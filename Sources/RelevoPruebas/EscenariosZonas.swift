import Darwin
import Foundation
@testable import RelevoNucleo

/// Pruebas de la revisión por zonas (`Sincronizador.analizar(_:zonas:)`): mirar solo lo que avisó macOS tiene que
/// decidir exactamente lo mismo que mirar todo. Los avisos se arman a mano y lo más pobres posible (solo la carpeta
/// donde pasó cada cosa, como FSEvents), así se prueba lo peor: carpetas movidas, cambiadas por otra, borradas enteras.
extension Escenarios {
    static let porZonas: [(String, () throws -> Void)] = [
        ("Por zonas: cambios al azar deciden igual que revisar todo", { try Escenarios().zonasAlAzar(semilla: 1) }),
        // RELEVO_SEMILLAS=50 swift run RelevoPruebas azar → muchas más rondas (para cuando se toca el motor).
        ("Por zonas: más cambios al azar (otras semillas)", {
            let hasta = ProcessInfo.processInfo.environment["RELEVO_SEMILLAS"].flatMap { UInt64($0) } ?? 2
            for s in 2...max(2, hasta) where fallas.isEmpty { try Escenarios().zonasAlAzar(semilla: s) }
        }),
        ("Por zonas: carpeta cambiada por otra con el mismo nombre se mira entera", { try Escenarios().zonasIntercambio() }),
        ("Por zonas: commits distintos siguen protegidos aunque se toque solo el índice", { try Escenarios().zonasCommitsDistintos() }),
        ("Por zonas: lo que no se miró queda igual en la base", { try Escenarios().zonasConservaLaBase() }),
        ("Por zonas: sin base o sin la carpeta, mira todo", { try Escenarios().zonasSinCerteza() }),
    ]

