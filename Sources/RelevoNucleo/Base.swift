import Darwin
import Foundation

/// La "base": cómo quedaron las cosas al terminar la última sincronización. Se guarda en un archivo binario
/// compacto (300 mil rutas ≈ 30 MB) que se escribe completo en un temporal y recién después reemplaza al anterior,
/// así un corte nunca deja una base a medias.
public struct Base: Sendable {
    public var registros: [String: Registro] = [:]

    public init() {}

    private static let inicio = Array("SGB1".utf8)
    private static let fin = Array("FIN!".utf8)

    /// `nil` si no existe o está dañada (en ese caso se sincroniza como la primera vez, sin pisar nada).
    /// `reusar`: si la ruta ya está ahí (la foto del hub), se usa ese mismo texto en vez de guardar otra copia.
    public static func cargar(_ url: URL, reusar: [String: Entrada] = [:]) -> Base? {
        cargar(url, recorte: nil, reusar: reusar)?.base
    }

    /// Solo los registros que caen en `recorte` (nil = todos). Devuelve además cuántos archivos tiene la base entera
    /// (para el freno de "muchos borrados" de una revisión por zonas, que no mira la carpeta entera).
    static func cargar(_ url: URL, recorte: Recorte?, reusar: [String: Entrada] = [:]) -> (base: Base, archivos: Int)? {
        var base = Base(), archivos = 0
        let bien = recorrer(url, cantidad: { if recorte == nil { base.registros.reserveCapacity($0) } }) { ruta, registro, _ in
            if registro.tipo == .archivo { archivos += 1 }
            guard recorte?.contiene(ruta) ?? true else { return }
            let clave = reusar.index(forKey: ruta).map { reusar[$0].key } ?? ruta
            base.registros[clave] = registro
        }
        return bien ? (base, archivos) : nil
    }

