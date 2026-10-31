import Darwin
import Foundation
@testable import RelevoNucleo

/// Cada prueba arma dos "discos" de ensayo (carpetas temporales) y una carpeta de estado, sincroniza y revisa.
final class Banco {
    let raiz: String
    let hub: String
    let portatil: String
    let estado: URL
    let carpeta = "Proyectos/Demo"

    init() {
        raiz = NSTemporaryDirectory() + "relevo-prueba-" + UUID().uuidString
        hub = raiz + "/hub"; portatil = raiz + "/portatil"
        estado = URL(fileURLWithPath: raiz + "/estado")
        try! FileManager.default.createDirectory(atPath: hub + "/" + carpeta, withIntermediateDirectories: true)
        try! FileManager.default.createDirectory(atPath: portatil, withIntermediateDirectories: true)
    }

    deinit {
        // Las pruebas dejan carpetas de solo lectura: abrirlas para poder borrar todo.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/chmod")
        p.arguments = ["-R", "u+w", raiz]
        try? p.run(); p.waitUntilExit()
        try? FileManager.default.removeItem(atPath: raiz)
    }

    /// Rutas que se saltean (como el .gitignore o las carpetas elegidas en "Lo que nunca se releva").
    var ignoradas: ((String) -> Set<String>)?
    /// Las reglas de lo que no viaja (por defecto, tampoco las dependencias).
    var reglas = Reglas.porDefecto
    var sinc: Sincronizador {
        let s = Sincronizador(volumenHub: hub, volumenPortatil: portatil, reglas: reglas, estado: estado)
        s.ignoradas = ignoradas
        return s
    }

    func ruta(_ lado: Lado, _ r: String) -> String { (lado == .hub ? hub : portatil) + "/" + carpeta + "/" + r }

    func escribir(_ lado: Lado, _ r: String, _ texto: String, hace segundos: Double = 0) {
        let p = ruta(lado, r)
        try! FileManager.default.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! texto.write(toFile: p, atomically: false, encoding: .utf8)
        if segundos != 0 {
            let fecha = Date().addingTimeInterval(-segundos)
            try! FileManager.default.setAttributes([.modificationDate: fecha], ofItemAtPath: p)
        }
    }

    func leer(_ lado: Lado, _ r: String) -> String? { try? String(contentsOfFile: ruta(lado, r), encoding: .utf8) }
    func existe(_ lado: Lado, _ r: String) -> Bool { Escaner.entrada(ruta(lado, r)) != nil }
    func borrar(_ lado: Lado, _ r: String) { try! FileManager.default.removeItem(atPath: ruta(lado, r)) }

    /// Copiar por zonas en vez de mirar todo (con avisos de todas las carpetas): las pruebas de siempre, de nuevo.
    nonisolated(unsafe) static var porZonas = false

    /// Todas las carpetas de los dos lados y de la base, como si macOS hubiera avisado cambios en cada una.
    func todasLasCarpetas() -> Zonas {
        var planas: Set<String> = [""]
        for lado in Lado.allCases {
            let f = (try? Escaner.fotografiar(ruta(lado, ""), reglas: .porDefecto)) ?? Foto()
            for (r, e) in f.entradas where e.tipo == .carpeta { planas.insert(r) }
        }
        for (r, reg) in Base.cargar(sinc.archivoBase(carpeta))?.registros ?? [:] where reg.tipo == .carpeta { planas.insert(r) }
        return Zonas(planas: planas)
    }

    @discardableResult
    func sincronizar(confirmado: Bool = false, cancelador: Cancelador = Cancelador(),
                     progreso: ((Progreso) -> Void)? = nil) throws -> (Analisis, Resultado) {
        let a = try sinc.analizar(carpeta, zonas: Banco.porZonas ? todasLasCarpetas() : nil)
        let r = sinc.ejecutar(a, confirmado: confirmado, cancelador: cancelador, progreso: progreso)
        return (a, r)
    }

    /// Lo que hay en la papelera de un lado (rutas relativas a la carpeta).
    func papelera(_ lado: Lado) -> [String] {
        let base = Sincronizador.papelera(lado == .hub ? hub : portatil)
        guard let sellos = try? FileManager.default.contentsOfDirectory(atPath: base) else { return [] }
        var salida: [String] = []
        for s in sellos {
            let raiz = base + "/" + s + "/" + carpeta
            let e = FileManager.default.enumerator(atPath: raiz)
            while let r = e?.nextObject() as? String {
                var esCarpeta: ObjCBool = false
                if FileManager.default.fileExists(atPath: raiz + "/" + r, isDirectory: &esCarpeta), !esCarpeta.boolValue { salida.append(r) }
            }
        }
        return salida.sorted()
    }

    /// Las dos carpetas tienen lo mismo (sin contar lo excluido).
    func iguales() throws -> Bool {
        let h = try Escaner.fotografiar(hub + "/" + carpeta, reglas: .porDefecto)
        let p = try Escaner.fotografiar(portatil + "/" + carpeta, reglas: .porDefecto)
        guard Set(h.entradas.keys) == Set(p.entradas.keys) else { return false }
        for (r, e) in h.entradas where e.tipo == .archivo {
            guard let o = p.entradas[r], o.tamano == e.tamano, o.mtime == e.mtime,
                  Sincronizador.mismoContenido(ruta(.hub, r), ruta(.portatil, r)) else { return false }
        }
        return true
    }
}

