import Darwin
import Foundation

/// Para cortar una sincronización desde afuera (botón, disco que se va).
public final class Cancelador: @unchecked Sendable {
    private let candado = NSLock()
    private var _cancelado = false
    public init() {}
    public var cancelado: Bool { candado.withLock { _cancelado } }
    public func cancelar() { candado.withLock { _cancelado = true } }
}

public struct Progreso: Sendable {
    public var hechos: Int
    public var total: Int
    public var bytesHechos: Int64
    public var bytesTotal: Int64
    public var ruta: String
}

/// Un cambio hecho, para el historial detallado.
public struct Cambio: Sendable, Codable, Equatable {
    public enum Tipo: String, Sendable, Codable { case copiado, reemplazado, aPapelera, carpeta, conflicto }
    public var ruta: String
    public var tipo: Tipo
    /// Disco donde se escribió (o de donde se mandó a la papelera).
    public var lado: Lado
    /// En conflictos: el nombre con el que quedó la otra versión.
    public var otraVersion: String?
}

public struct Resultado: Sendable {
    /// Cambios uno por uno (hasta `Resultado.topeCambios`); `cambiosTotales` cuenta todos.
    public var cambios: [Cambio] = []
    public var cambiosTotales = 0
    /// Nombre de la carpeta de papelera de esta pasada (`.Relevo/Papelera/<sello>/…`).
    public var sello = ""
    public static let topeCambios = 2000
    public var copiados = 0
    public var bytes: Int64 = 0
    public var carpetas = 0
    public var aPapelera = 0
    public var conflictos: [String] = []
    /// Archivos que cambiaron mientras se copiaban (se reintenta en la próxima pasada).
    public var enUso: [String] = []
    public var problemas: [Problema] = []
    /// Si un disco se desconectó a mitad: cuál.
    public var desconectado: Lado?
    public var cancelado = false
    /// Cuántos pasos quedaron sin hacer (se retoman solos al volver a sincronizar).
    public var pendientes = 0
    public var reparados = 0
    public var duracion: TimeInterval = 0

    public var completo: Bool { desconectado == nil && !cancelado && pendientes == 0 && problemas.isEmpty }

    /// Completo, salvo archivos que cambiaban mientras se copiaban (`enUso`). Eso no es algo que quedó atrás: el
    /// cambio que los movió deja su propio aviso de macOS y entran en la próxima pasada. Lo usa el `Coordinador` para
    /// saber si quedó al día (y "Me voy" puede ir por el camino rápido).
    public var completoSalvoEnUso: Bool {
        desconectado == nil && !cancelado && problemas.isEmpty && pendientes <= enUso.count
    }
}

enum ErrorCopia: Error {
    case cambioMientras
    case destinoCambio
    case desconectado(Lado)
    case sistema(Int32, String)
}

/// Hace el plan. Reglas para no romper nada:
/// 1. Nunca borra: lo que se elimina o se pisa va a la papelera de ese mismo disco (mover es instantáneo).
/// 2. Copia a un archivo temporal y lo renombra al final: nunca queda un archivo a medias con el nombre real.
/// 3. Antes de pisar, revisa que el destino siga como en la foto; si alguien lo tocó recién, no lo pisa.
/// 4. Anota en un diario lo copiado hasta que el disco confirma que lo escribió; si se corta, al volver se revisa.
final class Ejecutor: @unchecked Sendable {
    let volumenHub: String
    let volumenPortatil: String
    /// Carpeta que se sincroniza, relativa a la raíz de cada disco (por ejemplo "Proyectos/MiApp").
    let carpeta: String
    let diario: Diario
    let cancelador: Cancelador
    let progreso: ((Progreso) -> Void)?
    var hub: Foto
    var portatil: Foto

