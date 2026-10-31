import Darwin
import Foundation

/// Lo que se escribió en cada disco en la última sincronización. Vive en la Mac (no en los discos que se sacan).
///
/// - `pendientes`: copias que el disco todavía no confirmó haber guardado. Si se corta, se comparan por contenido.
/// - `recientes`: copias confirmadas. Si el disco se saca de golpe, puede "perder" lo último que recibió; sin esta
///   lista eso parecería un borrado tuyo y se borraría del otro lado. Con la lista, se vuelve a copiar.
///   Se olvida cuando el disco se expulsa bien (ahí macOS garantiza que escribió todo).
final class Diario: @unchecked Sendable {
    struct Anotacion { var id: Int; var paso: Paso }

    let pendientes: URL
    let recientes: URL
    private let candado = NSLock()
    private var abiertas: [Int: (paso: Paso, listo: Bool)] = [:]
    private var proximo = 0
    private var manija: FileHandle?

    init(pendientes: URL, recientes: URL) {
        self.pendientes = pendientes
        self.recientes = recientes
    }

    /// Lo mismo que `leer`, de a un paso por vez (para archivos enormes: no arma la lista entera).
    static func recorrer(_ archivo: URL, _ cada: (Paso) -> Void) {
        guard let datos = try? Data(contentsOf: archivo, options: .mappedIfSafe) else { return }
        datos.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var inicio = 0
            for i in 0...p.count where i == p.count || p[i] == UInt8(ascii: "\n") {
                defer { inicio = i + 1 }
                guard i > inicio, let tab = p[inicio..<i].firstIndex(of: UInt8(ascii: "\t")),
                      let lado = Lado(rawValue: String(decoding: UnsafeRawBufferPointer(rebasing: p[inicio..<tab]), as: UTF8.self))
                else { continue }
                cada(Paso(ruta: String(decoding: UnsafeRawBufferPointer(rebasing: p[(tab + 1)..<i]), as: UTF8.self), lado: lado))
            }
        }
    }

    static func leer(_ archivo: URL) -> [Paso] {
        guard let texto = try? String(contentsOf: archivo, encoding: .utf8) else { return [] }
        return texto.split(separator: "\n").compactMap { linea in
            let partes = linea.split(separator: "\t", maxSplits: 1)
            guard partes.count == 2, let lado = Lado(rawValue: String(partes[0])) else { return nil }
            return Paso(ruta: String(partes[1]), lado: lado)
        }
    }

    /// Antes de una sincronización nueva: lo de la anterior ya se revisó en el análisis.
    func empezar() {
        candado.withLock {
            try? FileManager.default.removeItem(at: pendientes)
            try? FileManager.default.removeItem(at: recientes)
        }
    }

    func anotar(_ lado: Lado, _ ruta: String) -> Int {
        candado.withLock {
            proximo += 1
            abiertas[proximo] = (Paso(ruta: ruta, lado: lado), false)
            if manija == nil { manija = Diario.abrirParaAgregar(pendientes) }
            try? manija?.write(contentsOf: Data(Diario.linea(lado, ruta).utf8))
            return proximo
        }
    }

    func listo(_ id: Int) { candado.withLock { abiertas[id]?.listo = true } }
    func descartar(_ id: Int) { candado.withLock { _ = abiertas.removeValue(forKey: id) } }

    func listos() -> [Anotacion] {
        candado.withLock { abiertas.filter { $0.value.listo }.map { Anotacion(id: $0.key, paso: $0.value.paso) } }
    }

    /// El disco confirmó: pasan de "pendientes" a "recientes".
    func confirmar(_ ids: [Int]) {
        candado.withLock {
            var texto = ""
            for id in ids {
                if let a = abiertas.removeValue(forKey: id) { texto += Diario.linea(a.paso.lado, a.paso.ruta) }
            }
            if let m = Diario.abrirParaAgregar(recientes) {
                try? m.write(contentsOf: Data(texto.utf8))
                try? m.close()
            }
            try? manija?.close()
            manija = nil
            if abiertas.isEmpty {
                try? FileManager.default.removeItem(at: pendientes)
            } else {
                let resto = abiertas.values.map { Diario.linea($0.paso.lado, $0.paso.ruta) }.joined()
                try? resto.write(to: pendientes, atomically: true, encoding: .utf8)
            }
        }
    }

    private static func linea(_ lado: Lado, _ ruta: String) -> String { "\(lado.rawValue)\t\(ruta)\n" }

    private static func abrirParaAgregar(_ archivo: URL) -> FileHandle? {
        try? FileManager.default.createDirectory(at: archivo.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: archivo.path) {
            FileManager.default.createFile(atPath: archivo.path, contents: nil)
        }
        let m = try? FileHandle(forWritingTo: archivo)
        _ = try? m?.seekToEnd()
        return m
    }
}