struct Escenarios {
    static let todas: [(String, () throws -> Void)] = [
        ("Cuando git se ordena solo (gc) no frena por muchos borrados", { try Escenarios().ordenDeGitNoFrena() }),
        ("Respeta el .gitignore, pero los .env viajan siempre", { try Escenarios().ignoradasPorGitignore() }),
        ("Archivos sueltos de una carpeta, sin entrar a las subcarpetas", { try Escenarios().archivosSueltos() }),
        ("Revisar a fondo encuentra una copia dañada y se repara desde el hub", { try Escenarios().revisarAFondo() }),
        ("Carpetas de solo lectura: se copian adentro y quedan con su permiso", { try Escenarios().carpetasSoloLectura() }),
        ("Archivos perdidos tras un desenchufe brusco se vuelven a copiar (no se borran del hub)", { try Escenarios().perdidosTrasDesenchufe() }),
        ("Si expulsaste bien, lo que borraste afuera se borra en el hub", { try Escenarios().borradoDespuesDeExpulsarBien() }),
        ("Lo que editaste afuera no se pisa con la copia vieja", { try Escenarios().editadoAfueraNoSePisa() }),
        ("La primera vez copia todo al portátil, con fechas y permisos", { try Escenarios().primeraVez() }),
        ("Solo copia lo nuevo o cambiado, en el sentido correcto", { try Escenarios().soloLoNuevo() }),
        ("Lo borrado de un lado va a la papelera del otro (nunca se borra del todo)", { try Escenarios().borrados() }),
        ("Borrado de un lado y modificado del otro: se conserva lo modificado", { try Escenarios().borradoVsModificado() }),
        ("Carpeta borrada en el hub pero con algo nuevo adentro en el portátil: se conserva", { try Escenarios().carpetaConAlgoNuevo() }),
        ("Cambios distintos en los dos lados: se guardan las dos versiones", { try Escenarios().conflicto() }),
        ("Mismo cambio en los dos lados: no es conflicto", { try Escenarios().mismoCambio() }),
        ("Commits distintos en los dos discos: el .git no se toca y se avisa", { try Escenarios().commitsDistintosEnGit() }),
        ("Commit de un solo lado: todo el .git viene de ese lado", { try Escenarios().commitDeUnLadoEnGit() }),
        ("Un fetch del editor (refs/remotes) no cuenta como commits distintos", { try Escenarios().fetchNoEsCommitDistinto() }),
        ("Borrado de un lado con commits nuevos del otro: no va entero a la papelera", { try Escenarios().borradoConCommitsDistintos() }),
        ("No lleva lo regenerable ni candados de git", { try Escenarios().exclusiones() }),
        ("Llevando dependencias, las de las copias de trabajo de Claude no viajan (ni se borran)", { try Escenarios().dependenciasDeCopiasDeTrabajo() }),
        ("Una base de datos prendida no se copia ni se borra; al apagarse viaja entera", { try Escenarios().baseDeDatosPrendida() }),
        ("Un emulador o una máquina virtual prendida no se copia; al apagarse viaja una vez", { try Escenarios().maquinaVirtualPrendida() }),
        ("De un archivo grande, la papelera guarda solo la última versión pisada", { try Escenarios().unaSolaVersionGrande() }),
        ("Enlaces simbólicos viajan como enlaces", { try Escenarios().enlaces() }),
        ("Muchos borrados de golpe: frena y pide OK", { try Escenarios().frenoBorrados() }),
        ("Si falta la carpeta entera en un lado, frena", { try Escenarios().faltaCarpeta() }),
        ("Confirmado: la carpeta borrada se va entera a la papelera del otro lado y no vuelve", { try Escenarios().faltaCarpetaConfirmada() }),
        ("Una carpeta puntual que no se releva no se borra ni viaja lo nuevo", { try Escenarios().carpetaPuntualQueNoSeReleva() }),
        ("Si el disco no está, no hace nada", { try Escenarios().discoAusente() }),
        ("Cortado a mitad: lo hecho queda bien, nada a medias, y la próxima termina", { try Escenarios().cortadoAMitad() }),
        ("Una copia que quedó mal tras un corte se detecta con el diario y se rehace", { try Escenarios().reparacionConDiario() }),
        ("Restos de copias cortadas se limpian", { try Escenarios().limpiaTemporales() }),
        ("Un archivo que cambia mientras se copia no se lleva a medias", { try Escenarios().cambiaMientras() }),
        ("Archivo convertido en carpeta y al revés", { try Escenarios().cambioDeTipo() }),
        ("La base sobrevive y se recupera desde la copia del portátil", { try Escenarios().baseDeRespaldo() }),
    ]

    func primeraVez() throws {
        let b = Banco()
        b.escribir(.hub, "a.txt", "hola")
        b.escribir(.hub, "src/b.swift", "codigo")
        b.escribir(.hub, "vacia/.gitkeep", "")
        chmod(b.ruta(.hub, "a.txt"), 0o755)
        let (a, r) = try b.sincronizar()
        espero(a.plan.resumen.haciaPortatil == 3)
        espero(r.completo)
        if !r.completo { print("  DEBUG", r) }
        espero(b.leer(.portatil, "src/b.swift") == "codigo")
        espero(Escaner.entrada(b.ruta(.portatil, "a.txt"))?.modo == 0o755)
        espero(try b.iguales())
        // La segunda vez no hay nada que hacer.
        let (a2, _) = try b.sincronizar()
        espero(a2.plan.vacio)
    }