    /// Lee la base de a un registro, sin armarla en memoria: `cada` recibe la ruta, el registro y sus bytes tal como
    /// están en el archivo (para copiarlos sin rearmarlos). false si no existe o está dañada.
    private static func recorrer(_ url: URL, cantidad: (Int) -> Void = { _ in },
                                 _ cada: (String, Registro, UnsafeRawBufferPointer) -> Void) -> Bool {
        guard let datos = try? Data(contentsOf: url, options: .mappedIfSafe), datos.count >= 12 else { return false }
        return datos.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            var lector = Lector(p: p)
            guard lector.bytes(4) == inicio, let total = lector.u32() else { return false }
            // La cantidad la dice el archivo (puede venir del portátil): nunca más registros de los que entran.
            cantidad(min(Int(total), (p.count - 12) / 32))
            for _ in 0..<total {
                let desde = lector.i
                guard let ruta = lector.texto(), let tipoCrudo = lector.u8(), let tipo = Entrada.Tipo(rawValue: tipoCrudo),
                      let tamano = lector.i64(), let modo = lector.u16(), let mh = lector.i64(), let mp = lector.i64(),
                      let tieneDestino = lector.u8() else { return false }
                var destino: String?
                if tieneDestino == 1 { guard let d = lector.texto() else { return false }; destino = d }
                cada(ruta, Registro(tipo: tipo, tamano: tamano, modo: modo, destino: destino, mtimeHub: mh, mtimePortatil: mp),
                     UnsafeRawBufferPointer(rebasing: p[desde..<lector.i]))
            }
            return lector.bytes(4) == fin
        }
    }

    public func guardar(_ url: URL) throws {
        try Base.escribir(url) { escritor in
            for (ruta, r) in registros { escritor.agregar(ruta, r) }
        }
    }

    /// Guarda una revisión por zonas: de la base `vieja` se copia tal cual todo lo que queda afuera de `recorte` (no
    /// se revisó, sigue igual) y lo de adentro se reemplaza por estos registros. Si la vieja no se puede leer, no
    /// escribe nada (tira error): una base a medias haría parecer borrado lo que no se revisó.
    func guardar(_ url: URL, encimaDe vieja: URL, recorte: Recorte) throws {
        try Base.escribir(url) { escritor in
            let bien = Base.recorrer(vieja) { ruta, _, crudo in
                if !recorte.contiene(ruta) { escritor.copiar(crudo) }
            }
            guard bien else { throw POSIXError(.EIO) }
            for (ruta, r) in registros { escritor.agregar(ruta, r) }
        }
    }

    /// Copia el archivo de una base a otro lugar (la copia de respaldo en el portátil), con el mismo cuidado: temporal,
    /// confirmado en el disco y recién ahí reemplaza al anterior. Lo usa `Sincronizador.guardar`.
    static func copiar(_ desde: URL, a destino: URL) throws {
        try FileManager.default.createDirectory(at: destino.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporal = destino.path + Reglas.sufijoTemporal
        unlink(temporal)
        guard copyfile(desde.path, temporal, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            let e = errno
            unlink(temporal)
            throw POSIXError(POSIXErrorCode(rawValue: e) ?? .EIO)
        }
        let fd = open(temporal, O_RDONLY)
        if fd >= 0 { _ = fcntl(fd, F_FULLFSYNC); close(fd) }
        guard rename(temporal, destino.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Escribe una base completa en un temporal, la confirma en el disco y recién ahí reemplaza a la anterior.
    private static func escribir(_ url: URL, _ llenar: (Escritor) throws -> Void) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporal = url.path + Reglas.sufijoTemporal
        unlink(temporal)
        let fd = open(temporal, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let escritor = Escritor(fd: fd)
        do {
            escritor.poner(inicio)
            escritor.poner(UInt32(0))   // la cantidad se completa al final
            try llenar(escritor)
            escritor.poner(fin)
            try escritor.terminar()
        } catch {
            close(fd); unlink(temporal)
            throw error
        }
        _ = fcntl(fd, F_FULLFSYNC)
        close(fd)
        guard rename(temporal, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    /// Junta lo que se escribe en tandas de 4 MB (una base grande no se arma entera en memoria).
    private final class Escritor {
        let fd: Int32
        var buffer: [UInt8] = []
        var cantidad: UInt32 = 0
        var error: Int32 = 0

        init(fd: Int32) { self.fd = fd; buffer.reserveCapacity(4 << 20) }

        func agregar(_ ruta: String, _ r: Registro) {
            cantidad += 1
            texto(ruta)
            buffer.append(r.tipo.rawValue)
            poner(r.tamano); poner(r.modo); poner(r.mtimeHub); poner(r.mtimePortatil)
            if let destino = r.destino { buffer.append(1); texto(destino) } else { buffer.append(0) }
            vaciarSiHaceFalta()
        }

        /// Un registro tal como estaba en la base vieja.
        func copiar(_ crudo: UnsafeRawBufferPointer) {
            cantidad += 1
            buffer.append(contentsOf: crudo)
            vaciarSiHaceFalta()
        }

        func poner(_ bytes: [UInt8]) { buffer.append(contentsOf: bytes) }
        func poner<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { buffer.append(contentsOf: $0) } }
        private func texto(_ s: String) {
            var s = s
            s.withUTF8 { u in poner(UInt32(u.count)); buffer.append(contentsOf: u) }
        }

        private func vaciarSiHaceFalta() { if buffer.count >= 4 << 20 { vaciar() } }

        private func vaciar() {
            guard error == 0, !buffer.isEmpty else { buffer.removeAll(keepingCapacity: true); return }
            let escrito = buffer.withUnsafeBytes { p -> Bool in
                var hecho = 0
                while hecho < p.count {
                    let n = write(fd, p.baseAddress! + hecho, p.count - hecho)
                    if n < 0 { if errno == EINTR { continue }; return false }
                    hecho += n
                }
                return true
            }
            if !escrito { error = errno }
            buffer.removeAll(keepingCapacity: true)
        }

        /// Escribe lo que quedó y completa la cantidad de registros al principio del archivo.
        func terminar() throws {
            vaciar()
            var c = cantidad.littleEndian
            if error == 0, pwrite(fd, &c, 4, 4) != 4 { error = errno }
            if error != 0 { throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO) }
        }
    }
}

/// Las rutas que cubre una revisión por zonas (ver `Zonas`): lo de adentro directo de cada carpeta plana y todo lo de
/// cada carpeta entera (con ella misma). Lo usan `Sincronizador` (qué parte de la base cargar) y
/// `Base.guardar(_:encimaDe:recorte:)` (qué parte de la base vieja reemplazar): tienen que ser exactamente las mismas.
struct Recorte: Sendable {
    var planas: Set<String>
    var enteras: Set<String>
    /// Largos (en bytes) de las carpetas enteras: para no armar textos de prefijos que no pueden coincidir.
    private var largos: [Int]

    init(planas: Set<String>, enteras: Set<String>) {
        self.planas = planas; self.enteras = enteras
        largos = Set(enteras.map(\.utf8.count)).sorted()
    }

    func contiene(_ ruta: String) -> Bool {
        if !planas.isEmpty, planas.contains(ruta.padre) { return true }
        guard !largos.isEmpty else { return false }
        let u = ruta.utf8
        for largo in largos {
            guard largo <= u.count else { break }
            let corte = u.index(u.startIndex, offsetBy: largo)
            guard largo == u.count || u[corte] == UInt8(ascii: "/") else { continue }
            if enteras.contains(String(ruta[..<corte])) { return true }
        }
        return false
    }
}

private struct Lector {
    let p: UnsafeRawBufferPointer
    var i = 0   // por dónde va (lo usa `Base.recorrer` para copiar cada registro tal cual)

    mutating func bytes(_ n: Int) -> [UInt8]? {
        guard i + n <= p.count else { return nil }
        defer { i += n }
        return Array(p[i..<i + n])
    }

    mutating func entero<T: FixedWidthInteger>(_: T.Type) -> T? {
        let n = MemoryLayout<T>.size
        guard i + n <= p.count else { return nil }
        var v: T = 0
        withUnsafeMutableBytes(of: &v) { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: p[i..<i + n])) }
        i += n
        return T(littleEndian: v)
    }

    mutating func u8() -> UInt8? { entero(UInt8.self) }
    mutating func u16() -> UInt16? { entero(UInt16.self) }
    mutating func u32() -> UInt32? { entero(UInt32.self) }
    mutating func i64() -> Int64? { entero(Int64.self) }

    mutating func texto() -> String? {
        guard let n = u32().map(Int.init), i + n <= p.count else { return nil }
        defer { i += n }
        return String(decoding: UnsafeRawBufferPointer(rebasing: p[i..<i + n]), as: UTF8.self)
    }
}