    private let candado = NSLock()
    private var resultado = Resultado()
    private(set) var nuevos: [String: Registro] = [:]
    private(set) var quitados: [String] = []      // rutas (y lo de adentro) que salen de la base
    private var hechos = 0, total = 0
    private var bytesHechos: Int64 = 0, bytesTotal: Int64 = 0
    private var bytesDesdeConfirmar: Int64 = 0
    private var permisosFinales: [String: mode_t] = [:]
    /// Carpetas de destino ya revisadas en esta pasada (ver `exigirSinEnlaces`).
    private var sinEnlaces = Set<String>()
    private var ultimaConfirmacion = Date()
    private let sello: String
    private let dispositivo: [Lado: dev_t]

    init(volumenHub: String, volumenPortatil: String, carpeta: String, diario: Diario,
         hub: Foto, portatil: Foto, cancelador: Cancelador, progreso: ((Progreso) -> Void)?) {
        self.volumenHub = volumenHub; self.volumenPortatil = volumenPortatil; self.carpeta = carpeta
        self.diario = diario; self.hub = hub; self.portatil = portatil
        self.cancelador = cancelador; self.progreso = progreso
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_AR")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        sello = f.string(from: Date())
        var d: [Lado: dev_t] = [:]
        for lado in Lado.allCases {
            var s = stat()
            if stat(lado == .hub ? volumenHub : volumenPortatil, &s) == 0 { d[lado] = s.st_dev }
        }
        dispositivo = d
    }

    func volumen(_ l: Lado) -> String { l == .hub ? volumenHub : volumenPortatil }
    func raiz(_ l: Lado) -> String { volumen(l) + "/" + carpeta }
    func completa(_ l: Lado, _ ruta: String) -> String { raiz(l) + "/" + ruta }
    func foto(_ l: Lado) -> Foto { l == .hub ? hub : portatil }

    // MARK: - Correr el plan

    func ejecutar(_ plan: Plan) -> Resultado {
        let inicio = Date()
        resultado.sello = sello
        total = plan.borrar.count + plan.conflictos.count + plan.carpetas.count + plan.copias.count
        for c in plan.copias { bytesTotal = Rutas.sumar(bytesTotal, foto(c.lado.otro).entradas[c.ruta]?.tamano ?? 0) }

        limpiarTemporales()
        for r in plan.anotar {
            if let h = hub.entradas[r], let p = portatil.entradas[r] { nuevos[r] = Registro(hub: h, portatil: p) }
        }
        for r in plan.olvidar { quitados.append(r) }

        // Orden: primero la papelera (también libera nombres), después conflictos, carpetas y por último copias.
        let etapas: [([Paso], (Paso) throws -> Void)] = [
            (plan.borrar, borrar), (plan.conflictos, resolverConflicto), (plan.carpetas, crearCarpeta),
        ]
        for (pasos, hacer) in etapas {
            for paso in pasos where seguir() { hacerPaso(paso, hacer) }
        }

        // Las copias van en paralelo (4 a la vez): con muchos archivos chicos rinde mucho más.
        let copias = plan.copias
        var siguiente = 0
        let candadoCola = NSLock()
        DispatchQueue.concurrentPerform(iterations: min(4, max(1, copias.count))) { _ in
            while seguir() {
                let i: Int = candadoCola.withLock { defer { siguiente += 1 }; return siguiente }
                guard i < copias.count else { break }
                hacerPaso(copias[i], copiar)
            }
        }
        confirmarEscritura()
        restaurarPermisos()

        resultado.pendientes = total - hechos
        resultado.cancelado = cancelador.cancelado && resultado.desconectado == nil
        resultado.duracion = Date().timeIntervalSince(inicio)
        return resultado
    }

    private func seguir() -> Bool { !cancelador.cancelado && candado.withLock { resultado.desconectado == nil } }