    func soloLoNuevo() throws {
        let b = Banco()
        for i in 0..<50 { b.escribir(.hub, "f\(i).txt", "v1 \(i)", hace: 100) }
        try b.sincronizar()
        b.escribir(.hub, "f3.txt", "hub cambió")
        b.escribir(.portatil, "f7.txt", "portátil cambió")
        b.escribir(.portatil, "nuevo/afuera.md", "hecho afuera")
        let (a, r) = try b.sincronizar()
        espero(a.plan.resumen.haciaPortatil == 1)
        espero(a.plan.resumen.haciaHub == 2)
        espero(r.copiados == 3)
        espero(b.leer(.portatil, "f3.txt") == "hub cambió")
        espero(b.leer(.hub, "f7.txt") == "portátil cambió")
        espero(b.leer(.hub, "nuevo/afuera.md") == "hecho afuera")
        // La versión pisada queda en la papelera.
        espero(b.papelera(.portatil) == ["f3.txt"])
        espero(b.papelera(.hub) == ["f7.txt"])
        espero(try b.iguales())
    }

    func borrados() throws {
        let b = Banco()
        b.escribir(.hub, "chau.txt", "x")
        b.escribir(.hub, "carpeta/uno.txt", "1")
        b.escribir(.hub, "carpeta/sub/dos.txt", "2")
        b.escribir(.hub, "queda.txt", "q")
        try b.sincronizar()
        b.borrar(.hub, "chau.txt")
        b.borrar(.hub, "carpeta")
        let (a, r) = try b.sincronizar()
        espero(a.plan.resumen.aPapeleraPortatil == 3)
        espero(a.plan.borrar.count == 2)   // la carpeta va entera, de una
        espero(r.completo)
        if !r.completo || a.plan.borrar.count != 2 { print("  DEBUG", a.plan.borrar, r) }
        espero(!b.existe(.portatil, "chau.txt") && !b.existe(.portatil, "carpeta"))
        espero(b.papelera(.portatil) == ["carpeta/sub/dos.txt", "carpeta/uno.txt", "chau.txt"])
        espero(b.existe(.portatil, "queda.txt"))
    }

    func borradoVsModificado() throws {
        let b = Banco()
        b.escribir(.hub, "nota.txt", "v1", hace: 50)
        try b.sincronizar()
        b.borrar(.hub, "nota.txt")
        b.escribir(.portatil, "nota.txt", "v2 afuera")
        let (a, _) = try b.sincronizar()
        espero(a.plan.resumen.recuperados == ["nota.txt"])
        espero(b.leer(.hub, "nota.txt") == "v2 afuera")
    }

