import Darwin
import Foundation

/// Algo que frena la sincronización hasta que digas que sí.
public enum Alerta: Sendable, Equatable {
    /// La carpeta no está en ese disco, pero la última vez sí (¿la moviste o la borraste?).
    case faltaCarpeta(Lado)
    /// Se mandarían muchos archivos a la papelera de ese lado.
    case muchosBorrados(Lado, Int)
    /// No entra lo que hay que copiar.
    case sinEspacio(Lado, necesita: Int64, hay: Int64)
}

public struct Analisis: Sendable {
    public let carpeta: String
    public let plan: Plan
    public let hub: Foto
    public let portatil: Foto
    let base: Base
    public let alertas: [Alerta]
    /// Copias de una vez anterior que se cortó y no habían quedado bien: se rehacen.
    public let reparar: Int
    public let duracion: TimeInterval
    /// Revisión por zonas: qué parte de la base se revisó (las fotos y `base` tienen solo eso) y de qué archivo salió
    /// el resto, que se conserva tal cual al guardar. nil = se revisó la carpeta entera.
    let recorte: Recorte?
    let origenBase: URL?
    /// La base cambió aunque no haya nada que copiar (por ejemplo, se anotó el número fijo de carpetas que todavía no
    /// lo tenían): conviene guardarla con `guardarBase` para que la próxima revisión por zonas no tenga que entrar.
    public let baseActualizada: Bool

    public var requiereOK: Bool { !alertas.isEmpty }
    /// Se miró solo lo que avisó macOS (y no la carpeta entera).
    public var porZonas: Bool { recorte != nil }
}

/// Une todo para una carpeta: sacar las fotos de los dos discos, comparar con la base, decidir y ejecutar.
public final class Sincronizador: @unchecked Sendable {
    public let volumenHub: String
    public let volumenPortatil: String
    public let reglas: Reglas
    /// Para cada carpeta, rutas extra que no se relevan (por ejemplo, lo que ignora su `.gitignore`).
    public var ignoradas: ((String) -> Set<String>)?

    func reglas(para carpeta: String) -> Reglas {
        guard let ignoradas else { return reglas }
        let r = ignoradas(carpeta)
        return r.isEmpty ? reglas : reglas.con(ignoradas: r)
    }
    /// Carpeta en la Mac donde se guarda la base y el diario de este par de discos.
    public let estado: URL

    public init(volumenHub: String, volumenPortatil: String, reglas: Reglas = .porDefecto, estado: URL) {
        self.volumenHub = volumenHub; self.volumenPortatil = volumenPortatil
        self.reglas = reglas; self.estado = estado
    }

    public static func papelera(_ volumen: String) -> String { volumen + "/.Relevo/Papelera" }

    func volumen(_ l: Lado) -> String { l == .hub ? volumenHub : volumenPortatil }
    func raiz(_ l: Lado, _ carpeta: String) -> String { volumen(l) + "/" + carpeta }

    static func nombreArchivo(_ carpeta: String) -> String {
        carpeta.replacingOccurrences(of: "/", with: "__")
    }
    public func archivoBase(_ carpeta: String) -> URL { estado.appendingPathComponent(Self.nombreArchivo(carpeta) + ".base") }
    func archivoBaseEnPortatil(_ carpeta: String) -> URL {
        URL(fileURLWithPath: volumenPortatil + "/.Relevo/estado/" + Self.nombreArchivo(carpeta) + ".base")
    }
    func archivoDiario(_ carpeta: String) -> URL { estado.appendingPathComponent(Self.nombreArchivo(carpeta) + ".pendientes") }
    func archivoRecientes(_ carpeta: String) -> URL { estado.appendingPathComponent(Self.nombreArchivo(carpeta) + ".recientes") }

