import Foundation

/// Qué no viaja: carpetas que se regeneran solas (dependencias, compilados) y basura del sistema.
public struct Reglas: Codable, Sendable, Equatable {
    /// Nombres exactos de carpeta o archivo que se saltean, estén donde estén.
    public var nombres: [String]
    /// Terminaciones de nombre que se saltean (por ejemplo ".log").
    public var terminaciones: [String]
    /// Rutas puntuales (relativas a la carpeta que se sincroniza) que se saltean: lo que ignora el `.gitignore`.
    public var ignoradas: Set<String> = []

    public init(nombres: [String], terminaciones: [String] = []) {
        self.nombres = nombres
        self.terminaciones = terminaciones
        armarIndice()
    }

    /// Lo que se puede volver a generar con un comando (`pnpm install`, `swift build`, etc.).
    public static let regenerables = [
        "node_modules", ".pnpm-store", ".venv", "venv", "__pycache__", ".next", ".nuxt", ".turbo", ".expo",
        ".build", "DerivedData", "Pods", ".gradle", ".parcel-cache", ".svelte-kit",
    ]

    /// Dependencias: ocupan mucho, pero llevarlas evita volver a bajarlas afuera (con las mismas rutas, funcionan tal cual).
    public static let dependencias: Set<String> = ["node_modules", ".pnpm-store", ".venv", "venv", "Pods"]

    /// Lo que crea macOS y no hay que llevar nunca.
    static let sistema: Set<String> = [
        ".DS_Store", ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems", ".DocumentRevisions-V100",
        ".Relevo", "Icon\r",
    ]

    public static let porDefecto = Reglas(nombres: regenerables)

    /// Sufijo de las copias a medio hacer: si el disco se saca en el medio, quedan con este nombre y se limpian.
    static let sufijoTemporal = ".relevo-tmp"

    private var indice: Set<String> = []
    private enum CodingKeys: String, CodingKey { case nombres, terminaciones }

    /// Las mismas reglas, más lo que el `.gitignore` de esta carpeta deja afuera. Los `.env` viajan siempre (son las
    /// claves que hacen falta afuera, aunque git los ignore).
    public func con(ignoradas rutas: Set<String>) -> Reglas {
        var r = self
        r.ignoradas = rutas.filter { !$0.nombreFinal.hasPrefix(".env") }
        return r
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        nombres = try c.decode([String].self, forKey: .nombres)
        terminaciones = try c.decodeIfPresent([String].self, forKey: .terminaciones) ?? []
        armarIndice()
    }

    private mutating func armarIndice() { indice = Set(nombres).union(Reglas.sistema) }

    public static func == (a: Reglas, b: Reglas) -> Bool {
        a.nombres == b.nombres && a.terminaciones == b.terminaciones && a.ignoradas == b.ignoradas
    }

    /// Carpeta donde Claude Code arma sus copias de trabajo de un proyecto (una por sesión, cada una con su propio
    /// `pnpm install`). El código de esas copias viaja; sus dependencias no (ver `dependenciaDeCopiaDeTrabajo`).
    static let copiasDeTrabajo = ".claude/worktrees/"

    /// ¿Es una carpeta de dependencias adentro de una copia de trabajo de Claude Code? No viajan nunca, aunque esté
    /// elegido llevar las dependencias: cada copia trae las suyas (cientos de miles de archivos que se rehacen con
    /// `pnpm install`) y eran casi todo lo que Relevo revisaba (en un proyecto, 610 mil de 710 mil archivos, 30/10/2026).
    /// Lo usan `excluye` y la copia en vivo (`Coordinador.zonasDe`), con la ruta relativa a la carpeta del par.
    public static func dependenciaDeCopiaDeTrabajo(_ ruta: String) -> Bool {
        guard ruta.hasPrefix(copiasDeTrabajo) || ruta.contains("/" + copiasDeTrabajo) else { return false }
        return ruta.split(separator: "/").contains { dependencias.contains(String($0)) }
    }

    /// `ruta` es relativa a la carpeta que se sincroniza; `nombre` es su último pedazo.
    func excluye(nombre: String, ruta: String) -> Bool {
        if indice.contains(nombre) || nombre.hasPrefix("._") || nombre.hasSuffix(Reglas.sufijoTemporal) { return true }
        if Reglas.dependencias.contains(nombre), Reglas.dependenciaDeCopiaDeTrabajo(ruta) { return true }
        for t in terminaciones where nombre.hasSuffix(t) { return true }
        if !ignoradas.isEmpty, ignoradas.contains(ruta) { return true }
        // Los candados de git (index.lock, HEAD.lock…) duran un instante: llevarlos dejaría el repo trabado del otro lado.
        if nombre.hasSuffix(".lock"), ruta.hasPrefix(".git/") || ruta.contains("/.git/") { return true }
        return false
    }
}