    private func hacerPaso(_ paso: Paso, _ hacer: (Paso) throws -> Void) {
        do {
            try hacer(paso)
            candado.withLock { hechos += 1 }
        } catch ErrorCopia.cambioMientras {
            candado.withLock { resultado.enUso.append(paso.ruta) }
        } catch ErrorCopia.destinoCambio {
            candado.withLock { resultado.enUso.append(paso.ruta) }
        } catch ErrorCopia.desconectado(let lado) {
            marcarDesconectado(lado)
        } catch {
            // ¿Fue por un disco que se fue?
            for lado in Lado.allCases where !sigueConectado(lado) { marcarDesconectado(lado); return }
            let detalle: String
            if case ErrorCopia.sistema(let c, let que) = error { detalle = "\(que): \(String(cString: strerror(c)))" } else { detalle = "\(error)" }
            candado.withLock { resultado.problemas.append(Problema(ruta: paso.ruta, detalle: detalle)) }
        }
        avisar(paso.ruta)
    }

    private func anotarCambio(_ c: Cambio) {
        candado.withLock {
            resultado.cambiosTotales += 1
            if resultado.cambios.count < Resultado.topeCambios { resultado.cambios.append(c) }
        }
    }

    private func marcarDesconectado(_ lado: Lado) {
        candado.withLock { if resultado.desconectado == nil { resultado.desconectado = lado } }
        cancelador.cancelar()
    }

    private func avisar(_ ruta: String) {
        guard let progreso else { return }
        let p = candado.withLock { Progreso(hechos: hechos, total: total, bytesHechos: bytesHechos, bytesTotal: bytesTotal, ruta: ruta) }
        progreso(p)
    }

    /// El disco sigue enchufado y es el mismo (no otro montado en el mismo lugar).
    func sigueConectado(_ lado: Lado) -> Bool {
        var s = stat()
        guard stat(volumen(lado), &s) == 0 else { return false }
        return dispositivo[lado] == nil || dispositivo[lado] == s.st_dev
    }

    // MARK: - Pasos

    private func borrar(_ paso: Paso) throws {
        try aPapelera(paso.lado, paso.ruta)
        candado.withLock {
            quitados.append(paso.ruta)
            resultado.aPapelera += 1
        }
        anotarCambio(Cambio(ruta: paso.ruta, tipo: .aPapelera, lado: paso.lado))
    }

    private func crearCarpeta(_ paso: Paso) throws {
        let destino = completa(paso.lado, paso.ruta)
        try exigirSinEnlaces((destino as NSString).deletingLastPathComponent, paso.lado)
        if let e = Escaner.entrada(destino), e.tipo != .carpeta { try aPapelera(paso.lado, paso.ruta) }
        try crearCarpetas(destino, lado: paso.lado)
        if let modo = foto(paso.lado.otro).entradas[paso.ruta]?.modo {
            // Una carpeta de solo lectura recibe su permiso al final: si no, no se podría copiar nada adentro.
            if modo & 0o200 == 0 {
                chmod(destino, mode_t(modo | 0o700))
                candado.withLock { permisosFinales[destino] = mode_t(modo) }
            } else {
                chmod(destino, mode_t(modo))
            }
        }
        let h = Escaner.entrada(completa(.hub, paso.ruta)), p = Escaner.entrada(completa(.portatil, paso.ruta))
        candado.withLock {
            if let h, let p { nuevos[paso.ruta] = Registro(hub: h, portatil: p) }
            resultado.carpetas += 1
        }
    }

    private func copiar(_ paso: Paso) throws {
        let origenLado = paso.lado.otro
        guard let esperado = foto(origenLado).entradas[paso.ruta] else { return }
        try copiarArchivo(paso.ruta, de: origenLado, esperado: esperado,
                          destinoEsperado: foto(paso.lado).entradas[paso.ruta])
    }

