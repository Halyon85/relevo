import Foundation

/// Un paso del plan: qué ruta y de qué lado se hace.
/// - En `borrar`: el lado donde la ruta se manda a la papelera.
/// - En `carpetas` y `copias`: el lado donde se crea o se escribe (el de destino).
/// - En `conflictos`: el lado que gana (su versión queda con el nombre original).
public struct Paso: Sendable, Equatable, Hashable {
    public var ruta: String
    public var lado: Lado
}

public struct Resumen: Sendable, Equatable {
    public var haciaPortatil = 0
    public var haciaHub = 0
    public var bytesHaciaPortatil: Int64 = 0
    public var bytesHaciaHub: Int64 = 0
    /// Archivos que se van a la papelera de cada lado (contando lo que hay adentro de carpetas borradas).
    public var aPapeleraHub = 0
    public var aPapeleraPortatil = 0
    /// De esos, cuántos son internos de git: git los junta y los borra solo al ordenarse (`gc`), no son borrados tuyos.
    public var aPapeleraGitHub = 0
    public var aPapeleraGitPortatil = 0
    public var conflictos: [String] = []
    /// Borrado de un lado pero modificado del otro: se conserva la versión modificada.
    public var recuperados: [String] = []
    /// Proyectos git con cambios internos en los dos discos pero sin commits distintos (por ejemplo, `git status` de
    /// los dos lados): gana el lado que hizo commit o, si ninguno, el más nuevo; lo otro, a la papelera.
    public var reposEnLosDosLados: [String] = []
    /// Proyectos git con commits distintos en los dos discos (la misma rama apunta a commits distintos): su `.git` no
    /// se toca, para no mezclar las dos historias. Se avisa para unirlos con git; el resto del proyecto se releva igual.
    public var reposDistintos: [String] = []

    public var cambios: Int { haciaPortatil + haciaHub + aPapeleraHub + aPapeleraPortatil + conflictos.count }
}

public struct Plan: Sendable {
    public var borrar: [Paso] = []
    public var conflictos: [Paso] = []
    public var carpetas: [Paso] = []
    public var copias: [Paso] = []
    public var anotar: [String] = []
    public var olvidar: [String] = []
    public var resumen = Resumen()

    public var vacio: Bool { borrar.isEmpty && conflictos.isEmpty && carpetas.isEmpty && copias.isEmpty }
    public var soloAnotar: Bool { vacio && (!anotar.isEmpty || !olvidar.isEmpty) }
}