    /// Cambios al azar de los dos lados, ronda tras ronda: la revisión por zonas tiene que armar el mismo plan que la
    /// entera y, después de copiar, la entera no tiene que encontrar nada pendiente.
    func zonasAlAzar(semilla: UInt64) throws {
        let b = Banco()
        var azar = Azar(semilla)
        var reloj = Date().timeIntervalSince1970 - 100_000
        let nombresCarpeta = ["d0", "d1", "d2"], nombresArchivo = ["f0", "f1", "f2"]

        // Escribe un archivo (creando sus carpetas) con una fecha única. Devuelve las carpetas que avisaría macOS.
        func escribir(_ lado: Lado, _ ruta: String) -> [String] {
            var avisos = [ruta.padreDePrueba]
            var c = ruta.padreDePrueba
            while !c.isEmpty, Escaner.entrada(b.ruta(lado, c)) == nil { avisos.append(c.padreDePrueba); c = c.padreDePrueba }
            if Escaner.entrada(b.ruta(lado, ruta))?.tipo == .carpeta { return [] }
            if let e = Escaner.entrada(b.ruta(lado, ruta.padreDePrueba)), e.tipo != .carpeta { return [] }
            reloj += 1
            let p = b.ruta(lado, ruta)
            guard (try? FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent,
                                                            withIntermediateDirectories: true)) != nil else { return [] }
            try? String(repeating: "x", count: azar.n(40)).write(toFile: p, atomically: false, encoding: .utf8)
            try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: reloj)], ofItemAtPath: p)
            return avisos
        }
        func existentes(_ lado: Lado, carpetas: Bool) -> [String] {
            let f = (try? Escaner.fotografiar(b.ruta(lado, ""), reglas: .porDefecto)) ?? Foto()
            return f.entradas.filter { ($0.value.tipo == .carpeta) == carpetas && !$0.key.contains(".git") }.keys.sorted()
        }
        func rutaAlAzar() -> String {
            var partes: [String] = []
            for _ in 0..<azar.n(3) { partes.append(nombresCarpeta[azar.n(nombresCarpeta.count)]) }
            partes.append(nombresArchivo[azar.n(nombresArchivo.count)])
            return partes.joined(separator: "/")
        }

        // Punto de partida, igual en los dos lados.
        for _ in 0..<25 { _ = escribir(.hub, rutaAlAzar()) }
        _ = escribir(.hub, ".git/refs/heads/main"); _ = escribir(.hub, ".git/HEAD"); _ = escribir(.hub, ".git/index")
        try b.sincronizar()

        for ronda in 0..<60 {
            var avisos = Set<String>()
            for _ in 0..<(1 + azar.n(4)) {
                let lado: Lado = azar.n(2) == 0 ? .hub : .portatil
                switch azar.n(10) {
                case 0, 1: avisos.formUnion(escribir(lado, rutaAlAzar()))
                case 2:   // modificar uno que ya está (a veces en los dos lados)
                    if let r = existentes(lado, carpetas: false).elegir(&azar) {
                        avisos.formUnion(escribir(lado, r))
                        if azar.n(4) == 0 { avisos.formUnion(escribir(lado.otro, r)) }
                    }
                case 3:   // borrar un archivo o una carpeta entera
                    let carpetas = azar.n(2) == 0
                    if let r = existentes(lado, carpetas: carpetas).elegir(&azar) {
                        try? FileManager.default.removeItem(atPath: b.ruta(lado, r))
                        avisos.insert(r.padreDePrueba)
                    }
                case 4:   // mover o renombrar una carpeta (adentro no queda ningún aviso)
                    if let r = existentes(lado, carpetas: true).elegir(&azar) {
                        let destino = (azar.n(2) == 0 ? "" : nombresCarpeta[azar.n(3)] + "/") + "m\(azar.n(3))"
                        guard Escaner.entrada(b.ruta(lado, destino)) == nil, !destino.estaDentroDePrueba(r) else { break }
                        let padre = b.ruta(lado, destino.padreDePrueba)
                        if Escaner.entrada(padre) == nil {
                            try? FileManager.default.createDirectory(atPath: padre, withIntermediateDirectories: true)
                            avisos.insert(destino.padreDePrueba.padreDePrueba)
                        }
                        if rename(b.ruta(lado, r), b.ruta(lado, destino)) == 0 {
                            avisos.insert(r.padreDePrueba); avisos.insert(destino.padreDePrueba)
                        }
                    }
                case 5:   // intercambiar dos carpetas: mismos nombres, contenido cambiado
                    let cs = existentes(lado, carpetas: true)
                    if cs.count >= 2, let a = cs.elegir(&azar), let c = cs.elegir(&azar), a != c,
                       !a.estaDentroDePrueba(c), !c.estaDentroDePrueba(a) {
                        let tmp = a.padreDePrueba.isEmpty ? "tmp-swap" : a.padreDePrueba + "/tmp-swap"
                        rename(b.ruta(lado, a), b.ruta(lado, tmp)); rename(b.ruta(lado, c), b.ruta(lado, a))
                        rename(b.ruta(lado, tmp), b.ruta(lado, c))
                        avisos.insert(a.padreDePrueba); avisos.insert(c.padreDePrueba)
                    }
                case 6:   // permisos
                    if let r = existentes(lado, carpetas: false).elegir(&azar) {
                        chmod(b.ruta(lado, r), azar.n(2) == 0 ? 0o755 : 0o600)
                        avisos.insert(r.padreDePrueba)
                    }
                case 7:   // enlace
                    let r = rutaAlAzar() + "-enlace"
                    if Escaner.entrada(b.ruta(lado, r.padreDePrueba))?.tipo == .carpeta || r.padreDePrueba.isEmpty {
                        symlink("f\(azar.n(3))", b.ruta(lado, r))
                        avisos.insert(r.padreDePrueba)
                    }
                case 8:   // git: commit (rama) o algo interno
                    let r = [".git/refs/heads/main", ".git/index", ".git/objects/a\(azar.n(3))/o", ".git/HEAD"][azar.n(4)]
                    avisos.formUnion(escribir(lado, r))
                default:  // el mismo archivo nuevo en los dos lados
                    let r = rutaAlAzar()
                    avisos.formUnion(escribir(lado, r))
                    avisos.formUnion(escribir(lado.otro, r))
                }
            }
            let entera = try b.sinc.analizar(b.carpeta)
            let parcial = try b.sinc.analizar(b.carpeta, zonas: Zonas(planas: avisos))
            let difieren = entera.plan.firmaDePrueba != parcial.plan.firmaDePrueba || entera.alertas != parcial.alertas
            if difieren || !parcial.porZonas {
                fallas.append("semilla \(semilla) ronda \(ronda): por zonas \(parcial.porZonas), avisos \(avisos.sorted())\n"
                              + "    entera:  \(entera.plan.firmaDePrueba) \(entera.alertas)\n"
                              + "    parcial: \(parcial.plan.firmaDePrueba) \(parcial.alertas)")
                return
            }
            let r = b.sinc.ejecutar(parcial, confirmado: true)
            if !r.completo {
                let detalle = r.enUso.map { u in
                    "\(u): foto hub \(String(describing: parcial.hub.entradas[u])) port \(String(describing: parcial.portatil.entradas[u])) "
                    + "ahora hub \(String(describing: Escaner.entrada(b.ruta(.hub, u)))) port \(String(describing: Escaner.entrada(b.ruta(.portatil, u)))) "
                    + "plan \(parcial.plan.firmaDePrueba)"
                }
                fallas.append("semilla \(semilla) ronda \(ronda): no terminó: \(r.problemas) \(detalle)"); return
            }
            let despues = try b.sinc.analizar(b.carpeta)
            if !despues.plan.vacio {
                fallas.append("semilla \(semilla) ronda \(ronda): quedó algo después de copiar por zonas: \(despues.plan.firmaDePrueba)")
                return
            }
        }
    }

    /// Dos carpetas que se intercambian el nombre: macOS solo avisa la carpeta de arriba, pero el contenido de las dos
    /// cambió. Con el número fijo de cada carpeta se nota y se miran enteras.
    func zonasIntercambio() throws {
        let b = Banco()
        b.escribir(.hub, "a/uno.txt", "de a", hace: 100)
        b.escribir(.hub, "b/dos.txt", "de b", hace: 100)
        try b.sincronizar()
        espero(try b.sincronizar().0.plan.vacio)   // segunda vuelta: anota el número fijo de las carpetas
        rename(b.ruta(.hub, "a"), b.ruta(.hub, "tmp")); rename(b.ruta(.hub, "b"), b.ruta(.hub, "a"))
        rename(b.ruta(.hub, "tmp"), b.ruta(.hub, "b"))
        let a = try b.sinc.analizar(b.carpeta, zonas: Zonas(planas: [""]))
        espero(a.porZonas)
        _ = b.sinc.ejecutar(a, confirmado: true)
        espero(b.leer(.portatil, "a/dos.txt") == "de b")
        espero(b.leer(.portatil, "b/uno.txt") == "de a")
        espero(!b.existe(.portatil, "a/uno.txt"))
        espero(try b.iguales())
    }

    /// Commits distintos en los dos lados y después un `git status` de un solo lado (cambia solo el índice): aunque el
    /// aviso sea solo la carpeta .git, las ramas se miran igual y el .git sigue sin tocarse.
    func zonasCommitsDistintos() throws {
        let b = Banco()
        b.escribir(.hub, ".git/refs/heads/main", "aaa", hace: 100)
        b.escribir(.hub, ".git/index", "indice-a", hace: 100)
        try b.sincronizar()
        b.escribir(.hub, ".git/refs/heads/main", "bbb", hace: 50)
        b.escribir(.portatil, ".git/refs/heads/main", "ccc", hace: 40)
        let (primera, _) = try b.sincronizar()
        espero(primera.plan.resumen.reposDistintos == [""])
        b.escribir(.hub, ".git/index", "indice-nuevo", hace: 5)
        let a = try b.sinc.analizar(b.carpeta, zonas: Zonas(planas: [".git"]))
        espero(a.porZonas)
        espero(a.plan.resumen.reposDistintos == [""])
        _ = b.sinc.ejecutar(a)
        espero(b.leer(.portatil, ".git/index") == "indice-a")
        espero(b.leer(.portatil, ".git/refs/heads/main") == "ccc")
    }

    /// Una copia por zonas reemplaza solo su parte de la base: todo lo demás sigue ahí, igual.
    func zonasConservaLaBase() throws {
        let b = Banco()
        for i in 0..<30 { b.escribir(.hub, "lejos/x\(i).txt", "\(i)", hace: 100) }
        b.escribir(.hub, "cerca/a.txt", "v1", hace: 100)
        try b.sincronizar()
        try b.sincronizar()
        let antes = Base.cargar(b.sinc.archivoBase(b.carpeta))!
        b.escribir(.hub, "cerca/a.txt", "v2", hace: 5)
        let a = try b.sinc.analizar(b.carpeta, zonas: Zonas(planas: ["cerca"]))
        espero(a.porZonas)
        espero(a.hub.entradas.keys.allSatisfy { !$0.hasPrefix("lejos/") })   // no miró lo que no cambió
        espero(a.plan.copias == [Paso(ruta: "cerca/a.txt", lado: .portatil)])
        _ = b.sinc.ejecutar(a)
        let despues = Base.cargar(b.sinc.archivoBase(b.carpeta))!
        espero(despues.registros.count == antes.registros.count)
        espero(despues.registros.filter { $0.key.hasPrefix("lejos") } == antes.registros.filter { $0.key.hasPrefix("lejos") })
        espero(despues.registros["cerca/a.txt"]?.tamano == 2 && despues.registros["cerca/a.txt"] != antes.registros["cerca/a.txt"])
        espero(try b.sinc.analizar(b.carpeta).plan.vacio)
        espero(b.leer(.portatil, "cerca/a.txt") == "v2")
    }

    /// Sin certeza no hay atajo: sin base (primera vez), sin la carpeta de un lado o si macOS pide revisar la raíz entera.
    func zonasSinCerteza() throws {
        let b = Banco()
        b.escribir(.hub, "a/x.txt", "x", hace: 100)
        espero(!(try b.sinc.analizar(b.carpeta, zonas: Zonas(planas: ["a"]))).porZonas)   // sin base
        try b.sincronizar()
        espero(!(try b.sinc.analizar(b.carpeta, zonas: Zonas(enteras: [""]))).porZonas)    // la raíz entera
        try FileManager.default.removeItem(atPath: b.ruta(.portatil, ""))
        let a = try b.sinc.analizar(b.carpeta, zonas: Zonas(planas: ["a"]))
        espero(!a.porZonas)
        espero(a.alertas == [.faltaCarpeta(.portatil)])
    }
}