    /// Cambió distinto en los dos lados: la versión del que pierde se guarda como "nombre (conflicto portátil …)" en
    /// los dos discos y la del que gana queda con el nombre original en los dos. No se pierde ninguna.
    private func resolverConflicto(_ paso: Paso) throws {
        let ganador = paso.lado, perdedor = paso.lado.otro
        guard let eGanador = foto(ganador).entradas[paso.ruta],
              let ePerdedor = foto(perdedor).entradas[paso.ruta] else { return }
        try exigirSinEnlaces((completa(perdedor, paso.ruta) as NSString).deletingLastPathComponent, perdedor)
        // Que el que pierde siga como en la foto antes de moverlo.
        guard Escaner.entrada(completa(perdedor, paso.ruta)) == ePerdedor || ePerdedor.tipo == .carpeta else {
            throw ErrorCopia.destinoCambio
        }
        // Si ya hay una versión con ese nombre (otro conflicto del mismo archivo en el mismo minuto), se numera: renombrar
        // encima la pisaría.
        var nuevoNombre = Ejecutor.nombreConflicto(paso.ruta, lado: perdedor, sello: sello)
        var n = 2
        while Lado.allCases.contains(where: { Escaner.entrada(completa($0, nuevoNombre)) != nil }) {
            nuevoNombre = Ejecutor.nombreConflicto(paso.ruta, lado: perdedor, sello: sello + " \(n)")
            n += 1
        }
        abrirParaEscribir((completa(perdedor, paso.ruta) as NSString).deletingLastPathComponent)
        guard rename(completa(perdedor, paso.ruta), completa(perdedor, nuevoNombre)) == 0 else {
            throw ErrorCopia.sistema(errno, "renombrar conflicto")
        }
        if ePerdedor.tipo != .carpeta {
            try copiarArchivo(nuevoNombre, de: perdedor, esperado: ePerdedor, destinoEsperado: nil, contar: false)
        }
        if eGanador.tipo == .carpeta {
            try crearCarpeta(Paso(ruta: paso.ruta, lado: perdedor))
        } else {
            try copiarArchivo(paso.ruta, de: ganador, esperado: eGanador, destinoEsperado: nil, contar: false)
        }
        candado.withLock { resultado.conflictos.append(paso.ruta) }
        anotarCambio(Cambio(ruta: paso.ruta, tipo: .conflicto, lado: ganador, otraVersion: nuevoNombre))
    }

    static func nombreConflicto(_ ruta: String, lado: Lado, sello: String) -> String {
        let nombre = ruta.nombreFinal
        // El sello va hasta el minuto; un número de desempate (" 2"), si lo hay, va al final.
        let desempate = sello.split(separator: " ").count > 2 ? " " + sello.split(separator: " ").last! : ""
        let marca = " (conflicto \(lado.nombre) \(sello.prefix(16))\(desempate))"
        var base = nombre, ext = ""
        if let punto = nombre.lastIndex(of: "."), punto != nombre.startIndex {
            base = String(nombre[..<punto]); ext = String(nombre[punto...])
        }
        let carpeta = ruta.padre
        let final = base + marca + ext
        return carpeta.isEmpty ? final : carpeta + "/" + final
    }

    // MARK: - Copia segura