/// Compara las dos fotos contra la base (cómo quedaron la última vez) y decide qué hacer.
///
/// La regla es la de las herramientas de sincronización en dos sentidos (como Unison): si algo cambió de un solo
/// lado, ese cambio se lleva al otro; si cambió de los dos, es un conflicto y no se pisa nada.
enum Planificador {
    static func planificar(hub: Foto, portatil: Foto, base: Base,
                           mismoContenido: (String) -> Bool) -> Plan {
        var plan = Plan()
        var rutas = Set(hub.entradas.keys)
        rutas.formUnion(portatil.entradas.keys)
        rutas.formUnion(base.registros.keys)
        let hayNoLeidas = !hub.noLeidas.isEmpty || !portatil.noLeidas.isEmpty
        let noLeidas = Set(hub.noLeidas).union(portatil.noLeidas)

        var llevar: [Paso] = []          // lado = de dónde sale
        var repos = Set<String>()

        // Primero, qué cambió. Y en cada proyecto git, de qué lado se movieron las ramas (HEAD, refs/, packed-refs).
        var cambiadas: [(r: String, h: Entrada?, p: Entrada?, enHub: Bool, enPortatil: Bool)] = []
        var refsDelHub = Set<String>(), refsDelPortatil = Set<String>(), distintos = Set<String>()
        for r in rutas {
            if hayNoLeidas, Foto.noLeida(r, en: noLeidas) { continue }
            let h = hub.entradas[r], p = portatil.entradas[r], b = base.registros[r]
            let cambioHub = cambio(h, b, .hub), cambioPortatil = cambio(p, b, .portatil)
            guard cambioHub || cambioPortatil else { continue }
            cambiadas.append((r, h, p, cambioHub, cambioPortatil))
            guard let repo = repoDe(r), esRama(r) else { continue }
            switch (cambioHub, cambioPortatil) {
            case (true, false): refsDelHub.insert(repo)
            case (false, true): refsDelPortatil.insert(repo)
            default:
                // La misma rama cambió distinto de los dos lados: commits distintos.
                if let h, let p, iguales(h, p, ruta: r, mismoContenido: mismoContenido) { continue }
                distintos.insert(repo)
            }
        }

        for (r, h, p, cambioHub, cambioPortatil) in cambiadas {
            // Commits distintos: su .git queda como está en cada disco (ni se copia ni se anota).
            if let repo = repoDe(r), distintos.contains(repo) { continue }

            switch (cambioHub, cambioPortatil) {
            case (false, false):
                continue
            case (true, false):
                llevar.append(Paso(ruta: r, lado: .hub))
            case (false, true):
                llevar.append(Paso(ruta: r, lado: .portatil))
            case (true, true):
                guard let h else {
                    if p == nil { plan.olvidar.append(r) } else {
                        llevar.append(Paso(ruta: r, lado: .portatil))
                        if p?.tipo == .archivo { plan.resumen.recuperados.append(r) }
                    }
                    continue
                }
                guard let p else {
                    llevar.append(Paso(ruta: r, lado: .hub))
                    if h.tipo == .archivo { plan.resumen.recuperados.append(r) }
                    continue
                }
                if iguales(h, p, ruta: r, mismoContenido: mismoContenido) {
                    plan.anotar.append(r)
                    continue
                }
                var ganador = elegirGanador(h, p)
                if let repo = repoDe(r) {
                    // Adentro de .git no se crean copias "(conflicto)": romperían el repo. Gana el lado que hizo commit
                    // (así índice, historial y rama quedan del mismo lado) o, si ninguno, el más nuevo; lo otro queda
                    // en la papelera.
                    let hub = refsDelHub.contains(repo), portatil = refsDelPortatil.contains(repo)
                    if hub != portatil { ganador = hub ? .hub : .portatil }
                    repos.insert(repo)
                    llevar.append(Paso(ruta: r, lado: ganador))
                } else {
                    plan.conflictos.append(Paso(ruta: r, lado: ganador))
                    plan.resumen.conflictos.append(r)
                }
            }
        }

        // Clasificar lo que se lleva: copiar, crear carpeta o mandar a la papelera.
        var borrar: [Paso] = []
        for paso in llevar {
            let origen = paso.lado == .hub ? hub : portatil
            let destino = paso.lado.otro
            guard let e = origen.entradas[paso.ruta] else {
                borrar.append(Paso(ruta: paso.ruta, lado: destino))
                continue
            }
            if e.tipo == .carpeta {
                plan.carpetas.append(Paso(ruta: paso.ruta, lado: destino))
            } else {
                plan.copias.append(Paso(ruta: paso.ruta, lado: destino))
                if destino == .portatil {
                    plan.resumen.haciaPortatil += 1
                    plan.resumen.bytesHaciaPortatil = Rutas.sumar(plan.resumen.bytesHaciaPortatil, e.tamano)
                } else {
                    plan.resumen.haciaHub += 1
                    plan.resumen.bytesHaciaHub = Rutas.sumar(plan.resumen.bytesHaciaHub, e.tamano)
                }
            }
        }

        // Conflictos: el lado que pierde recibe la versión ganadora y la suya queda con otro nombre en los dos.
        for c in plan.conflictos {
            let e = (c.lado == .hub ? hub : portatil).entradas[c.ruta]
            if c.lado == .hub { plan.resumen.haciaPortatil += 1 } else { plan.resumen.haciaHub += 1 }
            if c.lado == .hub { plan.resumen.bytesHaciaPortatil = Rutas.sumar(plan.resumen.bytesHaciaPortatil, e?.tamano ?? 0) }
            else { plan.resumen.bytesHaciaHub = Rutas.sumar(plan.resumen.bytesHaciaHub, e?.tamano ?? 0) }
        }

        plan.borrar = agruparBorrados(borrar, hub: hub, portatil: portatil, resumen: &plan.resumen)
        plan.borrar.sort { $0.ruta.profundidad > $1.ruta.profundidad }
        plan.carpetas.sort { $0.ruta.profundidad < $1.ruta.profundidad }
        plan.copias.sort { $0.ruta < $1.ruta }
        plan.resumen.reposEnLosDosLados = repos.subtracting(distintos).sorted()
        plan.resumen.reposDistintos = distintos.sorted()
        plan.resumen.conflictos.sort()
        plan.resumen.recuperados.sort()
        return plan
    }

