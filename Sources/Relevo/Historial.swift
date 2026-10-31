import AppKit
import Combine
import Foundation
import RelevoNucleo

/// Una sincronización de una carpeta, para mostrar qué pasó (como un "commit": qué archivos, para dónde).
struct Movimiento: Codable, Identifiable, Equatable {
    var id = UUID()
    var fecha: Date
    var carpeta: String
    var haciaPortatil: Int
    var haciaHub: Int
    var bytes: Int64
    var aPapelera: Int
    var conflictos: [String]
    var recuperados: [String]
    var repos: [String]
    var problemas: [String]
    var desconectado: String?
    var duracion: Double
    var vinculo: String?
    /// Archivo por archivo (hasta 2000; `cambiosTotales` cuenta todos).
    var cambios: [Cambio]?
    var cambiosTotales: Int?
    /// Carpeta de la papelera de esta pasada: ahí están las versiones anteriores y lo borrado.
    var sello: String?
    /// Conflictos ya resueltos (rutas).
    var resueltos: [String]?

    var texto: String {
        var partes: [String] = []
        if haciaPortatil > 0 { partes.append(T("%ld al portátil", haciaPortatil)) }
        if haciaHub > 0 { partes.append(T("%ld al hub", haciaHub)) }
        if aPapelera > 0 { partes.append(T("%ld a la papelera", aPapelera)) }
        if !conflictos.isEmpty { partes.append(T("%ld con dos versiones", conflictos.count)) }
        if partes.isEmpty { partes.append(T("revisado")) }
        return partes.joined(separator: " · ")
    }

    var conflictosAbiertos: [String] { conflictos.filter { !(resueltos ?? []).contains($0) } }
}

final class Historial: ObservableObject {
    static let shared = Historial()
    private static let archivo = Ajustes.carpetaApp.appendingPathComponent("historial.json")
    private static let tope = 300

    @Published private(set) var lista: [Movimiento] = []

    private init() {
        if let d = try? Data(contentsOf: Self.archivo), let l = try? JSONDecoder().decode([Movimiento].self, from: d) {
            // Como mucho 300 pasadas y de los últimos 90 días: el historial no crece sin fin.
            let limite = Date().addingTimeInterval(-90 * 86400)
            lista = Array(l.filter { $0.fecha > limite }.prefix(Self.tope))
        }
    }

    func agregar(_ m: Movimiento) {
        lista.insert(m, at: 0)
        if lista.count > Self.tope { lista.removeLast(lista.count - Self.tope) }
        guardar()
    }

    func marcarResuelto(_ movimiento: Movimiento.ID, _ ruta: String) {
        guard let i = lista.firstIndex(where: { $0.id == movimiento }) else { return }
        lista[i].resueltos = (lista[i].resueltos ?? []) + [ruta]
        guardar()
    }

    func borrarTodo() {
        lista = []
        try? FileManager.default.removeItem(at: Self.archivo)
    }

    private func guardar() {
        let lista = self.lista
        DispatchQueue.global(qos: .utility).async {
            try? JSONEncoder().encode(lista).write(to: Self.archivo, options: .atomic)
        }
    }

    /// Conflictos sin resolver de todos los movimientos.
    var conflictosAbiertos: [(Movimiento, String)] {
        lista.flatMap { m in m.conflictosAbiertos.map { (m, $0) } }
    }
}

/// Volver atrás: recuperar de la papelera algo borrado o la versión anterior de un archivo.
/// Se restaura en el lado donde estaba; después la sincronización lo lleva al otro.
enum Restaurar {
    /// Dónde quedó guardada la versión anterior (o lo borrado) de un cambio.
    static func enPapelera(raiz: String, sello: String, carpeta: String, ruta: String) -> String {
        Sincronizador.papelera(raiz) + "/" + sello + "/" + carpeta + "/" + ruta
    }

    static func disponible(raiz: String?, sello: String?, carpeta: String, ruta: String) -> Bool {
        guard let raiz, let sello else { return false }
        let guardado = enPapelera(raiz: raiz, sello: sello, carpeta: carpeta, ruta: ruta)
        var st = stat()
        return lstat(guardado, &st) == 0 && seguro(guardado, raiz)
    }

    /// Las carpetas del camino (desde la raíz del disco) tienen que ser de verdad: si en el portátil cambiaron una por
    /// un enlace, recuperar traería o llevaría archivos de otro lugar de la Mac (auditoría del 23/10).
    private static func seguro(_ ruta: String, _ raiz: String) -> Bool {
        Rutas.sinEnlaces((ruta as NSString).deletingLastPathComponent, desde: raiz)
    }

    /// Mover sin salir del disco: rename falla si el destino está en otro disco (moveItem copiaría y borraría).
    private static func mover(_ desde: String, _ hasta: String, _ raiz: String) -> Bool {
        guard seguro(desde, raiz), seguro(hasta, raiz) else { return false }
        try? FileManager.default.createDirectory(atPath: (hasta as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        return seguro(hasta, raiz) && rename(desde, hasta) == 0
    }

    /// Lo actual (si hay) va a la papelera y vuelve la versión guardada.
    static func traer(raiz: String, sello: String, carpeta: String, ruta: String) -> Bool {
        let guardado = enPapelera(raiz: raiz, sello: sello, carpeta: carpeta, ruta: ruta)
        let destino = raiz + "/" + carpeta + "/" + ruta
        var st = stat()
        guard lstat(guardado, &st) == 0, seguro(guardado, raiz), seguro(destino, raiz) else { return false }
        if lstat(destino, &st) == 0 {
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd HH.mm.ss"
            let aparte = Sincronizador.papelera(raiz) + "/" + f.string(from: Date()) + "/" + carpeta + "/" + ruta
            guard mover(destino, aparte, raiz) else { return false }
        }
        return mover(guardado, destino, raiz)
    }

    /// Conflicto: quedarse con una de las dos versiones. La otra va a la papelera (en el hub; la sincronización
    /// replica el cambio en el portátil).
    static func resolverConflicto(raizHub: String, carpeta: String, ruta: String, otraVersion: String, quedarseConLaOtra: Bool) -> Bool {
        let fm = FileManager.default
        let original = raizHub + "/" + carpeta + "/" + ruta
        let otra = raizHub + "/" + carpeta + "/" + otraVersion
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let papelera = Sincronizador.papelera(raizHub) + "/" + f.string(from: Date()) + "/" + carpeta + "/"
        func aPapelera(_ ruta: String, _ relativa: String) -> Bool { mover(ruta, papelera + relativa, raizHub) }
        if quedarseConLaOtra {
            guard fm.fileExists(atPath: otra), aPapelera(original, ruta) else { return false }
            return mover(otra, original, raizHub)
        }
        return fm.fileExists(atPath: otra) ? aPapelera(otra, otraVersion) : true
    }
}