    /// El disco se expulsó bien: lo que se le escribió quedó guardado seguro y ya no hace falta vigilarlo.
    public func expulsadoBien(_ lado: Lado) {
        guard let archivos = try? FileManager.default.contentsOfDirectory(at: estado, includingPropertiesForKeys: nil) else { return }
        for url in archivos where url.pathExtension == "recientes" || url.pathExtension == "pendientes" {
            let quedan = Diario.leer(url).filter { $0.lado != lado }
            if quedan.isEmpty { try? FileManager.default.removeItem(at: url) } else {
                try? quedan.map { "\($0.lado.rawValue)\t\($0.ruta)\n" }.joined().write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }

    // MARK: - Analizar (no escribe nada en los discos)

    /// Saca las fotos de los dos lados, las compara con la base y arma el plan.
    /// `zonas` (lo que avisó el registro de cambios de macOS): si se puede, se mira solo eso y se da por sabido el
    /// resto (`analizarPorZonas`); si no hay certeza, se mira la carpeta entera, como siempre.
    public func analizar(_ carpeta: String, zonas: Zonas? = nil) throws -> Analisis {
        let inicio = Date()
        // La carpeta del par, de cada lado, tiene que ser una carpeta de verdad en ese disco: si alguna parte del
        // camino es un enlace (armado en el portátil), se leería y escribiría en otro lugar de la Mac. No se toca.
        // ("Xcode/." son los archivos sueltos de "Xcode": se mira esa carpeta.)
        let carpetaReal = carpeta.hasSuffix("/.") ? String(carpeta.dropLast(2)) : carpeta
        for lado in Lado.allCases where access(volumen(lado), F_OK) == 0 {
            guard Rutas.sinEnlaces(raiz(lado, carpetaReal), desde: volumen(lado)) else {
                throw ErrorEscaneo.noSePuedeLeer(raiz(lado, carpetaReal), ENOTDIR)
            }
        }
        if let zonas, let a = try analizarPorZonas(carpeta, zonas, inicio: inicio) { return a }
        let reglasCarpeta = reglas(para: carpeta)
        // Las dos fotos a la vez: cada disco va por su lado.
        var fotos: [Lado: Result<Foto, Error>] = [:]
        let candado = NSLock()
        DispatchQueue.concurrentPerform(iterations: 2) { i in
            let lado: Lado = i == 0 ? .hub : .portatil
            let r = Result { try Escaner.fotografiar(raiz(lado, carpeta), reglas: reglasCarpeta, soloArchivos: carpeta.hasSuffix("/.")) }
            candado.withLock { fotos[lado] = r }
        }

        // La base se carga después de las fotos para reusar sus rutas: cada ruta se guarda una vez en memoria y no
        // tres (en carpetas de cientos de miles de archivos es la mayor parte de la memoria).
        let rutasDelHub = (try? fotos[.hub]?.get())?.entradas ?? [:]
        var base = Base.cargar(archivoBase(carpeta), reusar: rutasDelHub)
            ?? Base.cargar(archivoBaseEnPortatil(carpeta), reusar: rutasDelHub) ?? Base()

        var alertas: [Alerta] = []
        func foto(_ lado: Lado) throws -> Foto {
            switch fotos[lado]! {
            case .success(let f): return f
            case .failure(ErrorEscaneo.noExiste):
                guard access(volumen(lado), F_OK) == 0 else { throw ErrorEscaneo.noExiste(volumen(lado)) }
                // Primera vez: es normal que la carpeta no exista todavía del otro lado.
                if !base.registros.isEmpty { alertas.append(.faltaCarpeta(lado)) }
                return Foto()
            case .failure(let e): throw e
            }
        }
        let hub = try foto(.hub), portatil = try foto(.portatil)
        let actualizada = anotarNumerosDeCarpetas(&base, hub, portatil)
        return completar(carpeta, hub: hub, portatil: portatil, base: base, alertas: alertas,
                         archivos: (hub.archivos, portatil.archivos), recorte: nil, origenBase: nil,
                         baseActualizada: actualizada, inicio: inicio)
    }

    /// Hasta cuántas carpetas distintas del diario (copias de la última vez que hay que revisar) se suman como zonas;
    /// con más, se mira la carpeta entera (es lo mismo y más simple).
    static let topeCarpetasDelDiario = 2000

    /// La revisión por zonas: se mira solo lo que avisó macOS y para todo lo demás vale la base (cómo quedó la última
    /// vez). Nunca se saltea un cambio: devuelve nil (y se mira la carpeta entera) si no hay base, si falta la carpeta de
    /// algún lado o si macOS pidió revisar la carpeta entera. Lo llama `analizar(_:zonas:)`.
    ///
    /// Cómo no se pierde nada (FSEvents avisa la carpeta donde pasó algo, no qué pasó):
    /// - De cada carpeta avisada se mira lo de adentro directo, en los dos lados.
    /// - Una subcarpeta que no está igual en los dos lados y en la base (nueva, borrada, cambiada por otra con el mismo
    ///   nombre: su número fijo no coincide) se mira entera: mover una carpeta no deja avisos adentro de ella.
    /// - En un proyecto git, si se tocó algo de su `.git`, se miran siempre sus ramas (HEAD, refs, packed-refs): la
    ///   regla de "commits distintos" necesita verlas para no mezclar dos historias.
    /// - Lo que anotó el diario (copias de la última vez que hay que revisar) también entra.
    private func analizarPorZonas(_ carpeta: String, _ zonas: Zonas, inicio: Date) throws -> Analisis? {
        // Los archivos sueltos de una carpeta ("Xcode/.") son pocos: se miran enteros.
        guard !carpeta.hasSuffix("/.") else { return nil }
        let raizHub = raiz(.hub, carpeta), raizPortatil = raiz(.portatil, carpeta)
        for r in [raizHub, raizPortatil] {
            var st = stat()
            guard lstat(r, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return nil }
        }
        // Solo con la base de la Mac (la copia del portátil puede estar unos minutos atrasada): si no está, entera.
        let origen = archivoBase(carpeta)
        guard FileManager.default.fileExists(atPath: origen.path) else { return nil }

        var planas = Set(zonas.planas.map(Self.limpiarRuta)), enteras = Set(zonas.enteras.map(Self.limpiarRuta))
        guard !enteras.contains("") else { return nil }
        // Una zona con ".." (o partes vacías) no sale de un registro de cambios normal: puede venir de un registro
        // armado en el disco y apuntar afuera de la carpeta del par. Sin certeza, se mira entera.
        guard planas.union(enteras).allSatisfy(Rutas.relativaSegura) else { return nil }
        // Lo que anotó el diario de la última vez: sus carpetas se miran también.
        var delDiario = Set<String>()
        var demasiadas = false
        let anotar: (Paso) -> Void = { paso in
            guard !demasiadas else { return }
            delDiario.insert(paso.ruta.padre)
            if delDiario.count > Self.topeCarpetasDelDiario { demasiadas = true }
        }
        Diario.leer(archivoDiario(carpeta)).forEach(anotar)
        Diario.recorrer(archivoRecientes(carpeta), anotar)
        guard !demasiadas else { return nil }
        planas.formUnion(delDiario)
        // Proyectos git tocados: también sus ramas.
        for r in planas.union(enteras) {
            guard let repo = Self.repoDeZona(r) else { continue }
            let git = repo.isEmpty ? ".git" : repo + "/.git"
            planas.insert(git)
            enteras.insert(git + "/refs")
        }
        enteras = Self.sinRepetidas(enteras)
        planas = planas.filter { p in !enteras.contains { p.estaDentro(de: $0) } }

        let reglasCarpeta = reglas(para: carpeta)
        func fotos(_ planas: Set<String>, _ enteras: Set<String>) throws -> (Foto, Foto) {
            var resultado: [Lado: Result<Foto, Error>] = [:]
            let candado = NSLock()
            DispatchQueue.concurrentPerform(iterations: 2) { i in
                let lado: Lado = i == 0 ? .hub : .portatil
                let r = Result { try Escaner.fotografiar(raiz(lado, carpeta), planas: planas, enteras: enteras, reglas: reglasCarpeta) }
                candado.withLock { resultado[lado] = r }
            }
            return (try resultado[.hub]!.get(), try resultado[.portatil]!.get())
        }
        var (hub, portatil) = try fotos(planas, enteras)
        guard case (var base, let archivosBase)? = Base.cargar(origen, recorte: Recorte(planas: planas, enteras: enteras),
                                                     reusar: hub.entradas) else { return nil }

        // Subcarpetas de las zonas planas que hay que mirar enteras: cualquier diferencia entre los dos lados y la base
        // (nueva, borrada, de otro tipo o con otro número fijo). También la propia zona, si ya no está de algún lado.
        var masEnteras = Set<String>()
        for p in planas where !p.isEmpty {
            if hub.entradas[p]?.tipo != .carpeta && Escaner.entrada(raizHub + "/" + p)?.tipo != .carpeta
                || portatil.entradas[p]?.tipo != .carpeta && Escaner.entrada(raizPortatil + "/" + p)?.tipo != .carpeta {
                masEnteras.insert(p)
            }
        }
        var hijas = Set<String>()
        for (r, e) in hub.entradas where e.tipo == .carpeta { hijas.insert(r) }
        for (r, e) in portatil.entradas where e.tipo == .carpeta { hijas.insert(r) }
        for (r, b) in base.registros where b.tipo == .carpeta { hijas.insert(r) }
        for r in hijas where planas.contains(r.padre) && !enteras.contains(where: { r.estaDentro(de: $0) }) {
            let h = hub.entradas[r], p = portatil.entradas[r], b = base.registros[r]
            let misma = h?.tipo == .carpeta && p?.tipo == .carpeta && b?.tipo == .carpeta
                && b?.mtimeHub != 0 && b?.mtimePortatil != 0 && b?.mtimeHub == h?.mtime && b?.mtimePortatil == p?.mtime
            if !misma { masEnteras.insert(r) }
        }
        masEnteras = Self.sinRepetidas(masEnteras).filter { m in !enteras.contains { m.estaDentro(de: $0) } }
        if !masEnteras.isEmpty {
            let (h2, p2) = try fotos([], masEnteras)
            for (r, e) in h2.entradas { hub.entradas[r] = e }
            for (r, e) in p2.entradas { portatil.entradas[r] = e }
            hub.noLeidas += h2.noLeidas; portatil.noLeidas += p2.noLeidas
            hub.temporales += h2.temporales; portatil.temporales += p2.temporales
            guard let (b2, _) = Base.cargar(origen, recorte: Recorte(planas: [], enteras: masEnteras),
                                            reusar: hub.entradas) else { return nil }
            for (r, reg) in b2.registros where base.registros[r] == nil { base.registros[r] = reg }
            enteras.formUnion(masEnteras)
            enteras = Self.sinRepetidas(enteras)
        }
        // Lo de las zonas planas que quedó adentro de una entera ya está cubierto por la entera.
        let recorte = Recorte(planas: planas.filter { p in !enteras.contains { p.estaDentro(de: $0) } }, enteras: enteras)
        hub.archivos = hub.entradas.values.reduce(0) { $0 + ($1.tipo == .archivo ? 1 : 0) }
        portatil.archivos = portatil.entradas.values.reduce(0) { $0 + ($1.tipo == .archivo ? 1 : 0) }
        hub.bytes = hub.entradas.values.reduce(0) { Rutas.sumar($0, $1.tipo == .archivo ? $1.tamano : 0) }
        portatil.bytes = portatil.entradas.values.reduce(0) { Rutas.sumar($0, $1.tipo == .archivo ? $1.tamano : 0) }

        let actualizada = anotarNumerosDeCarpetas(&base, hub, portatil)
        // Para el freno de "muchos borrados" cuenta la carpeta entera, no solo lo que se miró.
        let archivos = max(archivosBase, hub.archivos, portatil.archivos)
        return completar(carpeta, hub: hub, portatil: portatil, base: base, alertas: [], archivos: (archivos, archivos),
                         recorte: recorte, origenBase: origen, baseActualizada: actualizada, inicio: inicio)
    }

    /// "a/b/", "/a/b" o "." → la forma en que se guardan las rutas ("a/b", y "" para la raíz).
    static func limpiarRuta(_ r: String) -> String {
        var s = Substring(r)
        while s.hasPrefix("/") { s = s.dropFirst() }
        while s.hasSuffix("/") { s = s.dropLast() }
        return s == "." ? "" : String(s)
    }

    /// Sin las que ya están adentro de otra de la lista.
    static func sinRepetidas(_ carpetas: Set<String>) -> Set<String> {
        var salida = Set<String>()
        for c in carpetas.sorted(by: { $0.utf8.count < $1.utf8.count }) where !salida.contains(where: { c.estaDentro(de: $0) }) {
            salida.insert(c)
        }
        return salida
    }

    /// Si la zona está adentro de un `.git` (o es uno), la carpeta de ese proyecto ("" si es la raíz).
    static func repoDeZona(_ r: String) -> String? {
        if r == ".git" || r.hasPrefix(".git/") { return "" }
        if r.hasSuffix("/.git") { return String(r.dropLast(5)) }
        guard let i = r.range(of: "/.git/") else { return nil }
        return String(r[..<i.lowerBound])
    }

    /// Anota en la base el número fijo de las carpetas que están en los dos lados (las bases de antes no lo tenían, y
    /// una carpeta movida lo cambia). No cambia nada de lo que se copia. Devuelve true si cambió algo.
    private func anotarNumerosDeCarpetas(_ base: inout Base, _ hub: Foto, _ portatil: Foto) -> Bool {
        var cambio = false
        for (r, b) in base.registros where b.tipo == .carpeta {
            guard let h = hub.entradas[r], let p = portatil.entradas[r], h.tipo == .carpeta, p.tipo == .carpeta,
                  b.mtimeHub != h.mtime || b.mtimePortatil != p.mtime else { continue }
            base.registros[r]?.mtimeHub = h.mtime
            base.registros[r]?.mtimePortatil = p.mtime
            cambio = true
        }
        return cambio
    }

    /// Lo que comparten la revisión entera y la de zonas: reparar lo que dejó el diario, armar el plan y los frenos.
    /// `archivos`: cuántos archivos tiene cada lado (para el freno de muchos borrados).
    private func completar(_ carpeta: String, hub: Foto, portatil: Foto, base: Base, alertas: [Alerta],
                           archivos: (hub: Int, portatil: Int), recorte: Recorte?, origenBase: URL?,
                           baseActualizada: Bool, inicio: Date) -> Analisis {
        var base = base, alertas = alertas

        // Lo que se escribió en la última sincronización y el disco puede haber perdido si se sacó de golpe.
        // Si falta o quedó distinto, se vuelve a copiar desde el original (nunca se toma como un borrado tuyo).
        var reparar = 0
        let pendientes = Set(Diario.leer(archivoDiario(carpeta)))
        // Las recientes pueden ser cientos de miles (después de una copia grande): se recorren de a una, sin juntarlas.
        var revisar = Array(pendientes)
        Diario.recorrer(archivoRecientes(carpeta)) { if !pendientes.contains($0) { revisar.append($0) } }
        for paso in revisar {
            let origen = paso.lado.otro
            guard let eo = (origen == .hub ? hub : portatil).entradas[paso.ruta], eo.tipo != .carpeta,
                  let b = base.registros[paso.ruta], b.igual(eo, lado: origen) else { continue }
            let ed = (paso.lado == .hub ? hub : portatil).entradas[paso.ruta]
            guard let ed else {
                // No está: se olvida de la base y el plan lo copia de nuevo.
                base.registros[paso.ruta] = nil
                reparar += 1
                continue
            }
            // Más nuevo que lo que escribimos: es un cambio tuyo de después, no una copia perdida.
            if ed.tipo == .archivo && ed.mtime > b.mtime(paso.lado) { continue }
            if ed.tipo == eo.tipo && ed.tamano == eo.tamano {
                // Sin confirmar: además se compara el contenido.
                if !pendientes.contains(paso) || eo.tipo != .archivo { continue }
                if Sincronizador.mismoContenido(raiz(.hub, carpeta) + "/" + paso.ruta, raiz(.portatil, carpeta) + "/" + paso.ruta) {
                    continue
                }
            }
            // Quedó distinto: se marca como "cambiado del lado de origen" y el plan lo vuelve a copiar.
            let (h, p) = origen == .hub ? (Entrada(tipo: eo.tipo, mtime: -1), ed) : (ed, Entrada(tipo: eo.tipo, mtime: -1))
            var r = Registro(hub: h, portatil: p)
            r.tipo = ed.tipo; r.tamano = ed.tamano; r.modo = ed.modo; r.destino = ed.destino
            base.registros[paso.ruta] = r
            reparar += 1
        }

        let raizHub = raiz(.hub, carpeta), raizPortatil = raiz(.portatil, carpeta)
        let plan = Planificador.planificar(hub: hub, portatil: portatil, base: base) { ruta in
            Sincronizador.mismoContenido(raizHub + "/" + ruta, raizPortatil + "/" + ruta)
        }

        // Frenos de seguridad.
        for lado in Lado.allCases {
            // El orden interno de git (.git/objects) no cuenta: no son archivos tuyos y git los borra solo.
            let aPapelera = lado == .hub ? plan.resumen.aPapeleraHub - plan.resumen.aPapeleraGitHub
                                         : plan.resumen.aPapeleraPortatil - plan.resumen.aPapeleraGitPortatil
            let total = lado == .hub ? archivos.hub : archivos.portatil
            if aPapelera > 50 && Double(aPapelera) > Double(total) * 0.2 {
                alertas.append(.muchosBorrados(lado, aPapelera))
            }
            let necesita = lado == .hub ? plan.resumen.bytesHaciaHub : plan.resumen.bytesHaciaPortatil
            let hay = Sincronizador.espacioLibre(volumen(lado))
            if necesita > 0, Rutas.sumar(necesita, 1 << 30) > hay { alertas.append(.sinEspacio(lado, necesita: necesita, hay: hay)) }
        }

        return Analisis(carpeta: carpeta, plan: plan, hub: hub, portatil: portatil, base: base, alertas: alertas,
                        reparar: reparar, duracion: Date().timeIntervalSince(inicio), recorte: recorte,
                        origenBase: origenBase, baseActualizada: baseActualizada)
    }

    // MARK: - Ejecutar

    /// Si el análisis tiene alertas, solo corre con `confirmado: true` (cuando dijiste que sí).
    public func ejecutar(_ a: Analisis, confirmado: Bool = false, cancelador: Cancelador = Cancelador(),
                         progreso: ((Progreso) -> Void)? = nil) -> Resultado {
        if a.requiereOK && !confirmado {
            var r = Resultado()
            r.cancelado = true
            r.pendientes = a.plan.borrar.count + a.plan.conflictos.count + a.plan.carpetas.count + a.plan.copias.count
            return r
        }
        let diario = Diario(pendientes: archivoDiario(a.carpeta), recientes: archivoRecientes(a.carpeta))
        diario.empezar()
        let ejecutor = Ejecutor(volumenHub: volumenHub, volumenPortatil: volumenPortatil, carpeta: a.carpeta,
                                diario: diario, hub: a.hub, portatil: a.portatil, cancelador: cancelador, progreso: progreso)
        var resultado = ejecutor.ejecutar(a.plan)
        resultado.reparados = a.reparar

        // Base nueva: la anterior, menos lo que salió, más lo que se hizo. Si se cortó, lo no hecho sigue
        // apareciendo como diferencia la próxima vez y se retoma solo.
        var base = a.base
        if !ejecutor.quitados.isEmpty {
            let quitados = Set(ejecutor.quitados)
            base.registros = base.registros.filter { ruta, _ in
                if quitados.contains(ruta) { return false }
                var padre = ruta.padre
                while !padre.isEmpty { if quitados.contains(padre) { return false }; padre = padre.padre }
                return true
            }
        }
        for (ruta, r) in ejecutor.nuevos { base.registros[ruta] = r }
        // La carpeta ya no está de un lado y dijiste que siga: si del otro solo había que borrar, se va entera a la
        // papelera (si no, quedaba vacía y volvía a aparecer). Si del otro lado hubo algo nuevo, se conserva.
        // Un repo con commits distintos de este lado (su .git no se tocó) no se manda a la papelera entero.
        let soloBorrar = a.plan.copias.isEmpty && a.plan.carpetas.isEmpty && a.plan.conflictos.isEmpty
            && a.plan.resumen.reposDistintos.isEmpty
        if confirmado, soloBorrar, resultado.desconectado == nil, !cancelador.cancelado {
            for alerta in a.alertas {
                if case .faltaCarpeta(let lado) = alerta, ejecutor.raizAPapelera(lado.otro) { base.registros = [:] }
            }
        }
        do {
            try guardar(base, a, portatil: resultado.desconectado != .portatil)
        } catch {
            resultado.problemas.append(Problema(ruta: "", detalle: "No se pudo guardar el estado: \(error)"))
        }
        return resultado
    }

    /// Para un análisis sin nada que copiar pero con la base actualizada (`Analisis.baseActualizada`): la guarda sin
    /// tocar el diario. Lo llama `Coordinador.sincronizar`.
    public func guardarBase(_ a: Analisis) throws {
        try guardar(a.base, a, portatil: true)
    }

    /// Cada cuánto se renueva la copia de la base que va en el portátil después de una revisión por zonas (la de la
    /// Mac se guarda siempre). Es un respaldo para cuando falta la de la Mac (otra Mac, Relevo reinstalado); una un poco
    /// vieja es segura: a lo sumo algo aparece como "cambiado en los dos lados" y se resuelve sin perder nada.
    static let renovarCopiaEnPortatil: TimeInterval = 10 * 60

    /// Guarda la base nueva en la Mac y su copia en el portátil. En una revisión por zonas, lo que no se miró se copia
    /// tal cual de la base de la que salió (`Base.guardar(_:encimaDe:recorte:)`).
    private func guardar(_ base: Base, _ a: Analisis, portatil: Bool) throws {
        let mac = archivoBase(a.carpeta), enPortatil = archivoBaseEnPortatil(a.carpeta)
        guard let recorte = a.recorte, let origen = a.origenBase else {
            try base.guardar(mac)
            // La copia de respaldo va al portátil solo si .Relevo/estado es una carpeta de verdad en ese disco.
            if portatil, Rutas.sinEnlaces(enPortatil.deletingLastPathComponent().path, desde: volumenPortatil) {
                try? base.guardar(enPortatil)
            }
            return
        }
        try base.guardar(mac, encimaDe: origen, recorte: recorte)
        guard portatil, Rutas.sinEnlaces(enPortatil.deletingLastPathComponent().path, desde: volumenPortatil) else { return }
        let fecha = (try? enPortatil.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if fecha.map({ Date().timeIntervalSince($0) > Self.renovarCopiaEnPortatil }) ?? true {
            try? Base.copiar(mac, a: enPortatil)
        }
    }

    // MARK: - Revisar a fondo

    /// Compara byte a byte todo lo que figura igual en los dos discos (mismo tamaño y fecha) para encontrar copias
    /// que se dañaron con el tiempo. Lento: lee todo. Devuelve las rutas que no coinciden.
    public func revisarAFondo(_ carpeta: String, cancelador: Cancelador = Cancelador(),
                              progreso: ((Int64, Int64) -> Void)? = nil) throws -> [String] {
        let solo = carpeta.hasSuffix("/.")
        let r = reglas(para: carpeta)
        let hub = try Escaner.fotografiar(raiz(.hub, carpeta), reglas: r, soloArchivos: solo)
        let portatil = try Escaner.fotografiar(raiz(.portatil, carpeta), reglas: r, soloArchivos: solo)
        let comunes = hub.entradas.filter { r, e in e.tipo == .archivo && portatil.entradas[r]?.tamano == e.tamano }
        let total = comunes.values.reduce(Int64(0)) { $0 + $1.tamano }
        var hecho: Int64 = 0
        var distintos: [String] = []
        for (r, e) in comunes.sorted(by: { $0.key < $1.key }) {
            if cancelador.cancelado { break }
            if !Sincronizador.mismoContenido(raiz(.hub, carpeta) + "/" + r, raiz(.portatil, carpeta) + "/" + r) {
                distintos.append(r)
            }
            hecho += e.tamano
            progreso?(hecho, total)
        }
        return distintos
    }

    /// La próxima sincronización copia estas rutas desde `desde` hacia el otro lado (la versión del otro lado
    /// queda en la papelera). Sirve para reparar lo que encontró `revisarAFondo`.
    public func forzarCopia(_ carpeta: String, rutas: [String], desde: Lado) throws {
        var base = Base.cargar(archivoBase(carpeta)) ?? Base()
        for r in rutas {
            guard var reg = base.registros[r] else { continue }
            if desde == .hub { reg.mtimeHub = -1 } else { reg.mtimePortatil = -1 }
            base.registros[r] = reg
        }
        try base.guardar(archivoBase(carpeta))
    }

    // MARK: - Ayudas

    static func espacioLibre(_ volumen: String) -> Int64 {
        let url = URL(fileURLWithPath: volumen)
        if let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity { return Int64(v) }
        return Int64.max
    }

    /// Compara byte a byte (solo se usa cuando tamaño igual pero fecha distinta, o para revisar copias cortadas).
    static func mismoContenido(_ a: String, _ b: String) -> Bool {
        guard let fa = FileHandle(forReadingAtPath: a), let fb = FileHandle(forReadingAtPath: b) else { return false }
        defer { try? fa.close(); try? fb.close() }
        while true {
            let da = (try? fa.read(upToCount: 1 << 20)) ?? nil
            let db = (try? fb.read(upToCount: 1 << 20)) ?? nil
            if da != db { return false }
            if da == nil || da!.isEmpty { return true }
        }
    }
}
