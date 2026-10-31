import AppKit
import Combine
import Foundation

// Pestaña "Repositorios": ver los repos de GitHub (u otro proveedor git), bajarlos al hub o al portátil y ver cuáles
// están atrasados. Todo con `Process` y argumentos separados (nunca por una shell), en segundo plano y con tope de
// tiempo. Las credenciales son las del sistema (gh o el llavero de git): Relevo no guarda ningún token.

// MARK: - Modelos

/// Un repo de la lista de `gh repo list`.
struct RepoRemoto: Decodable, Identifiable, Hashable {
    let name: String
    let nameWithOwner: String
    let url: String
    let sshUrl: String?
    let isPrivate: Bool
    let updatedAt: String?
    let description: String?

    var id: String { nameWithOwner }
    var dueno: String { String(nameWithOwner.split(separator: "/").first ?? "") }
    var actualizado: Date? { updatedAt.flatMap { ISO8601DateFormatter().date(from: $0) } }
}

/// Un repo que ya está en el hub, con su estado (sin red, salvo después de "Buscar novedades").
struct RepoLocal: Identifiable, Hashable {
    let ruta: String
    let nombre: String
    let vinculoID: String
    /// Carpeta relativa a la raíz del hub donde está (por ejemplo "Proyectos").
    let carpetaPadre: String
    /// La carpeta que sincroniza Relevo y que lo contiene (para pedir que se releve después de actualizar).
    let par: String
    var rama: String?
    var remoto: String?
    var tieneSeguimiento = false
    var cambios = 0
    var sinSubir = 0
    var atrasados = 0
    var error: String?

    var id: String { ruta }
    var alDia: Bool { error == nil && cambios == 0 && sinSubir == 0 && atrasados == 0 }
    /// Para ocultarlo: el vínculo y la ruta adentro del hub (no cambia si el disco se monta con otro nombre).
    var claveOculto: String { vinculoID + "|" + (carpetaPadre.isEmpty ? nombre : carpetaPadre + "/" + nombre) }
}

/// Dónde se puede clonar: una carpeta que se sincroniza en el hub de un vínculo (por ejemplo "Proyectos").
struct DestinoClon: Identifiable, Hashable {
    let vinculoID: String
    /// Relativa a la raíz de cada lado.
    let base: String
    /// true si la carpeta se sincroniza "de a una" (`Proyectos/*`): cada repo nuevo es su propia carpeta relevada.
    let deAUna: Bool
    let descripcion: String

    var id: String { vinculoID + "|" + base }
    func par(_ nombre: String) -> String { deAUna ? base + "/" + nombre : base }
}

enum LadoClon: String, Identifiable, Hashable, CaseIterable {
    case hub, portatil
    var id: String { rawValue }
    var nombre: String { self == .hub ? T("Hub") : T("Portátil") }
}

/// Un archivo con cambios sin commit, dicho en simple.
struct ArchivoCambiado: Identifiable, Hashable {
    enum Tipo { case nuevo, modificado, borrado, renombrado, conflicto }
    let ruta: String
    let tipo: Tipo
    var id: String { ruta }
    var nombreTipo: String {
        switch tipo {
        case .nuevo: T("nuevo")
        case .modificado: T("modificado")
        case .borrado: T("borrado")
        case .renombrado: T("renombrado")
        case .conflicto: T("en conflicto")
        }
    }
}

// MARK: - Herramientas (git y gh)

enum HerramientasRepos {
    /// Dónde buscar. Nunca `/usr/bin/git`: si no están las herramientas de Apple, ese "git" abre un cartel para instalarlas.
    static func carpetas() -> [String] {
        var c = ["/opt/homebrew/bin", "/usr/local/bin", "/Library/Developer/CommandLineTools/usr/bin"]
        // La carpeta elegida con xcode-select se lee de su enlace (sin ejecutar nada).
        if let xcode = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            var esCarpeta: ObjCBool = false
            if FileManager.default.fileExists(atPath: xcode, isDirectory: &esCarpeta), esCarpeta.boolValue { c.append(xcode + "/usr/bin") }
        }
        return c
    }

    static func buscar(_ programa: String, en carpetas: [String]) -> String? {
        carpetas.map { $0 + "/" + programa }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// Lo que se sabe de git y gh en esta Mac.
struct EstadoHerramientas: Equatable {
    var git: String?
    var gh: String?
    /// nil = todavía no se revisó (o no hay gh).
    var ghConSesion: Bool?
    var cuentaGH: String?
}

// MARK: - Correr programas

enum ProcesoRepos {
    struct Resultado {
        var codigo: Int32 = -1
        var salida = ""
        var error = ""
        var vencido = false
        var noArranco = false
        var bien: Bool { codigo == 0 && !vencido && !noArranco }

        /// El error para mostrar: las últimas líneas de lo que dijo el programa.
        var mensaje: String {
            if noArranco { return T("No se pudo abrir el programa.") }
            if vencido { return T("Tardó demasiado y lo corté.") }
            let lineas = (error.isEmpty ? salida : error).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return lineas.suffix(4).joined(separator: "\n")
        }
    }

    /// Corre `programa` con sus argumentos (sin shell) y espera, como mucho, `tope` segundos.
    static func correr(_ programa: String, _ args: [String], en carpeta: String? = nil, tope: TimeInterval,
                       entorno: [String: String] = [:]) -> Resultado {
        var r = Resultado()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: programa)
        p.arguments = args
        if let carpeta { p.currentDirectoryURL = URL(fileURLWithPath: carpeta) }
        var env = ProcessInfo.processInfo.environment
        for (k, v) in entorno { env[k] = v }
        p.environment = env
        p.standardInput = FileHandle.nullDevice
        let tuboSalida = Pipe(), tuboError = Pipe()
        p.standardOutput = tuboSalida
        p.standardError = tuboError

        let termino = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in termino.signal() }
        do { try p.run() } catch { r.noArranco = true; return r }

        // Las dos salidas se leen en paralelo, así un programa que escribe mucho no se traba.
        let lecturas = DispatchGroup()
        var datosSalida = Data(), datosError = Data()
        lecturas.enter()
        DispatchQueue.global(qos: .utility).async { datosSalida = tuboSalida.fileHandleForReading.readDataToEndOfFile(); lecturas.leave() }
        lecturas.enter()
        DispatchQueue.global(qos: .utility).async { datosError = tuboError.fileHandleForReading.readDataToEndOfFile(); lecturas.leave() }

        if termino.wait(timeout: .now() + tope) == .timedOut {
            r.vencido = true
            p.terminate()
            if termino.wait(timeout: .now() + 3) == .timedOut { kill(p.processIdentifier, SIGKILL); _ = termino.wait(timeout: .now() + 2) }
        }
        // Algún hijo (ssh, git-remote-https) puede quedar con la salida abierta un rato: no esperarlo para siempre.
        _ = lecturas.wait(timeout: .now() + 3)
        r.codigo = p.isRunning ? -1 : p.terminationStatus
        r.salida = String(decoding: datosSalida, as: UTF8.self)
        r.error = String(decoding: datosError, as: UTF8.self)
        return r
    }
}