    func carpetaConAlgoNuevo() throws {
        let b = Banco()
        b.escribir(.hub, "proy/viejo.txt", "v")
        try b.sincronizar()
        b.borrar(.hub, "proy")
        b.escribir(.portatil, "proy/nuevo.txt", "n")
        let (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(!b.existe(.portatil, "proy/viejo.txt"))
        espero(b.leer(.hub, "proy/nuevo.txt") == "n")
        espero(try b.iguales())
    }

    func conflicto() throws {
        let b = Banco()
        b.escribir(.hub, "plan.md", "base", hace: 100)
        try b.sincronizar()
        b.escribir(.hub, "plan.md", "versión hub", hace: 20)
        b.escribir(.portatil, "plan.md", "versión portátil más nueva", hace: 5)
        let (a, r) = try b.sincronizar()
        espero(a.plan.resumen.conflictos == ["plan.md"])
        espero(r.conflictos == ["plan.md"])
        // Gana la más nueva (portátil); la del hub queda con otro nombre en los dos lados.
        espero(b.leer(.hub, "plan.md") == "versión portátil más nueva")
        espero(b.leer(.portatil, "plan.md") == "versión portátil más nueva")
        let copias = try FileManager.default.contentsOfDirectory(atPath: b.ruta(.hub, "")).filter { $0.contains("conflicto hub") }
        espero(copias.count == 1)
        espero(b.leer(.portatil, copias[0]) == "versión hub")
        espero(try b.iguales())
        let (a2, _) = try b.sincronizar()
        espero(a2.plan.vacio)
    }

    func mismoCambio() throws {
        let b = Banco()
        b.escribir(.hub, "x.txt", "igual", hace: 30)
        b.escribir(.portatil, "x.txt", "igual", hace: 10)
        let (a, _) = try b.sincronizar()
        espero(a.plan.vacio)
        espero(a.plan.anotar == ["x.txt"])
    }

    /// Commits distintos en los dos discos (la misma rama apunta a commits distintos): el .git de ese proyecto no se
    /// toca, para no mezclar las dos historias; los archivos del proyecto se relevan igual.
    func commitsDistintosEnGit() throws {
        let b = Banco()
        b.escribir(.hub, ".git/refs/heads/main", "aaa", hace: 100)
        b.escribir(.hub, ".git/index", "indice-a", hace: 100)
        b.escribir(.hub, "app.swift", "v1", hace: 100)
        try b.sincronizar()
        b.escribir(.hub, ".git/refs/heads/main", "bbb", hace: 20)
        b.escribir(.hub, ".git/index", "indice-b", hace: 20)
        b.escribir(.hub, ".git/objects/bb/1", "objeto-b", hace: 20)
        b.escribir(.portatil, ".git/refs/heads/main", "ccc", hace: 5)
        b.escribir(.portatil, ".git/index", "indice-c", hace: 5)
        b.escribir(.portatil, "app.swift", "v2", hace: 5)
        let (a, _) = try b.sincronizar()
        espero(a.plan.resumen.reposDistintos == [""])
        espero(a.plan.resumen.reposEnLosDosLados.isEmpty)
        espero(b.leer(.hub, ".git/refs/heads/main") == "bbb")
        espero(b.leer(.portatil, ".git/refs/heads/main") == "ccc")
        espero(b.leer(.portatil, ".git/index") == "indice-c")
        espero(b.leer(.portatil, ".git/objects/bb/1") == nil)
        // A la papelera va solo la versión vieja de app.swift (reemplazada): nada de adentro del .git.
        espero(b.papelera(.hub) == ["app.swift"] && b.papelera(.portatil).isEmpty)
        espero(b.leer(.hub, "app.swift") == "v2")
        // Y la próxima vez sigue avisando hasta que se unan con git.
        let (a2, _) = try b.sincronizar()
        espero(a2.plan.resumen.reposDistintos == [""])
    }

    /// Un "fetch" del editor mueve refs/remotes distinto en cada lado: no son commits tuyos, no frena el .git.
    func fetchNoEsCommitDistinto() throws {
        let b = Banco()
        b.escribir(.hub, ".git/refs/remotes/origin/main", "r1", hace: 100)
        try b.sincronizar()
        b.escribir(.hub, ".git/refs/remotes/origin/main", "r2", hace: 20)
        b.escribir(.portatil, ".git/refs/remotes/origin/main", "r3", hace: 5)
        let (a, _) = try b.sincronizar()
        espero(a.plan.resumen.reposDistintos.isEmpty)
        espero(b.leer(.hub, ".git/refs/remotes/origin/main") == "r3")
    }

    /// Borraste el proyecto de un lado y del otro tiene commits nuevos: aunque confirmes, no va entero a la papelera.
    func borradoConCommitsDistintos() throws {
        let b = Banco()
        b.escribir(.hub, ".git/refs/heads/main", "aaa", hace: 100)
        b.escribir(.hub, "app.swift", "v1", hace: 100)
        try b.sincronizar()
        b.escribir(.portatil, ".git/refs/heads/main", "bbb", hace: 5)
        try FileManager.default.removeItem(atPath: b.hub + "/" + b.carpeta)
        try b.sincronizar(confirmado: true)
        espero(b.leer(.portatil, ".git/refs/heads/main") == "bbb")
    }

    /// Commit de un solo lado y del otro solo cambió el índice (un `git status`): todo el .git viene del lado del commit,
    /// aunque el índice del otro lado sea más nuevo (si no, la rama quedaría con el índice viejo).
    func commitDeUnLadoEnGit() throws {
        let b = Banco()
        b.escribir(.hub, "Proyectos/A/.git/refs/heads/main", "aaa", hace: 100)
        b.escribir(.hub, "Proyectos/A/.git/index", "indice-a", hace: 100)
        try b.sincronizar()
        b.escribir(.hub, "Proyectos/A/.git/refs/heads/main", "bbb", hace: 30)
        b.escribir(.hub, "Proyectos/A/.git/index", "indice-b", hace: 30)
        b.escribir(.portatil, "Proyectos/A/.git/index", "indice-status", hace: 5)
        let (a, _) = try b.sincronizar()
        espero(a.plan.resumen.reposDistintos.isEmpty)
        espero(a.plan.resumen.reposEnLosDosLados == ["Proyectos/A"])
        espero(b.leer(.portatil, "Proyectos/A/.git/refs/heads/main") == "bbb")
        espero(b.leer(.portatil, "Proyectos/A/.git/index") == "indice-b")
        espero(b.leer(.hub, "Proyectos/A/.git/index") == "indice-b")
    }

    func exclusiones() throws {
        let b = Banco()
        b.escribir(.hub, "node_modules/react/index.js", "x")
        b.escribir(.hub, "app/.next/cache.bin", "x")
        b.escribir(.hub, ".git/index.lock", "x")
        b.escribir(.hub, "Cargo.lock", "se lleva")
        b.escribir(.hub, ".DS_Store", "x")
        b.escribir(.hub, "app/page.tsx", "x")
        try b.sincronizar()
        espero(!b.existe(.portatil, "node_modules"))
        espero(!b.existe(.portatil, "app/.next"))
        espero(!b.existe(.portatil, ".git/index.lock"))
        espero(!b.existe(.portatil, ".DS_Store"))
        espero(b.existe(.portatil, "Cargo.lock"))
        espero(b.existe(.portatil, "app/page.tsx"))
    }

    func dependenciasDeCopiasDeTrabajo() throws {
        let b = Banco()
        b.reglas = Reglas(nombres: Reglas.regenerables.filter { !Reglas.dependencias.contains($0) })
        b.escribir(.hub, "node_modules/react/index.js", "se lleva")
        b.escribir(.hub, ".claude/worktrees/sesion/src/app.ts", "código de la copia")
        b.escribir(.hub, ".claude/worktrees/sesion/node_modules/react/index.js", "no viaja")
        b.escribir(.hub, ".claude/worktrees/sesion/apps/web/.venv/lib/x.py", "no viaja")
        b.escribir(.hub, "apps/.claude/worktrees/otra/node_modules/a.js", "no viaja")
        // Lo que ya había llegado antes al portátil se queda donde está (no se borra ni vuelve al hub).
        b.escribir(.portatil, ".claude/worktrees/vieja/node_modules/b.js", "de antes")
        let (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(b.leer(.portatil, "node_modules/react/index.js") == "se lleva")
        espero(b.leer(.portatil, ".claude/worktrees/sesion/src/app.ts") == "código de la copia")
        espero(!b.existe(.portatil, ".claude/worktrees/sesion/node_modules"))
        espero(!b.existe(.portatil, ".claude/worktrees/sesion/apps/web/.venv"))
        espero(!b.existe(.portatil, "apps/.claude/worktrees/otra/node_modules"))
        espero(b.existe(.portatil, ".claude/worktrees/vieja/node_modules/b.js"))
        espero(!b.existe(.hub, ".claude/worktrees/vieja/node_modules"))
        espero(b.papelera(.portatil).isEmpty && b.papelera(.hub).isEmpty)
    }

    func baseDeDatosPrendida() throws {
        let b = Banco()
        b.escribir(.hub, "app/main.ts", "uno")
        b.escribir(.hub, "datos/pg/base/1/tabla", "v1")
        b.escribir(.hub, "datos/pg/global/control", "c1")
        try b.sincronizar()
        espero(b.leer(.portatil, "datos/pg/base/1/tabla") == "v1")
        // Se prende (su postmaster.pid apunta a un proceso vivo: estas mismas pruebas) y cambia sin parar.
        b.escribir(.hub, "datos/pg/postmaster.pid", "\(getpid())\n/datos/pg\n")
        b.escribir(.hub, "datos/pg/base/1/tabla", "v2 a medio escribir")
        b.borrar(.hub, "datos/pg/global/control")
        b.escribir(.hub, "datos/pg/base/1/nueva", "n")
        b.escribir(.hub, "app/main.ts", "dos")
        var (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(b.leer(.portatil, "app/main.ts") == "dos")          // lo demás del proyecto viaja igual
        espero(b.leer(.portatil, "datos/pg/base/1/tabla") == "v1")  // la base, quieta en los dos lados
        espero(b.existe(.portatil, "datos/pg/global/control"))
        espero(!b.existe(.portatil, "datos/pg/base/1/nueva") && !b.existe(.portatil, "datos/pg/postmaster.pid"))
        espero(b.papelera(.portatil) == ["app/main.ts"])           // solo la versión vieja de lo que se reemplazó
        // Un postmaster.pid viejo (de un proceso que ya no existe) no la frena.
        b.escribir(.hub, "datos/pg/postmaster.pid", "99999999\n")
        espero(!Escaner.baseDeDatosPrendida(b.ruta(.hub, "datos/pg")))
        // Se apaga: viaja entera.
        b.borrar(.hub, "datos/pg/postmaster.pid")
        (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(b.leer(.portatil, "datos/pg/base/1/tabla") == "v2 a medio escribir")
        espero(b.existe(.portatil, "datos/pg/base/1/nueva") && !b.existe(.portatil, "datos/pg/global/control"))
        espero(try b.iguales())
    }

    func maquinaVirtualPrendida() throws {
        let b = Banco()
        b.escribir(.hub, "app/main.ts", "uno")
        b.escribir(.hub, "emu/Pixel.avd/userdata.qcow2", "disco 1")
        b.escribir(.hub, "emu/Pixel.avd/config.ini", "c")
        try b.sincronizar()
        espero(b.leer(.portatil, "emu/Pixel.avd/userdata.qcow2") == "disco 1")
        // Se prende: estas mismas pruebas hacen de programa de máquinas y tienen abierto su disco.
        var nombre = [CChar](repeating: 0, count: 256)
        proc_name(getpid(), &nombre, UInt32(nombre.count))
        let antes = Escaner.programasDeMaquinas
        Escaner.programasDeMaquinas.append(String(cString: nombre))
        defer { Escaner.programasDeMaquinas = antes }
        let disco = open(b.ruta(.hub, "emu/Pixel.avd/userdata.qcow2"), O_RDONLY)
        b.escribir(.hub, "emu/Pixel.avd/userdata.qcow2", "disco 2 a medio escribir")
        b.escribir(.hub, "emu/Pixel.avd/snapshots/ram.bin", "ram")
        b.borrar(.hub, "emu/Pixel.avd/config.ini")
        b.escribir(.hub, "app/main.ts", "dos")
        var (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(b.leer(.portatil, "app/main.ts") == "dos")                       // lo demás viaja igual
        espero(b.leer(.portatil, "emu/Pixel.avd/userdata.qcow2") == "disco 1")  // la máquina, quieta en los dos lados
        espero(b.existe(.portatil, "emu/Pixel.avd/config.ini") && !b.existe(.portatil, "emu/Pixel.avd/snapshots"))
        // Las zonas (la copia en vivo) tampoco entran.
        let fotoZonas = try Escaner.fotografiar(b.hub + "/" + b.carpeta, planas: [], enteras: ["emu/Pixel.avd/snapshots"],
                                                reglas: .porDefecto)
        espero(fotoZonas.noLeidas == ["emu/Pixel.avd"] && fotoZonas.entradas.isEmpty)
        // Un archivo abierto fuera de una carpeta de máquina no frena nada.
        espero(!Escaner.maquinaVirtualPrendida(b.ruta(.hub, "emu")))
        // Se apaga: viaja entera, una vez.
        close(disco)
        (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(b.leer(.portatil, "emu/Pixel.avd/userdata.qcow2") == "disco 2 a medio escribir")
        espero(b.existe(.portatil, "emu/Pixel.avd/snapshots/ram.bin") && !b.existe(.portatil, "emu/Pixel.avd/config.ini"))
        espero(try b.iguales())
    }

    func unaSolaVersionGrande() throws {
        let antes = Ejecutor.unaSolaVersionDesde
        Ejecutor.unaSolaVersionDesde = 10
        defer { Ejecutor.unaSolaVersionDesde = antes }
        let b = Banco()
        b.escribir(.hub, "vm/disco.qcow2", "versión número 1")
        b.escribir(.hub, "chico.txt", "c1")
        try b.sincronizar()
        for n in 2...4 {
            b.escribir(.hub, "vm/disco.qcow2", "versión número \(n)")
            b.escribir(.hub, "chico.txt", "c\(n)")
            let (_, r) = try b.sincronizar()
            espero(r.completo)
        }
        espero(b.leer(.portatil, "vm/disco.qcow2") == "versión número 4")
        // Del grande queda solo la anterior; de lo chico, todas.
        let papelera = b.papelera(.portatil)
        espero(papelera.filter { $0.hasPrefix("vm/") }.count == 1)
        espero(papelera.filter { $0.hasPrefix("chico.txt") }.count == 3)
        let base = Sincronizador.papelera(b.portatil)
        let guardada = try FileManager.default.contentsOfDirectory(atPath: base).compactMap { s -> String? in
            let lugar = base + "/" + s + "/" + b.carpeta + "/vm"
            return (try? FileManager.default.contentsOfDirectory(atPath: lugar))?.first.map { lugar + "/" + $0 }
        }
        espero(guardada.count == 1 && (try? String(contentsOfFile: guardada[0], encoding: .utf8)) == "versión número 3")
        espero(Ejecutor.esVersion("disco.qcow2 12", de: "disco.qcow2") && !Ejecutor.esVersion("disco.qcow2.lock", de: "disco.qcow2"))
    }

    func enlaces() throws {
        let b = Banco()
        b.escribir(.hub, "real.txt", "r")
        symlink("real.txt", b.ruta(.hub, "atajo"))
        try b.sincronizar()
        espero(Escaner.entrada(b.ruta(.portatil, "atajo"))?.tipo == .enlace)
        espero(Escaner.leerEnlace(b.ruta(.portatil, "atajo")) == "real.txt")
    }

    func frenoBorrados() throws {
        let b = Banco()
        for i in 0..<100 { b.escribir(.hub, "f\(i).txt", "\(i)") }
        try b.sincronizar()
        for i in 0..<80 { b.borrar(.hub, "f\(i).txt") }
        let (a, r) = try b.sincronizar()
        espero(a.alertas == [.muchosBorrados(.portatil, 80)])
        espero(r.cancelado)
        espero(b.existe(.portatil, "f0.txt"))
        let (_, r2) = try b.sincronizar(confirmado: true)
        espero(r2.aPapelera == 80)
    }

    func faltaCarpeta() throws {
        let b = Banco()
        for i in 0..<3 { b.escribir(.hub, "f\(i).txt", "\(i)") }
        try b.sincronizar()
        try FileManager.default.removeItem(atPath: b.hub + "/" + b.carpeta)
        let (a, r) = try b.sincronizar()
        espero(a.alertas.contains(.faltaCarpeta(.hub)))
        espero(r.cancelado)
        espero(b.existe(.portatil, "f1.txt"))
    }

    /// Confirmado el borrado de la carpeta entera: del otro lado se va entera a la papelera y no vuelve a aparecer.
    func faltaCarpetaConfirmada() throws {
        let b = Banco()
        for i in 0..<3 { b.escribir(.hub, "f\(i).txt", "\(i)") }
        try b.sincronizar()
        try FileManager.default.createDirectory(atPath: b.ruta(.portatil, "node_modules/x"), withIntermediateDirectories: true)
        try FileManager.default.removeItem(atPath: b.hub + "/" + b.carpeta)
        try b.sincronizar(confirmado: true)
        espero(Escaner.entrada(b.portatil + "/" + b.carpeta) == nil)
        espero(Set(b.papelera(.portatil)).isSuperset(of: ["f0.txt", "f1.txt", "f2.txt"]))
        let (a, _) = try b.sincronizar()
        espero(a.alertas.isEmpty)
        espero(Escaner.entrada(b.hub + "/" + b.carpeta) == nil)
    }

    /// Una carpeta puntual que se deja de relevar (elegida en "Lo que nunca se releva"): no se borra de ningún lado y
    /// lo nuevo de adentro no viaja.
    func carpetaPuntualQueNoSeReleva() throws {
        let b = Banco()
        b.escribir(.hub, "App/dist/x.js", "x")
        b.escribir(.hub, "App/src/a.swift", "a")
        try b.sincronizar()
        b.ignoradas = { _ in ["App/dist"] }
        b.escribir(.hub, "App/dist/y.js", "y")
        b.escribir(.hub, "App/src/b.swift", "b")
        let (a, _) = try b.sincronizar()
        espero(a.alertas.isEmpty)
        espero(b.existe(.hub, "App/dist/x.js") && b.existe(.portatil, "App/dist/x.js"))
        espero(!b.existe(.portatil, "App/dist/y.js"))
        espero(b.existe(.portatil, "App/src/b.swift"))
        espero(b.papelera(.hub).isEmpty && b.papelera(.portatil).isEmpty)
    }

    func discoAusente() throws {
        let b = Banco()
        b.escribir(.hub, "a.txt", "a")
        try b.sincronizar()
        try FileManager.default.removeItem(atPath: b.portatil)
        esperoError { _ = try b.sinc.analizar(b.carpeta) }
    }

    func cortadoAMitad() throws {
        let b = Banco()
        for i in 0..<400 { b.escribir(.hub, "d\(i % 10)/f\(i).txt", String(repeating: "x", count: 2000 + i)) }
        let cancelador = Cancelador()
        let (_, r) = try b.sincronizar(cancelador: cancelador) { p in
            if p.hechos >= 120 { cancelador.cancelar() }
        }
        espero(r.cancelado)
        espero(r.pendientes > 0)
        // Ningún temporal suelto ni archivo con contenido parcial.
        let foto = try Escaner.fotografiar(b.portatil + "/" + b.carpeta, reglas: .porDefecto)
        for (ruta, e) in foto.entradas where e.tipo == .archivo {
            espero(Sincronizador.mismoContenido(b.ruta(.hub, ruta), b.ruta(.portatil, ruta)))
        }
        let (a2, r2) = try b.sincronizar()
        espero(a2.plan.resumen.haciaPortatil == 400 - r.copiados)
        espero(r2.completo)
        espero(try b.iguales())
    }

    func perdidosTrasDesenchufe() throws {
        let b = Banco()
        for i in 0..<10 { b.escribir(.hub, "f\(i).txt", "contenido \(i)", hace: 60) }
        try b.sincronizar()
        // El portátil se sacó de golpe y perdió 3 de los archivos que acababa de recibir, y uno quedó con lo viejo.
        for i in 0..<3 { b.borrar(.portatil, "f\(i).txt") }
        b.escribir(.portatil, "f5.txt", "vie", hace: 3600)
        let (a, r) = try b.sincronizar()
        espero(a.reparar == 4)
        espero(a.plan.resumen.aPapeleraHub == 0)
        espero(r.completo)
        espero(try b.iguales())
        espero(b.leer(.hub, "f0.txt") == "contenido 0")
    }

    func borradoDespuesDeExpulsarBien() throws {
        let b = Banco()
        for i in 0..<10 { b.escribir(.hub, "f\(i).txt", "contenido \(i)", hace: 60) }
        try b.sincronizar()
        b.sinc.expulsadoBien(.portatil)
        // Afuera, borraste uno a propósito: al volver se borra también en el hub (a su papelera).
        b.borrar(.portatil, "f2.txt")
        let (a, _) = try b.sincronizar()
        espero(a.reparar == 0)
        espero(!b.existe(.hub, "f2.txt"))
        espero(b.papelera(.hub) == ["f2.txt"])
    }

    func editadoAfueraNoSePisa() throws {
        let b = Banco()
        b.escribir(.hub, "nota.txt", "v1", hace: 60)
        try b.sincronizar()
        // Sin expulsar bien, pero lo editaste afuera (fecha más nueva): es un cambio tuyo, se lleva al hub.
        b.escribir(.portatil, "nota.txt", "editado afuera, más largo")
        let (a, _) = try b.sincronizar()
        espero(a.reparar == 0)
        espero(b.leer(.hub, "nota.txt") == "editado afuera, más largo")
    }

    func carpetasSoloLectura() throws {
        let b = Banco()
        b.escribir(.hub, "congelada/sub/a.c", "a")
        b.escribir(.hub, "congelada/b.h", "b")
        chmod(b.ruta(.hub, "congelada/sub"), 0o555)
        chmod(b.ruta(.hub, "congelada"), 0o555)
        let (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(b.leer(.portatil, "congelada/sub/a.c") == "a")
        espero(Escaner.entrada(b.ruta(.portatil, "congelada"))?.modo == 0o555)
        espero(Escaner.entrada(b.ruta(.portatil, "congelada/sub"))?.modo == 0o555)
        // Después cambia algo adentro (en el hub se abre a mano, como haría quien la edita).
        chmod(b.ruta(.hub, "congelada"), 0o755)
        b.escribir(.hub, "congelada/nuevo.txt", "n")
        try FileManager.default.removeItem(atPath: b.ruta(.hub, "congelada/b.h"))
        chmod(b.ruta(.hub, "congelada"), 0o555)
        let (_, r2) = try b.sincronizar()
        espero(r2.completo)
        espero(b.leer(.portatil, "congelada/nuevo.txt") == "n")
        espero(!b.existe(.portatil, "congelada/b.h"))
        espero(Escaner.entrada(b.ruta(.portatil, "congelada"))?.modo == 0o555)
        espero(try b.iguales())
    }

    func archivosSueltos() throws {
        let b = Banco()
        b.escribir(.hub, "notas.md", "suelto")
        b.escribir(.hub, "ProyectoA/codigo.swift", "no va en este par")
        let s = b.sinc
        let a = try s.analizar(b.carpeta + "/.")
        let r = s.ejecutar(a)
        espero(r.completo)
        espero(b.leer(.portatil, "notas.md") == "suelto")
        espero(!b.existe(.portatil, "ProyectoA"))
        espero(r.cambios.map(\.ruta) == ["notas.md"])
        espero(r.cambios.first?.tipo == .copiado && r.cambios.first?.lado == .portatil)
    }

    func revisarAFondo() throws {
        let b = Banco()
        b.escribir(.hub, "a.txt", "contenido bueno", hace: 60)
        b.escribir(.hub, "b.txt", "otro", hace: 60)
        try b.sincronizar()
        // Se daña la copia del portátil sin cambiar tamaño ni fecha.
        let m = Escaner.entrada(b.ruta(.portatil, "a.txt"))!.mtime
        try "contenido malo".padding(toLength: 15, withPad: "!", startingAt: 0)
            .write(toFile: b.ruta(.portatil, "a.txt"), atomically: false, encoding: .utf8)
        var t = [timespec(tv_sec: Int(m / 1_000_000_000), tv_nsec: Int(m % 1_000_000_000)),
                 timespec(tv_sec: Int(m / 1_000_000_000), tv_nsec: Int(m % 1_000_000_000))]
        utimensat(AT_FDCWD, b.ruta(.portatil, "a.txt"), &t, 0)
        let (a0, _) = try b.sincronizar()
        espero(a0.plan.vacio)   // por fecha y tamaño parece igual
        let distintos = try b.sinc.revisarAFondo(b.carpeta)
        espero(distintos == ["a.txt"])
        try b.sinc.forzarCopia(b.carpeta, rutas: distintos, desde: .hub)
        let (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(b.leer(.portatil, "a.txt") == "contenido bueno")
        espero(b.papelera(.portatil) == ["a.txt"])
    }

    func ignoradasPorGitignore() throws {
        let b = Banco()
        b.escribir(.hub, "src/app.ts", "a")
        b.escribir(.hub, "dist/bundle.js", "compilado")
        b.escribir(.hub, ".env", "CLAVE=1")
        b.escribir(.hub, "debug.log", "ruido")
        let s = b.sinc
        s.ignoradas = { _ in ["dist", "debug.log", ".env"] }   // lo que diría git
        let a = try s.analizar(b.carpeta)
        let r = s.ejecutar(a)
        espero(r.completo)
        espero(b.existe(.portatil, "src/app.ts"))
        espero(!b.existe(.portatil, "dist"))
        espero(!b.existe(.portatil, "debug.log"))
        espero(b.leer(.portatil, ".env") == "CLAVE=1")   // las claves viajan siempre
    }

    func ordenDeGitNoFrena() throws {
        let b = Banco()
        for i in 0..<120 { b.escribir(.hub, ".git/objects/\(i % 16)/obj\(i)", "o\(i)") }
        b.escribir(.hub, "codigo.swift", "x")
        try b.sincronizar()
        for i in 0..<120 { b.borrar(.hub, ".git/objects/\(i % 16)/obj\(i)") }   // git gc: los junta en un pack
        b.escribir(.hub, ".git/objects/pack/pack-1.pack", "todo junto")
        let (a, r) = try b.sincronizar()
        espero(a.alertas.isEmpty)
        espero(r.completo)
        espero(b.existe(.portatil, ".git/objects/pack/pack-1.pack"))
    }

    func reparacionConDiario() throws {
        let b = Banco()
        b.escribir(.hub, "video.mov", String(repeating: "A", count: 50_000), hace: 60)
        try b.sincronizar()
        // Simula el peor caso: el disco se sacó y el archivo quedó con el nombre y la fecha bien pero contenido roto.
        let mtime = Escaner.entrada(b.ruta(.portatil, "video.mov"))!.mtime
        try String(repeating: "\0", count: 50_000).write(toFile: b.ruta(.portatil, "video.mov"), atomically: false, encoding: .utf8)
        var t = [timespec(tv_sec: Int(mtime / 1_000_000_000), tv_nsec: Int(mtime % 1_000_000_000)),
                 timespec(tv_sec: Int(mtime / 1_000_000_000), tv_nsec: Int(mtime % 1_000_000_000))]
        utimensat(AT_FDCWD, b.ruta(.portatil, "video.mov"), &t, 0)
        try "portatil\tvideo.mov\n".write(to: b.sinc.archivoDiario(b.carpeta), atomically: true, encoding: .utf8)

        let (a, r) = try b.sincronizar()
        espero(a.reparar == 1)
        espero(r.completo)
        espero(Sincronizador.mismoContenido(b.ruta(.hub, "video.mov"), b.ruta(.portatil, "video.mov")))
        espero(!FileManager.default.fileExists(atPath: b.sinc.archivoDiario(b.carpeta).path))
    }

    func limpiaTemporales() throws {
        let b = Banco()
        b.escribir(.hub, "a.txt", "a")
        try b.sincronizar()
        b.escribir(.portatil, ".a.txt.relevo-tmp", "resto")
        b.escribir(.hub, "b.txt", "b")
        try b.sincronizar()
        espero(!b.existe(.portatil, ".a.txt.relevo-tmp"))
    }

    func cambiaMientras() throws {
        let b = Banco()
        b.escribir(.hub, "log.txt", "uno")
        let a = try b.sinc.analizar(b.carpeta)
        b.escribir(.hub, "log.txt", "uno dos tres")   // cambió después de la foto
        let r = b.sinc.ejecutar(a)
        espero(r.enUso == ["log.txt"])
        // No quedó nada atrás de verdad: entra en la próxima pasada (así "Me voy" no revisa todo por esto).
        espero(!r.completo && r.completoSalvoEnUso)
        espero(!b.existe(.portatil, "log.txt"))
        let (_, r2) = try b.sincronizar()
        espero(r2.completo)
        espero(b.leer(.portatil, "log.txt") == "uno dos tres")
    }

    func cambioDeTipo() throws {
        let b = Banco()
        b.escribir(.hub, "cosa", "era archivo")
        b.escribir(.hub, "otra/adentro.txt", "x")
        try b.sincronizar()
        b.borrar(.hub, "cosa"); b.escribir(.hub, "cosa/ahora.txt", "carpeta")
        b.borrar(.hub, "otra"); b.escribir(.hub, "otra", "ahora archivo")
        let (_, r) = try b.sincronizar()
        espero(r.completo)
        espero(try b.iguales())
    }

    func baseDeRespaldo() throws {
        let b = Banco()
        b.escribir(.hub, "a.txt", "a", hace: 40)
        try b.sincronizar()
        try FileManager.default.removeItem(at: b.sinc.archivoBase(b.carpeta))
        b.escribir(.portatil, "a.txt", "cambio afuera")
        let (a, _) = try b.sincronizar()
        espero(a.plan.resumen.conflictos.isEmpty)
        espero(b.leer(.hub, "a.txt") == "cambio afuera")
    }
}