/// Números al azar que se repiten con la misma semilla (para que una falla se pueda reproducir).
struct Azar {
    var estado: UInt64
    init(_ semilla: UInt64) { estado = semilla &* 0x9E37_79B9_7F4A_7C15 }
    mutating func n(_ tope: Int) -> Int {
        estado = estado &+ 0x9E37_79B9_7F4A_7C15
        var z = estado
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Int((z ^ (z >> 31)) % UInt64(max(1, tope)))
    }
}

extension Array {
    func elegir(_ azar: inout Azar) -> Element? { isEmpty ? nil : self[azar.n(count)] }
}

extension String {
    var padreDePrueba: String { (self as NSString).deletingLastPathComponent }
    func estaDentroDePrueba(_ c: String) -> Bool { self == c || hasPrefix(c + "/") }
}

extension Plan {
    /// Lo que decide el plan, sin importar el orden.
    var firmaDePrueba: String {
        func t(_ p: [Paso]) -> String { p.map { "\($0.lado.rawValue):\($0.ruta)" }.sorted().joined(separator: ",") }
        return "borrar[\(t(borrar))] conflictos[\(t(conflictos))] carpetas[\(t(carpetas))] copias[\(t(copias))] "
            + "repos[\(resumen.reposDistintos)|\(resumen.reposEnLosDosLados)] recuperados\(resumen.recuperados)"
    }
}
