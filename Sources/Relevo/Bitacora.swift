import Foundation

/// Lo que hace Relevo al juntar o separar los discos, con la hora exacta, en ~/Library/Logs/Relevo.log (solo en esta
/// Mac). Sirve para saber en qué se va el tiempo cuando una vuelta tarda (31/10/2026: la vuelta tardaba casi dos
/// minutos y no había cómo saber dónde). Lo llaman el coordinador (llegada, nombres, revisión, cada proyecto) y
/// `Montajes`. Pasado 1 MB, lo viejo pasa a Relevo.log.1. En las pruebas no escribe.
enum Bitacora {
    static let archivo = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Relevo.log")
    private static let cola = DispatchQueue(label: "team.halyon.relevo.bitacora", qos: .utility)
    private static let formato: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func anotar(_ texto: String) {
        guard !Notificar.prueba else { return }
        let linea = formato.string(from: Date()) + "  " + texto + "\n"
        cola.async {
            let fm = FileManager.default
            if let tam = (try? fm.attributesOfItem(atPath: archivo.path))?[.size] as? Int, tam > 1_000_000 {
                let viejo = archivo.appendingPathExtension("1")
                try? fm.removeItem(at: viejo)
                try? fm.moveItem(at: archivo, to: viejo)
            }
            guard let datos = linea.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: archivo) {
                h.seekToEndOfFile()
                h.write(datos)
                try? h.close()
            } else {
                try? fm.createDirectory(at: archivo.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? datos.write(to: archivo)
            }
        }
    }
}
