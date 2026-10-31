import Foundation

/// Los dos lados de una sincronización: el disco que queda en casa y el que te llevás.
public enum Lado: String, Codable, Sendable, CaseIterable {
    case hub, portatil

    public var otro: Lado { self == .hub ? .portatil : .hub }
    public var nombre: String { self == .hub ? "hub" : "portátil" }
}

/// Un archivo, carpeta o enlace tal como está ahora en un disco.
public struct Entrada: Equatable, Sendable {
    public enum Tipo: UInt8, Sendable { case archivo = 0, carpeta = 1, enlace = 2 }

    // El orden de los campos importa: de los grandes a los chicos ocupa 40 bytes en vez de 48, y una revisión entera
    // guarda cientos de miles de estas.
    public var tamano: Int64
    /// Archivos: fecha de modificación (nanosegundos desde 1970). Carpetas: su número fijo en el disco (inodo), que
    /// no cambia aunque se modifique lo de adentro pero sí si en ese lugar quedó otra carpeta (movida o renombrada).
    /// Lo usa la revisión por zonas (`Sincronizador.analizar(_:zonas:)`) para saber si una carpeta sigue siendo la misma.
    public var mtime: Int64
    public var destino: String?    // solo enlaces
    public var modo: UInt16        // permisos (0o777)
    public var tipo: Tipo

    public init(tipo: Tipo, tamano: Int64 = 0, mtime: Int64 = 0, modo: UInt16 = 0o644, destino: String? = nil) {
        self.tipo = tipo; self.tamano = tamano; self.mtime = mtime; self.modo = modo; self.destino = destino
    }
}

/// Cómo quedó una ruta en los dos lados al terminar la última sincronización ("la base").
/// Comparar contra esto es lo que permite saber de qué lado hubo un cambio.
/// En las carpetas, `mtimeHub`/`mtimePortatil` guardan el número fijo de la carpeta en cada disco (ver `Entrada.mtime`);
/// 0 = todavía no se sabe (bases de antes de la revisión por zonas).
public struct Registro: Equatable, Sendable {
    // De los campos grandes a los chicos: 48 bytes en vez de 56 (la base de una carpeta grande tiene cientos de miles).
    public var tamano: Int64
    public var mtimeHub: Int64
    public var mtimePortatil: Int64
    public var destino: String?
    public var modo: UInt16
    public var tipo: Entrada.Tipo

    public func mtime(_ lado: Lado) -> Int64 { lado == .hub ? mtimeHub : mtimePortatil }

    init(hub: Entrada, portatil: Entrada) {
        tipo = hub.tipo; tamano = hub.tamano; modo = hub.modo; destino = hub.destino
        mtimeHub = hub.mtime; mtimePortatil = portatil.mtime
    }

    init(tipo: Entrada.Tipo, tamano: Int64, modo: UInt16, destino: String?, mtimeHub: Int64, mtimePortatil: Int64) {
        self.tipo = tipo; self.tamano = tamano; self.modo = modo; self.destino = destino
        self.mtimeHub = mtimeHub; self.mtimePortatil = mtimePortatil
    }

    /// ¿Esta entrada sigue igual que cuando sincronizamos?
    func igual(_ e: Entrada, lado: Lado) -> Bool {
        guard e.tipo == tipo else { return false }
        switch tipo {
        case .carpeta: return true   // su número fijo no cuenta acá: una carpeta que existe en los dos lados está igual
        case .enlace: return e.destino == destino
        case .archivo: return e.tamano == tamano && e.mtime == mtime(lado) && e.modo == modo
        }
    }
}

/// Qué partes de una carpeta del par revisar, según lo que avisó el registro de cambios de macOS (FSEvents dice
/// "algo cambió adentro de esta carpeta", sin decir qué). Rutas relativas a la carpeta del par; "" es su raíz.
/// Lo arma `Coordinador` (revisión inteligente y copia en vivo) y lo usa `Sincronizador.analizar(_:zonas:)`.
public struct Zonas: Sendable, Equatable {
    /// Carpetas de las que se mira solo lo que tienen adentro directo (sus archivos y sus subcarpetas, sin entrar).
    public var planas: Set<String>
    /// Carpetas que se miran enteras, con todo lo de adentro (macOS perdió el detalle, o la carpeta es nueva o se movió).
    public var enteras: Set<String>

    public init(planas: Set<String> = [], enteras: Set<String> = []) {
        self.planas = planas; self.enteras = enteras
    }

    public var vacia: Bool { planas.isEmpty && enteras.isEmpty }

    /// Toda la carpeta (por ejemplo, un proyecto nuevo o algo que espera tu OK): con esto se mira entera.
    public static let todo = Zonas(enteras: [""])

    /// Junta dos avisos (por ejemplo, cambios que llegaron mientras otra copia corría).
    public mutating func unir(_ otra: Zonas) {
        planas.formUnion(otra.planas)
        enteras.formUnion(otra.enteras)
    }
}

/// Algo que no salió y conviene contar.
public struct Problema: Sendable, Equatable {
    public var ruta: String
    public var detalle: String
}

extension String {
    /// "a/b/c" → "a/b". Vacío para lo que está en la raíz.
    var padre: String {
        guard let i = lastIndex(of: "/") else { return "" }
        return String(self[..<i])
    }

    var nombreFinal: String {
        guard let i = lastIndex(of: "/") else { return self }
        return String(self[index(after: i)...])
    }

    var profundidad: Int { utf8.reduce(1) { $0 + ($1 == UInt8(ascii: "/") ? 1 : 0) } }

    /// ¿`self` está adentro de `carpeta` (o es la misma)?
    func estaDentro(de carpeta: String) -> Bool {
        carpeta.isEmpty || self == carpeta || hasPrefix(carpeta + "/")
    }
}