// MARK: - Direcciones

enum DireccionRepo {
    /// "https://github.com/Yo/App.git", "git@github.com:yo/app" y "ssh://git@github.com/yo/app" → "github.com/yo/app".
    static func normalizar(_ direccion: String) -> String {
        var s = direccion.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for prefijo in ["https://", "http://", "ssh://", "git://", "git+ssh://"] where s.hasPrefix(prefijo) {
            s.removeFirst(prefijo.count)
        }
        if let arroba = s.firstIndex(of: "@"), !s[..<arroba].contains("/") { s = String(s[s.index(after: arroba)...]) }
        // git@host:dueño/repo → host/dueño/repo (si lo que sigue a ":" no es un puerto).
        if let dosPuntos = s.firstIndex(of: ":"), !s[..<dosPuntos].contains("/") {
            let resto = s[s.index(after: dosPuntos)...]
            if let barra = resto.firstIndex(of: "/"), Int(resto[..<barra]) != nil {
                s = String(s[..<dosPuntos]) + String(resto[barra...])   // host:2222/dueño → host/dueño
            } else {
                s = String(s[..<dosPuntos]) + "/" + resto
            }
        }
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        return s
    }

    /// Solo direcciones de verdad: https, ssh (las dos formas) o una ruta de esta Mac. Nada que git pueda tomar como opción.
    static func esValida(_ d: String) -> Bool {
        let s = d.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, !s.hasPrefix("-"), !s.contains(" "), !s.contains("\n") else { return false }
        let l = s.lowercased()
        if l.hasPrefix("https://") || l.hasPrefix("http://") || l.hasPrefix("ssh://") || l.hasPrefix("file://") { return true }
        if s.hasPrefix("/") { return true }
        // usuario@host:ruta
        return s.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^/].*"#, options: .regularExpression) != nil
    }

    /// El nombre de la carpeta que va a tener al clonarlo.
    static func nombre(_ d: String) -> String? {
        var s = d.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix(".git") { s.removeLast(4) }
        let ultimo = s.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? ""
        return nombreSeguro(ultimo)
    }

    static func nombreSeguro(_ n: String) -> String? {
        guard !n.isEmpty, n != ".", n != "..", !n.hasPrefix("."), !n.contains("/") else { return nil }
        return n
    }

    static func esGitHub(_ d: String) -> Bool { normalizar(d).hasPrefix("github.com/") }
}

// MARK: - Lo que ve la pestaña

final class Repos: ObservableObject {
    /// Vive mientras la app está abierta: así la lista de GitHub no se vuelve a pedir cada vez que se abre la pestaña.
    static let compartido = Repos()

    struct Novedad: Equatable { let texto: String; let esError: Bool }

    @Published private(set) var herramientas = EstadoHerramientas()
    @Published private(set) var herramientasRevisadas = false
    @Published private(set) var remotos: [RepoRemoto] = []
    @Published private(set) var cargandoRemotos = false
    @Published private(set) var errorRemotos: String?
    @Published private(set) var remotosCargados = false
    @Published private(set) var locales: [RepoLocal] = []
    @Published private(set) var revisandoLocales = false
    @Published private(set) var buscandoNovedades = false
    @Published private(set) var ultimaBusqueda: Date?
    /// Lo que está haciendo cada repo ahora (por id de remoto, ruta de local o dirección pegada).
    @Published private(set) var trabajando: [String: String] = [:]
    @Published var novedad: Novedad?
    /// La carpeta elegida para clonar (id de `DestinoClon`).
    @Published var destinoElegido: String? {
        didSet { UserDefaults.standard.set(destinoElegido, forKey: "repos-destino") }
    }