    private func copiarArchivo(_ ruta: String, de origenLado: Lado, esperado: Entrada, destinoEsperado: Entrada?,
                               contar: Bool = true) throws {
        let destinoLado = origenLado.otro
        let origen = completa(origenLado, ruta), destino = completa(destinoLado, ruta)
        guard sigueConectado(origenLado) else { throw ErrorCopia.desconectado(origenLado) }
        guard sigueConectado(destinoLado) else { throw ErrorCopia.desconectado(destinoLado) }
        guard Escaner.entrada(origen) == esperado else { throw ErrorCopia.cambioMientras }

        let carpeta = (destino as NSString).deletingLastPathComponent
        try exigirSinEnlaces((origen as NSString).deletingLastPathComponent, origenLado)
        try exigirSinEnlaces(carpeta, destinoLado)
        try crearCarpetas(carpeta, lado: destinoLado)
        abrirParaEscribir(carpeta)
        let temporal = carpeta + "/." + String(ruta.nombreFinal.prefix(200)) + Reglas.sufijoTemporal
        unlink(temporal)

        if esperado.tipo == .enlace {
            guard symlink(esperado.destino ?? "", temporal) == 0 else { throw ErrorCopia.sistema(errno, "crear enlace") }
        } else {
            guard copyfile(origen, temporal, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) == 0 else {
                let e = errno
                unlink(temporal)
                throw ErrorCopia.sistema(e, "copiar")
            }
            // Misma fecha que el original: es lo que permite saber después que están iguales.
            var tiempos = [timespec(tv_sec: Int(esperado.mtime / 1_000_000_000), tv_nsec: Int(esperado.mtime % 1_000_000_000)),
                           timespec(tv_sec: Int(esperado.mtime / 1_000_000_000), tv_nsec: Int(esperado.mtime % 1_000_000_000))]
            utimensat(AT_FDCWD, temporal, &tiempos, AT_SYMLINK_NOFOLLOW)
        }

        // Si el original cambió mientras lo copiábamos, esta copia no sirve: se reintenta la próxima.
        guard Escaner.entrada(origen) == esperado else { unlink(temporal); throw ErrorCopia.cambioMientras }
        // Si alguien tocó el destino desde la foto, no lo pisamos.
        let actual = Escaner.entrada(destino)
        if let actual, actual.tipo != .carpeta, actual != destinoEsperado { unlink(temporal); throw ErrorCopia.destinoCambio }

        let anotacion = diario.anotar(destinoLado, ruta)
        var guardada: String?
        do {
            if let actual {
                if actual.tipo == .archivo {
                    // La versión vieja queda en la papelera (un enlace duro: no ocupa espacio extra) y el reemplazo
                    // es un solo paso: el archivo nunca falta.
                    let enPapelera = try lugarEnPapelera(destinoLado, ruta)
                    guardada = link(destino, enPapelera) == 0 ? enPapelera : try aPapelera(destinoLado, ruta)
                } else {
                    try aPapelera(destinoLado, ruta)
                }
            }
            guard rename(temporal, destino) == 0 else { throw ErrorCopia.sistema(errno, "reemplazar") }
        } catch {
            unlink(temporal)
            diario.descartar(anotacion)
            throw error
        }
        diario.listo(anotacion)
        if let guardada, let actual, actual.tamano >= Ejecutor.unaSolaVersionDesde {
            soloLaUltimaVersion(destinoLado, ruta, guardada: guardada)
        }

        if contar { anotarCambio(Cambio(ruta: ruta, tipo: actual == nil ? .copiado : .reemplazado, lado: destinoLado)) }
        if let final = Escaner.entrada(destino) {
            let registro = origenLado == .hub ? Registro(hub: esperado, portatil: final) : Registro(hub: final, portatil: esperado)
            candado.withLock {
                nuevos[ruta] = registro
                if contar {
                    resultado.copiados += 1
                    resultado.bytes = Rutas.sumar(resultado.bytes, esperado.tamano)
                    bytesHechos = Rutas.sumar(bytesHechos, esperado.tamano)
                }
                bytesDesdeConfirmar = Rutas.sumar(bytesDesdeConfirmar, esperado.tamano)
            }
        }
        confirmarSiHaceFalta()
    }