    /// Si se borró una carpeta entera, se manda a la papelera de una vez (incluso lo que no viaja, como
    /// `node_modules`). Pero si adentro hay algo nuevo del otro lado, la carpeta se conserva.
    private static func agruparBorrados(_ borrar: [Paso], hub: Foto, portatil: Foto, resumen: inout Resumen) -> [Paso] {
        var salida: [Paso] = []
        for lado in Lado.allCases {
            let foto = lado == .hub ? hub : portatil
            let rutas = Set(borrar.filter { $0.lado == lado }.map(\.ruta))
            guard !rutas.isEmpty else { continue }
            for r in rutas where foto.entradas[r]?.tipo == .archivo {
                let deGit = r.hasPrefix(".git/") || r.contains("/.git/")
                if lado == .hub {
                    resumen.aPapeleraHub += 1
                    if deGit { resumen.aPapeleraGitHub += 1 }
                } else {
                    resumen.aPapeleraPortatil += 1
                    if deGit { resumen.aPapeleraGitPortatil += 1 }
                }
            }
            // Carpetas que no se pueden borrar enteras porque algo de adentro se queda.
            var bloqueadas = Set<String>()
            for (r, _) in foto.entradas where !rutas.contains(r) {
                var padre = r.padre
                while !padre.isEmpty, bloqueadas.insert(padre).inserted { padre = padre.padre }
            }
            for nl in foto.noLeidas {
                var padre = nl
                while !padre.isEmpty, bloqueadas.insert(padre).inserted { padre = padre.padre }
            }
            var topes = Set<String>()
            for r in rutas.sorted(by: { $0.profundidad < $1.profundidad }) {
                if foto.entradas[r]?.tipo == .carpeta && bloqueadas.contains(r) { continue }
                var padre = r.padre, cubierta = false
                while !padre.isEmpty {
                    if topes.contains(padre) { cubierta = true; break }
                    padre = padre.padre
                }
                if cubierta { continue }
                topes.insert(r)
                salida.append(Paso(ruta: r, lado: lado))
            }
        }
        return salida
    }

    static func cambio(_ e: Entrada?, _ b: Registro?, _ lado: Lado) -> Bool {
        switch (e, b) {
        case (nil, nil): return false
        case (nil, _), (_, nil): return true
        case let (e?, b?): return !b.igual(e, lado: lado)
        }
    }

    static func iguales(_ h: Entrada, _ p: Entrada, ruta: String, mismoContenido: (String) -> Bool) -> Bool {
        guard h.tipo == p.tipo else { return false }
        switch h.tipo {
        case .carpeta: return true
        case .enlace: return h.destino == p.destino
        case .archivo:
            guard h.tamano == p.tamano, h.modo == p.modo else { return false }
            return h.mtime == p.mtime || mismoContenido(ruta)
        }
    }

    /// Ante cambios distintos en los dos lados: gana la carpeta sobre el archivo y, entre archivos, el más nuevo.
    static func elegirGanador(_ h: Entrada, _ p: Entrada) -> Lado {
        if h.tipo == .carpeta { return .hub }
        if p.tipo == .carpeta { return .portatil }
        if h.tipo != p.tipo { return h.tipo == .archivo ? .hub : .portatil }
        return p.mtime > h.mtime ? .portatil : .hub
    }

    /// Archivos de un `.git` que dicen a qué commit apunta cada rama: HEAD, refs/… y packed-refs.
    static func esRama(_ ruta: String) -> Bool {
        guard let r = ruta.range(of: ".git/", options: .backwards) else { return false }
        let adentro = ruta[r.upperBound...]
        // Las de otros (refs/remotes, que mueve un "fetch" del editor) no son commits tuyos: no cuentan.
        return adentro == "HEAD" || adentro == "packed-refs" || (adentro.hasPrefix("refs/") && !adentro.hasPrefix("refs/remotes/"))
    }

    /// Para rutas adentro de un `.git`, la carpeta del proyecto ("" si es la raíz).
    static func repoDe(_ ruta: String) -> String? {
        if ruta.hasPrefix(".git/") { return "" }
        guard let r = ruta.range(of: "/.git/") else { return nil }
        return String(ruta[..<r.lowerBound])
    }
}