    private let cola = DispatchQueue(label: "team.halyon.relevo.repos", qos: .userInitiated, attributes: .concurrent)
    private var carpetasPath: [String] = []

    init() {
        destinoElegido = UserDefaults.standard.string(forKey: "repos-destino")
    }

    // MARK: Entorno para git y gh

    /// Sin preguntas por la terminal (no hay terminal): si faltan credenciales, falla y se muestra el error.
    private func entorno() -> [String: String] {
        let path = (carpetasPath + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        var e = ["PATH": path, "GIT_TERMINAL_PROMPT": "0", "GH_PROMPT_DISABLED": "1", "GCM_INTERACTIVE": "never",
                 "GH_NO_UPDATE_NOTIFIER": "1"]
        if ProcessInfo.processInfo.environment["GIT_SSH_COMMAND"] == nil { e["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes" }
        return e
    }

    /// Para remotos de GitHub por https: usar la sesión de gh como credencial (sin guardar nada).
    private func credencialGH(_ direccion: String?) -> [String] {
        guard let gh = herramientas.gh, herramientas.ghConSesion == true, let d = direccion, DireccionRepo.esGitHub(d),
              d.lowercased().hasPrefix("https://") else { return [] }
        return ["-c", "credential.https://github.com.helper=", "-c", "credential.https://github.com.helper=!\(gh) auth git-credential"]
    }

    /// `sinCandados`: las consultas que Relevo hace solo (estado, ramas): además de no reescribir el índice, no corren
    /// nada que venga en la configuración del repo (ver `Git.opcionesSeguras`). Las acciones que tocás vos (commit,
    /// actualizar, unir) sí corren los hooks del proyecto, como en la terminal, pero sin el monitor de archivos.
    private func git(_ args: [String], en carpeta: String? = nil, tope: TimeInterval, sinCandados: Bool = false) -> ProcesoRepos.Resultado {
        guard let g = herramientas.git else { return ProcesoRepos.Resultado(noArranco: true) }
        var e = entorno()
        if sinCandados { e["GIT_OPTIONAL_LOCKS"] = "0" }   // `git status` no reescribe el índice (Relevo lo copiaría)
        let seguras = sinCandados ? Git.opcionesSeguras(carpeta, git: g) : ["-c", "core.fsmonitor=false"]
        return ProcesoRepos.correr(g, seguras + args, en: carpeta, tope: tope, entorno: e)
    }

    private func gh(_ args: [String], tope: TimeInterval) -> ProcesoRepos.Resultado {
        guard let g = herramientas.gh else { return ProcesoRepos.Resultado(noArranco: true) }
        return ProcesoRepos.correr(g, args, tope: tope, entorno: entorno())
    }

    private func enPrincipal(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

    private func avisar(_ texto: String, error: Bool) { enPrincipal { self.novedad = Novedad(texto: texto, esError: error) } }

    private func marcar(_ id: String, _ texto: String?) { enPrincipal { self.trabajando[id] = texto } }

    // MARK: Cargar

    /// Al abrir la pestaña: busca git y gh, revisa los repos del hub y, la primera vez, pide la lista de GitHub.
    func cargar(_ gestor: Gestor) {
        revisarHerramientas { [weak self] in
            guard let self else { return }
            self.revisarLocales(gestor)
            if !self.remotosCargados { self.cargarRemotos() }
        }
    }

    func revisarHerramientas(_ despues: (() -> Void)? = nil) {
        cola.async {
            let carpetas = HerramientasRepos.carpetas()
            var h = EstadoHerramientas()
            h.git = HerramientasRepos.buscar("git", en: carpetas)
            h.gh = HerramientasRepos.buscar("gh", en: carpetas)
            self.carpetasPath = Array(Set([h.git, h.gh].compactMap { $0.map { ($0 as NSString).deletingLastPathComponent } }))
            if let gh = h.gh {
                // `--active` mira solo la cuenta en uso (otra cuenta vencida no debe contar como "sin sesión").
                var r = ProcesoRepos.correr(gh, ["auth", "status", "--active", "--hostname", "github.com"], tope: 15, entorno: self.entorno())
                if !r.bien, (r.error + r.salida).contains("unknown flag") {
                    r = ProcesoRepos.correr(gh, ["auth", "status", "--hostname", "github.com"], tope: 15, entorno: self.entorno())
                }
                h.ghConSesion = r.bien
                if r.bien, let rango = (r.salida + r.error).range(of: #"account ([A-Za-z0-9-]+)"#, options: .regularExpression) {
                    h.cuentaGH = String((r.salida + r.error)[rango].dropFirst("account ".count))
                }
            }
            self.enPrincipal {
                self.herramientas = h
                self.herramientasRevisadas = true
                if h.ghConSesion != true { self.remotos = []; self.remotosCargados = false }
                despues?()
            }
        }
    }

    /// Lista de GitHub: los repos propios y los de las organizaciones (hasta 200 de cada uno).
    func cargarRemotos() {
        guard herramientas.gh != nil, herramientas.ghConSesion == true, !cargandoRemotos else { return }
        cargandoRemotos = true
        errorRemotos = nil
        cola.async {
            let campos = "name,nameWithOwner,url,sshUrl,isPrivate,updatedAt,description"
            var todos: [RepoRemoto] = []
            var error: String?
            let propios = self.gh(["repo", "list", "--limit", "200", "--json", campos], tope: 45)
            if propios.bien, let l = try? JSONDecoder().decode([RepoRemoto].self, from: Data(propios.salida.utf8)) {
                todos += l
            } else {
                error = propios.mensaje.isEmpty ? T("No pude leer la lista de GitHub.") : propios.mensaje
            }
            if error == nil {
                let orgs = self.gh(["api", "user/orgs", "--jq", ".[].login"], tope: 20)
                if orgs.bien {
                    for org in orgs.salida.split(separator: "\n").map(String.init) where !org.isEmpty && !org.hasPrefix("-") {
                        let r = self.gh(["repo", "list", org, "--limit", "200", "--json", campos], tope: 45)
                        if r.bien, let l = try? JSONDecoder().decode([RepoRemoto].self, from: Data(r.salida.utf8)) { todos += l }
                    }
                }
            }
            var vistos = Set<String>()
            todos = todos.filter { vistos.insert($0.nameWithOwner.lowercased()).inserted }
            todos.sort { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
            self.enPrincipal {
                self.remotos = todos
                self.errorRemotos = error
                self.cargandoRemotos = false
                self.remotosCargados = error == nil
            }
        }
    }

    // MARK: Repos del hub

    /// Carpetas candidatas: un nivel adentro de cada carpeta que se sincroniza en el hub (o la carpeta misma si es un repo).
    static func buscarLocales(_ gestor: Gestor) -> [RepoLocal] {
        var salida: [RepoLocal] = []
        var vistas = Set<String>()
        let fm = FileManager.default
        for c in gestor.coordinadores {
            guard let v = c.vinculo, let raiz = c.raizHub else { continue }
            for carpeta in v.carpetas where !carpeta.hasSuffix("/.") {
                let base = Coordinador.base(carpeta)
                let dir = base.isEmpty ? raiz : raiz + "/" + base
                if fm.fileExists(atPath: dir + "/.git") {
                    if vistas.insert(dir).inserted {
                        salida.append(RepoLocal(ruta: dir, nombre: (dir as NSString).lastPathComponent, vinculoID: v.id,
                                                carpetaPadre: (base as NSString).deletingLastPathComponent, par: carpeta))
                    }
                    continue
                }
                for n in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []).sorted() where !n.hasPrefix(".") {
                    let ruta = dir + "/" + n
                    var esCarpeta: ObjCBool = false
                    guard fm.fileExists(atPath: ruta, isDirectory: &esCarpeta), esCarpeta.boolValue,
                          fm.fileExists(atPath: ruta + "/.git"), vistas.insert(ruta).inserted else { continue }
                    let par = carpeta.hasSuffix("/*") ? base + "/" + n : carpeta
                    salida.append(RepoLocal(ruta: ruta, nombre: n, vinculoID: v.id, carpetaPadre: base, par: par))
                }
            }
        }
        return salida
    }

    /// Estado de un repo sin usar la red: rama, cambios sin commit y adelante/atrás de la última copia del remoto.
    func estado(_ repo: RepoLocal) -> RepoLocal {
        var r = repo
        let s = git(["status", "--porcelain=v2", "--branch"], en: repo.ruta, tope: 20, sinCandados: true)
        guard s.bien else { r.error = s.mensaje; return r }
        r.error = nil
        r.cambios = 0
        r.tieneSeguimiento = false
        r.sinSubir = 0
        r.atrasados = 0
        for linea in s.salida.split(separator: "\n") {
            if linea.hasPrefix("# branch.head ") {
                let h = String(linea.dropFirst("# branch.head ".count))
                r.rama = h == "(detached)" ? nil : h
            } else if linea.hasPrefix("# branch.upstream ") {
                r.tieneSeguimiento = true
            } else if linea.hasPrefix("# branch.ab ") {
                // "# branch.ab +2 -3": 2 sin subir, 3 atrasados.
                for parte in linea.dropFirst("# branch.ab ".count).split(separator: " ") {
                    if parte.hasPrefix("+") { r.sinSubir = Int(parte.dropFirst()) ?? 0 }
                    if parte.hasPrefix("-") { r.atrasados = Int(parte.dropFirst()) ?? 0 }
                }
            } else if !linea.hasPrefix("#") {
                r.cambios += 1
            }
        }
        let remoto = git(["config", "--get", "remote.origin.url"], en: repo.ruta, tope: 10, sinCandados: true)
        r.remoto = remoto.bien ? remoto.salida.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        return r
    }

    func revisarLocales(_ gestor: Gestor) {
        guard herramientas.git != nil, !revisandoLocales else { return }
        revisandoLocales = true
        let encontrados = Self.buscarLocales(gestor)
        cola.async {
            var lista = encontrados
            DispatchQueue.concurrentPerform(iterations: lista.count) { i in
                let e = self.estado(encontrados[i])
                objc_sync_enter(self); lista[i] = e; objc_sync_exit(self)
            }
            self.enPrincipal {
                self.locales = lista.sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
                self.revisandoLocales = false
            }
        }
    }

    /// "Buscar novedades": `git fetch` en cada repo del hub que tenga remoto. Solo cuando lo pide el usuario (usa la red).
    func buscarNovedades(_ gestor: Gestor) {
        guard herramientas.git != nil, !buscandoNovedades else { return }
        buscandoNovedades = true
        let lista = Self.buscarLocales(gestor)
        cola.async {
            var resultado = lista
            var fallados: [String] = []
            let grupo = DispatchGroup()
            let tope = DispatchSemaphore(value: 4)   // de a 4 por vez
            for (i, repo) in lista.enumerated() {
                tope.wait()
                grupo.enter()
                self.cola.async {
                    defer { tope.signal(); grupo.leave() }
                    var r = self.estado(repo)
                    if r.remoto != nil {
                        let f = self.git(self.credencialGH(r.remoto) + ["fetch", "--quiet"], en: repo.ruta, tope: 90)
                        if f.bien { r = self.estado(r) } else {
                            r.error = f.mensaje
                            objc_sync_enter(self); fallados.append(repo.nombre); objc_sync_exit(self)
                        }
                    }
                    objc_sync_enter(self); resultado[i] = r; objc_sync_exit(self)
                }
            }
            grupo.wait()
            self.enPrincipal {
                self.locales = resultado.sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
                self.buscandoNovedades = false
                self.ultimaBusqueda = Date()
                if !fallados.isEmpty {
                    self.novedad = Novedad(texto: T("No pude consultar: %@.", fallados.sorted().joined(separator: ", ")), esError: true)
                }
            }
        }
    }

    // MARK: Destinos

    /// Carpetas que se sincronizan en el hub de cada vínculo (las que son repos en sí no cuentan).
    static func destinos(_ gestor: Gestor) -> [DestinoClon] {
        var salida: [DestinoClon] = []
        let varios = gestor.coordinadores.count > 1
        for c in gestor.coordinadores {
            guard let v = c.vinculo else { continue }
            var bases = Set<String>()
            for carpeta in v.carpetas where !carpeta.hasSuffix("/.") {
                let base = Coordinador.base(carpeta)
                guard !base.isEmpty, bases.insert(base).inserted else { continue }
                if let raiz = c.raizHub, FileManager.default.fileExists(atPath: raiz + "/" + base + "/.git") { continue }
                let lugar = varios ? v.hub.descripcion + " › " + base : base
                salida.append(DestinoClon(vinculoID: v.id, base: base, deAUna: carpeta.hasSuffix("/*"), descripcion: lugar))
            }
        }
        return salida
    }

    /// El elegido, o la carpeta con más repos (por ejemplo "Proyectos").
    func destino(_ gestor: Gestor) -> DestinoClon? {
        let todos = Self.destinos(gestor)
        if let e = destinoElegido, let d = todos.first(where: { $0.id == e }) { return d }
        return todos.max { a, b in
            let na = locales.filter { $0.vinculoID == a.vinculoID && $0.carpetaPadre == a.base }.count
            let nb = locales.filter { $0.vinculoID == b.vinculoID && $0.carpetaPadre == b.base }.count
            return na < nb
        }
    }

    // MARK: Acciones

    /// ¿Ya está en el hub? Por el remoto (`origin`) o, si no tiene, por el nombre de la carpeta.
    func local(de remoto: RepoRemoto) -> RepoLocal? {
        let claves = Set([remoto.url, remoto.sshUrl].compactMap { $0 }.map(DireccionRepo.normalizar))
        return locales.first { l in l.remoto.map { claves.contains(DireccionRepo.normalizar($0)) } ?? false }
            ?? locales.first { $0.remoto == nil && $0.nombre.lowercased() == remoto.name.lowercased() }
    }

    /// Clona un repo de la lista de GitHub (con `gh repo clone`, que usa su propia sesión).
    func clonar(_ remoto: RepoRemoto, en destino: DestinoClon, lado: LadoClon, gestor: Gestor) {
        guard let nombre = DireccionRepo.nombreSeguro(remoto.name) else { return }
        clonar(id: remoto.id, nombre: nombre, destino: destino, lado: lado, gestor: gestor) { carpetaTemporal in
            if self.herramientas.gh != nil, self.herramientas.ghConSesion == true {
                return self.gh(["repo", "clone", remoto.nameWithOwner, carpetaTemporal, "--", "--quiet"], tope: 1800)
            }
            return self.git(self.credencialGH(remoto.url) + ["clone", "--quiet", "--", remoto.url, carpetaTemporal], tope: 1800)
        }
    }

    /// Clona una dirección pegada (GitHub, GitLab, Bitbucket, un servidor propio…).
    func clonar(direccion: String, en destino: DestinoClon, lado: LadoClon, gestor: Gestor) {
        let d = direccion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard DireccionRepo.esValida(d) else {
            novedad = Novedad(texto: T("Esa dirección no parece de un repositorio (https://… o git@…)."), esError: true); return
        }
        guard let nombre = DireccionRepo.nombre(d) else {
            novedad = Novedad(texto: T("No pude sacar el nombre del repositorio de esa dirección."), esError: true); return
        }
        clonar(id: d, nombre: nombre, destino: destino, lado: lado, gestor: gestor) { carpetaTemporal in
            self.git(self.credencialGH(d) + ["clone", "--quiet", "--", d, carpetaTemporal], tope: 1800)
        }
    }

    /// Clona primero en una carpeta temporal adentro de `.Relevo` (que nunca se sincroniza) y recién al terminar la mueve
    /// a su lugar: así Relevo no copia un repo a medio bajar.
    private func clonar(id: String, nombre: String, destino: DestinoClon, lado: LadoClon, gestor: Gestor,
                        correr: @escaping (String) -> ProcesoRepos.Resultado) {
        guard herramientas.git != nil else { return }
        guard trabajando[id] == nil else { return }
        guard let c = gestor.coordinador(destino.vinculoID) else { return }
        let raiz = lado == .hub ? c.raizHub : c.raizPortatil
        guard let raiz else {
            novedad = Novedad(texto: lado == .hub ? T("Conectá el hub para clonar ahí.") : T("Conectá el portátil para clonar ahí."), esError: true)
            return
        }
        let final = raiz + "/" + destino.base + "/" + nombre
        guard !FileManager.default.fileExists(atPath: final) else {
            novedad = Novedad(texto: T("Ya hay una carpeta “%@” en %@.", nombre, destino.base), esError: true); return
        }
        marcar(id, T("Clonando…"))
        let par = destino.par(nombre)
        cola.async {
            let fm = FileManager.default
            let temporal = raiz + "/.Relevo/Clonando/" + UUID().uuidString
            defer { try? fm.removeItem(atPath: temporal) }   // solo la carpeta temporal propia
            do { try fm.createDirectory(atPath: temporal, withIntermediateDirectories: true) } catch {
                self.marcar(id, nil); self.avisar(T("No pude escribir en el disco: %@", error.localizedDescription), error: true); return
            }
            let destinoTemporal = temporal + "/" + nombre
            let r = correr(destinoTemporal)
            guard r.bien, fm.fileExists(atPath: destinoTemporal + "/.git") else {
                self.marcar(id, nil)
                self.avisar(T("No se pudo clonar %@.", nombre) + "\n" + Self.explicar(r), error: true)
                return
            }
            do {
                try fm.createDirectory(atPath: (final as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
                guard !fm.fileExists(atPath: final) else { throw CocoaError(.fileWriteFileExists) }
                try fm.moveItem(atPath: destinoTemporal, toPath: final)
            } catch {
                self.marcar(id, nil)
                self.avisar(T("Se bajó, pero no pude ponerlo en %@: %@", destino.base, error.localizedDescription), error: true)
                return
            }
            self.enPrincipal {
                self.trabajando[id] = nil
                self.novedad = Novedad(texto: lado == .hub ? T("%@ quedó en el hub, en %@.", nombre, destino.base)
                                                           : T("%@ quedó en el portátil, en %@. Relevo lo copia al hub.", nombre, destino.base),
                                       esError: false)
                // Que Relevo lo releve ya, sin esperar.
                c.sincronizar([par], aMano: true)
                self.revisarLocales(gestor)
            }
        }
    }

    /// `git pull --ff-only`: si no se puede avanzar sin mezclar, avisa y no toca nada.
    func actualizar(_ repo: RepoLocal, gestor: Gestor) {
        guard herramientas.git != nil, trabajando[repo.id] == nil else { return }
        if repo.sinSubir > 0 && repo.atrasados > 0 {
            novedad = Novedad(texto: T("%@ tiene commits tuyos sin subir y commits nuevos del remoto: no se puede avanzar sin mezclar. No toqué nada; resolvelo en la terminal.", repo.nombre), esError: true)
            return
        }
        marcar(repo.id, T("Actualizando…"))
        cola.async {
            let r = self.git(self.credencialGH(repo.remoto) + ["pull", "--ff-only", "--no-rebase", "--quiet"], en: repo.ruta, tope: 300)
            let nuevo = self.estado(repo)
            self.enPrincipal {
                self.trabajando[repo.id] = nil
                if let i = self.locales.firstIndex(where: { $0.id == repo.id }) { self.locales[i] = nuevo }
                if r.bien {
                    self.novedad = Novedad(texto: T("%@ está al día.", repo.nombre), esError: false)
                    gestor.coordinador(repo.vinculoID)?.sincronizar([repo.par], aMano: true)
                } else {
                    self.novedad = Novedad(texto: T("No se pudo actualizar %@.", repo.nombre) + "\n" + Self.explicar(r), esError: true)
                }
            }
        }
    }

    /// El error de git, más una pista en castellano para los casos comunes.
    static func explicar(_ r: ProcesoRepos.Resultado) -> String {
        let t = (r.error + r.salida).lowercased()
        var pista: String?
        if t.contains("please tell me who you are") || t.contains("unable to auto-detect email") {
            pista = T("git no sabe tu nombre y correo para firmar el commit. En la terminal: git config --global user.name \"Tu nombre\" y git config --global user.email \"tu@correo\".")
        } else if t.contains("has no upstream") || t.contains("no upstream branch") {
            pista = T("Esta rama todavía no existe en el remoto.")
        } else if t.contains("[rejected]") || t.contains("fetch first") || t.contains("non-fast-forward") {
            pista = T("El remoto tiene commits que vos no tenés: primero tocá “Buscar novedades” y “Actualizar”. Relevo nunca fuerza la subida.")
        } else if t.contains("not possible to fast-forward") || t.contains("diverg") {
            pista = T("Tu copia y la del remoto tienen commits distintos: no se puede avanzar sin mezclar. No toqué nada; resolvelo en la terminal.")
        } else if t.contains("would be overwritten") {
            pista = T("Tenés cambios sin commit en archivos que el remoto también cambió. No toqué nada: hacé commit o guardalos antes.")
        } else if t.contains("authentication failed") || t.contains("could not read username") || t.contains("terminal prompts disabled") {
            pista = T("Falta iniciar sesión: en la terminal, “gh auth login” (GitHub) o guardá tus credenciales de git en el llavero.")
        } else if t.contains("host key verification failed") {
            pista = T("Es la primera vez que te conectás a ese servidor por ssh: conectate una vez desde la terminal (ssh -T) y aceptalo.")
        } else if t.contains("permission denied (publickey)") {
            pista = T("El servidor no aceptó tu llave ssh. Probá con la dirección https o agregá tu llave al proveedor.")
        } else if t.contains("dubious ownership") {
            pista = T("git no confía en esta carpeta porque el dueño es otro usuario (pasa en discos externos). Ver “git config --global --add safe.directory”.")
        } else if t.contains("repository not found") || t.contains("not found") {
            pista = T("No existe o no tenés acceso.")
        }
        return [r.mensaje, pista].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    static func abrirEnFinder(_ ruta: String) {
        Discos.mostrarEnFinder(ruta)
    }

    static func abrirEnTerminal(_ ruta: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ProcesoRepos.correr("/usr/bin/open", ["-a", "Terminal", ruta], tope: 15)
        }
    }

    /// Abre el instalador de las herramientas de Apple (trae git). Solo cuando lo toca el usuario.
    static func instalarHerramientasApple() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = ProcesoRepos.correr("/usr/bin/xcode-select", ["--install"], tope: 15)
        }
    }
}

// MARK: - Cambios, commit, subir y unir ramas

extension Repos {
    /// Los archivos con cambios sin commit (`git status --porcelain`), en simple.
    func archivosCambiados(_ repo: RepoLocal) -> [ArchivoCambiado] {
        let r = git(["status", "--porcelain=v1", "-z", "--untracked-files=all"], en: repo.ruta, tope: 20, sinCandados: true)
        guard r.bien else { return [] }
        var salida: [ArchivoCambiado] = []
        let partes = r.salida.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var i = 0
        while i < partes.count {
            let e = partes[i]
            i += 1
            guard e.count > 3 else { continue }
            let x = e[e.startIndex], y = e[e.index(after: e.startIndex)]
            let ruta = String(e.dropFirst(3))
            let tipo: ArchivoCambiado.Tipo
            if x == "U" || y == "U" || (x == "A" && y == "A") || (x == "D" && y == "D") { tipo = .conflicto }
            else if x == "?" || x == "A" { tipo = .nuevo }
            else if x == "D" || y == "D" { tipo = .borrado }
            else if x == "R" || x == "C" { tipo = .renombrado }
            else { tipo = .modificado }
            if x == "R" || x == "C" { i += 1 }   // con -z, después viene la ruta vieja
            salida.append(ArchivoCambiado(ruta: ruta, tipo: tipo))
        }
        return salida
    }

    /// Ramas locales (`git branch --format`).
    func ramas(_ repo: RepoLocal) -> [String] {
        let r = git(["branch", "--format=%(refname:short)"], en: repo.ruta, tope: 15, sinCandados: true)
        guard r.bien else { return [] }
        return r.salida.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && !$0.hasPrefix("(") }
    }

    /// Cuántos commits trae `origen` que `destino` no tiene (`git rev-list --count destino..origen`).
    func commitsQueTrae(_ repo: RepoLocal, origen: String, destino: String) -> Int? {
        guard Self.ramaValida(origen), Self.ramaValida(destino) else { return nil }
        let r = git(["rev-list", "--count", "refs/heads/\(destino)..refs/heads/\(origen)"], en: repo.ruta, tope: 15, sinCandados: true)
        return r.bien ? Int(r.salida.trimmingCharacters(in: .whitespacesAndNewlines)) : nil
    }

    static func ramaValida(_ n: String) -> Bool { !n.isEmpty && !n.hasPrefix("-") && !n.contains("..") && !n.contains(" ") }

    /// Lo que se muestra al abrir un repo: archivos cambiados y ramas. Se lee en segundo plano.
    func cargarDetalle(_ repo: RepoLocal, listo: @escaping ([ArchivoCambiado], [String]) -> Void) {
        cola.async {
            let a = self.archivosCambiados(repo), r = self.ramas(repo)
            self.enPrincipal { listo(a, r) }
        }
    }

    func contarCommits(_ repo: RepoLocal, origen: String, destino: String, listo: @escaping (Int?) -> Void) {
        cola.async {
            let n = self.commitsQueTrae(repo, origen: origen, destino: destino)
            self.enPrincipal { listo(n) }
        }
    }

    /// Después de escribir en git: refrescar su estado y que Relevo lo releve.
    private func terminar(_ repo: RepoLocal, _ texto: String, error: Bool, gestor: Gestor, listo: ((Bool) -> Void)?) {
        let nuevo = estado(repo)
        enPrincipal {
            self.trabajando[repo.id] = nil
            if let i = self.locales.firstIndex(where: { $0.id == repo.id }) { self.locales[i] = nuevo }
            self.novedad = Novedad(texto: texto, esError: error)
            gestor.coordinador(repo.vinculoID)?.sincronizar([repo.par], aMano: true)
            listo?(!error)
        }
    }

    /// "Commit de todo" (bajo responsabilidad del usuario): `git add -A` y `git commit -m`.
    func commitDeTodo(_ repo: RepoLocal, mensaje: String, gestor: Gestor, listo: ((Bool) -> Void)? = nil) {
        let m = mensaje.trimmingCharacters(in: .whitespacesAndNewlines)
        guard herramientas.git != nil, trabajando[repo.id] == nil else { return }
        guard !m.isEmpty else { novedad = Novedad(texto: T("Escribí un mensaje para el commit."), esError: true); return }
        marcar(repo.id, T("Guardando…"))
        cola.async {
            let a = self.git(["add", "-A"], en: repo.ruta, tope: 120)
            guard a.bien else {
                self.terminar(repo, T("No se pudo preparar el commit en %@.", repo.nombre) + "\n" + Self.explicar(a), error: true, gestor: gestor, listo: listo)
                return
            }
            let c = self.git(["commit", "--quiet", "-m", m], en: repo.ruta, tope: 120)
            if c.bien {
                self.terminar(repo, T("Commit hecho en %@.", repo.nombre), error: false, gestor: gestor, listo: listo)
            } else {
                self.terminar(repo, T("No se pudo hacer el commit en %@.", repo.nombre) + "\n" + Self.explicar(c), error: true, gestor: gestor, listo: listo)
            }
        }
    }

    /// "Subir": `git push` (nunca forzado). Si la rama todavía no sigue a ninguna del remoto, la crea en `origin`.
    func subir(_ repo: RepoLocal, gestor: Gestor, listo: ((Bool) -> Void)? = nil) {
        guard herramientas.git != nil, trabajando[repo.id] == nil, repo.remoto != nil else { return }
        marcar(repo.id, T("Subiendo…"))
        cola.async {
            let args = repo.tieneSeguimiento ? ["push", "--quiet"] : ["push", "--quiet", "--set-upstream", "origin", "HEAD"]
            let r = self.git(self.credencialGH(repo.remoto) + args, en: repo.ruta, tope: 300)
            if r.bien {
                self.terminar(repo, T("%@: subido.", repo.nombre), error: false, gestor: gestor, listo: listo)
            } else {
                self.terminar(repo, T("No se pudo subir %@.", repo.nombre) + "\n" + Self.explicar(r), error: true, gestor: gestor, listo: listo)
            }
        }
    }

    /// Unir `origen` en `destino` (`git merge --no-edit`). Si hay cambios sin commit no hace nada; si hay conflicto,
    /// `git merge --abort` y vuelve a la rama donde estaba. Nunca reset, nunca push, nunca borra ramas.
    func unir(_ repo: RepoLocal, origen: String, destino: String, quedarseEnOriginal: Bool, gestor: Gestor,
              listo: ((Bool) -> Void)? = nil) {
        guard herramientas.git != nil, trabajando[repo.id] == nil else { return }
        guard Self.ramaValida(origen), Self.ramaValida(destino), origen != destino else {
            novedad = Novedad(texto: T("Elegí dos ramas distintas."), esError: true); return
        }
        marcar(repo.id, T("Uniendo…"))
        cola.async {
            let fallar = { (texto: String) in self.terminar(repo, texto, error: true, gestor: gestor, listo: listo) }
            let s = self.git(["status", "--porcelain"], en: repo.ruta, tope: 20)
            guard s.bien else { fallar(Self.explicar(s)); return }
            guard s.salida.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                fallar(T("%@ tiene cambios sin commit. Hacé commit antes de unir ramas; no se cambió nada.", repo.nombre)); return
            }
            // Dónde está el usuario: una rama, o un commit suelto.
            let rama = self.git(["symbolic-ref", "--short", "-q", "HEAD"], en: repo.ruta, tope: 10)
            var original = rama.salida.trimmingCharacters(in: .whitespacesAndNewlines)
            if !rama.bien || original.isEmpty {
                original = self.git(["rev-parse", "HEAD"], en: repo.ruta, tope: 10).salida.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !original.isEmpty else { fallar(T("No pude saber en qué rama estás.")); return }
            let volver = { if original != destino { _ = self.git(["checkout", "--quiet", original], en: repo.ruta, tope: 60) } }

            if original != destino {
                let c = self.git(["checkout", "--quiet", destino], en: repo.ruta, tope: 60)
                guard c.bien else { fallar(T("No pude pasar a la rama %@.", destino) + "\n" + Self.explicar(c)); return }
            }
            var entorno = ["GIT_MERGE_AUTOEDIT": "no"]
            entorno["GIT_EDITOR"] = "true"
            let m = self.gitCon(entorno, ["merge", "--no-edit", "--quiet", "refs/heads/\(origen)"], en: repo.ruta, tope: 120)
            if !m.bien {
                let enCurso = self.git(["rev-parse", "-q", "--verify", "MERGE_HEAD"], en: repo.ruta, tope: 10).bien
                if enCurso { _ = self.git(["merge", "--abort"], en: repo.ruta, tope: 60) }
                volver()
                let conflicto = enCurso || (m.salida + m.error).lowercased().contains("conflict")
                fallar(conflicto
                       ? T("Hay conflictos entre las ramas: resolvelos con tu editor o con Claude; no se cambió nada.")
                       : T("No se pudo unir %@ en %@; no se cambió nada.", origen, destino) + "\n" + Self.explicar(m))
                return
            }
            if quedarseEnOriginal { volver() }
            let donde = quedarseEnOriginal ? original : destino
            self.terminar(repo, T("%@ quedó unida en %@. Estás en %@.", origen, destino, donde), error: false, gestor: gestor, listo: listo)
        }
    }

    private func gitCon(_ extra: [String: String], _ args: [String], en carpeta: String, tope: TimeInterval) -> ProcesoRepos.Resultado {
        guard let g = herramientas.git else { return ProcesoRepos.Resultado(noArranco: true) }
        var e = entorno()
        for (k, v) in extra { e[k] = v }
        return ProcesoRepos.correr(g, args, en: carpeta, tope: tope, entorno: e)
    }
}