    /// Carpetas de solo lectura (por ejemplo, una versión congelada): se les abre el permiso un momento para
    /// escribir adentro y al terminar vuelven a quedar como estaban.
    private func abrirParaEscribir(_ carpeta: String) {
        guard access(carpeta, W_OK) != 0, errno == EACCES else { return }
        var s = stat()
        guard lstat(carpeta, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR else { return }
        let original = s.st_mode & 0o7777
        guard chmod(carpeta, original | 0o700) == 0 else { return }
        candado.withLock { if permisosFinales[carpeta] == nil { permisosFinales[carpeta] = original } }
    }

    /// Devuelve a cada carpeta su permiso (de la más profunda a la de más arriba).
    private func restaurarPermisos() {
        let lista = candado.withLock { permisosFinales }
        for (carpeta, modo) in lista.sorted(by: { $0.key.count > $1.key.count }) { chmod(carpeta, modo) }
        candado.withLock { permisosFinales = [:] }
    }

    private func crearCarpetas(_ carpeta: String, lado: Lado) throws {
        if mkdir(carpeta, 0o755) == 0 { return }
        if errno == EEXIST { try exigirCarpetaReal(carpeta); return }
        if errno == EACCES {
            abrirParaEscribir((carpeta as NSString).deletingLastPathComponent)
            if mkdir(carpeta, 0o755) == 0 { return }
            if errno == EEXIST { try exigirCarpetaReal(carpeta); return }
        }
        guard errno == ENOENT else { throw ErrorCopia.sistema(errno, "crear carpeta") }
        guard sigueConectado(lado) else { throw ErrorCopia.desconectado(lado) }
        try crearCarpetas((carpeta as NSString).deletingLastPathComponent, lado: lado)
        if mkdir(carpeta, 0o755) != 0 {
            guard errno == EEXIST else { throw ErrorCopia.sistema(errno, "crear carpeta") }
            try exigirCarpetaReal(carpeta)
        }
    }

    /// Lo que ya existe tiene que ser una carpeta de verdad: si fuera un enlace (atajo) a otra carpeta, escribir
    /// adentro terminaría fuera del disco.
    private func exigirCarpetaReal(_ carpeta: String) throws {
        var s = stat()
        guard lstat(carpeta, &s) == 0, (s.st_mode & S_IFMT) == S_IFDIR else { throw ErrorCopia.sistema(ENOTDIR, "no es una carpeta") }
    }

    /// Que ninguna carpeta del camino (desde la raíz del disco de ese lado) sea un enlace ni esté en otro disco. Si el
    /// portátil trae una carpeta cambiada por un enlace a otro lugar de la Mac, escribir o mover "adentro" terminaría
    /// fuera de lo sincronizado (auditoría del 23/10). `exigirCarpetaReal` solo mira la última parte; esto, todas.
    /// Lo llaman copiar, crear carpeta, conflicto y papelera antes de tocar nada. Lo ya revisado no se vuelve a mirar.
    private func exigirSinEnlaces(_ carpeta: String, _ lado: Lado) throws {
        if candado.withLock({ sinEnlaces.contains(carpeta) }) { return }
        guard Rutas.sinEnlaces(carpeta, desde: volumen(lado)) else {
            throw ErrorCopia.sistema(ENOTDIR, "una carpeta del camino es un enlace o está en otro disco")
        }
        candado.withLock { _ = sinEnlaces.insert(carpeta) }
    }

    // MARK: - Papelera

    private func lugarEnPapelera(_ lado: Lado, _ ruta: String) throws -> String {
        let base = Sincronizador.papelera(volumen(lado)) + "/" + sello + "/" + carpeta
        var destino = base + "/" + ruta
        try exigirSinEnlaces((destino as NSString).deletingLastPathComponent, lado)
        try crearCarpetas((destino as NSString).deletingLastPathComponent, lado: lado)
        var n = 2
        while access(destino, F_OK) == 0 { destino = base + "/" + ruta + " \(n)"; n += 1 }
        return destino
    }

    /// La carpeta del par entera a la papelera de ese lado, con lo que le quede adentro (también lo que no viaja, como
    /// node_modules). Para cuando la borraste del otro lado y confirmaste: si no, quedaba vacía y la próxima vez volvía
    /// a aparecer del lado donde la borraste. Lo llama `Sincronizador.ejecutar`; devuelve true si la movió.
    func raizAPapelera(_ lado: Lado) -> Bool {
        let origen = raiz(lado)
        guard Escaner.entrada(origen)?.tipo == .carpeta, Rutas.sinEnlaces(origen, desde: volumen(lado)) else { return false }
        let base = Sincronizador.papelera(volumen(lado)) + "/" + sello + "/" + carpeta
        var destino = base, n = 2
        while access(destino, F_OK) == 0 { destino = base + " \(n)"; n += 1 }
        guard (try? crearCarpetas((destino as NSString).deletingLastPathComponent, lado: lado)) != nil else { return false }
        abrirParaEscribir((origen as NSString).deletingLastPathComponent)
        abrirParaEscribir(origen)
        return rename(origen, destino) == 0
    }

    /// De los archivos de este tamaño para arriba, la papelera guarda solo la última versión pisada (ver
    /// `soloLaUltimaVersion`). Las pruebas lo bajan para no escribir archivos enormes.
    static var unaSolaVersionDesde: Int64 = 256 << 20

    /// Borra de la papelera de ese lado las versiones anteriores de `ruta` (de esta pasada y de las otras) y deja solo
    /// `guardada`, la que se acaba de pisar. Un archivo enorme que cambia seguido (un disco virtual, una grabación)
    /// dejaba una copia entera por cada vez: 300 GB de papelera en el portátil en nueve días (30/10/2026). Con la
    /// última alcanza para volver atrás. Lo llama `copiarArchivo`, solo para archivos de `unaSolaVersionDesde` o más.
    private func soloLaUltimaVersion(_ lado: Lado, _ ruta: String, guardada: String) {
        let base = Sincronizador.papelera(volumen(lado))
        guard let sellos = try? FileManager.default.contentsOfDirectory(atPath: base) else { return }
        let nombre = ruta.nombreFinal, arriba = ruta.padre
        for s in sellos {
            let lugar = base + "/" + s + "/" + carpeta + (arriba.isEmpty ? "" : "/" + arriba)
            guard let nombres = try? FileManager.default.contentsOfDirectory(atPath: lugar),
                  Rutas.sinEnlaces(lugar, desde: volumen(lado)) else { continue }
            for n in nombres where Ejecutor.esVersion(n, de: nombre) {
                let vieja = lugar + "/" + n
                if vieja != guardada, Escaner.entrada(vieja)?.tipo == .archivo { unlink(vieja) }
            }
        }
    }

    /// ¿`n` es `nombre` tal cual o con el número que le suma `lugarEnPapelera` cuando ya había otro ("foto.img 2")?
    static func esVersion(_ n: String, de nombre: String) -> Bool {
        guard n.hasPrefix(nombre) else { return false }
        let resto = n.dropFirst(nombre.count)
        return resto.isEmpty || (resto.count > 1 && resto.first == " " && resto.dropFirst().allSatisfy(\.isNumber))
    }

    /// Mueve a la papelera de ese disco. Mover dentro del mismo disco es instantáneo y no ocupa lugar. Devuelve dónde
    /// quedó (nil si ya no estaba).
    @discardableResult
    private func aPapelera(_ lado: Lado, _ ruta: String) throws -> String? {
        let origen = completa(lado, ruta)
        guard access(origen, F_OK) == 0 || Escaner.entrada(origen) != nil else { return nil }
        try exigirSinEnlaces((origen as NSString).deletingLastPathComponent, lado)
        let destino = try lugarEnPapelera(lado, ruta)
        abrirParaEscribir((origen as NSString).deletingLastPathComponent)
        if Escaner.entrada(origen)?.tipo == .carpeta { abrirParaEscribir(origen) }
        guard rename(origen, destino) == 0 else { throw ErrorCopia.sistema(errno, "mover a la papelera") }
        return destino
    }

    private func limpiarTemporales() {
        for (lado, f) in [(Lado.hub, hub), (.portatil, portatil)] {
            for t in f.temporales { unlink(completa(lado, t)) }
        }
    }

    // MARK: - Confirmar escritura

    /// Cada 256 MB o 2 segundos se le pide a los discos que escriban de verdad lo que tienen en memoria; recién ahí
    /// se tachan esas copias del diario. Si el disco se saca antes, el diario dice qué revisar.
    private func confirmarSiHaceFalta() {
        let toca = candado.withLock { bytesDesdeConfirmar > 256 << 20 || Date().timeIntervalSince(ultimaConfirmacion) > 2 }
        if toca { confirmarEscritura() }
    }

    private func confirmarEscritura() {
        candado.withLock { bytesDesdeConfirmar = 0; ultimaConfirmacion = Date() }
        let listos = diario.listos()
        guard !listos.isEmpty else { return }
        for lado in Set(listos.map(\.paso.lado)) {
            guard sync_volume_np(volumen(lado), 0x01 | 0x02) == 0 else { return }   // FULLSYNC | WAIT
        }
        diario.confirmar(listos.map(\.id))
    }
}
