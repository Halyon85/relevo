import CoreServices
import Foundation

/// Avisa qué carpetas cambiaron, usando el registro de cambios del propio macOS (FSEvents): no recorre nada ni
/// gasta mientras no pase nada. Agrupa los avisos de los últimos segundos.
final class Vigia {
    private var flujo: FSEventStreamRef?
    /// Está mirando los cambios (copia en vivo prendida y los dos discos conectados).
    var activo: Bool { flujo != nil }
    /// Recibe las carpetas donde pasó algo y, de cada una, si hay que mirarla entera (macOS perdió el detalle de lo de
    /// adentro, o se perdieron avisos): ver `Coordinador.cambiaron`.
    private let alCambiar: ([(ruta: String, entera: Bool)]) -> Void
    /// El último evento que se vio: al volver a mirar (se reinicia con cada cambio de discos), se arranca desde ahí y
    /// no se pierde lo que pasó en el medio. macOS los entrega en orden: todo lo anterior ya llegó (por eso también
    /// sirve de marca para la copia en vivo, ver `Coordinador.copiarSucias`).
    private(set) var ultimoEvento: FSEventStreamEventId?

    init(alCambiar: @escaping ([(ruta: String, entera: Bool)]) -> Void) { self.alCambiar = alCambiar }

    deinit { detener() }

    func vigilar(_ rutas: [String]) {
        detener()
        guard !rutas.isEmpty else { return }
        var contexto = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let llamada: FSEventStreamCallback = { _, info, cantidad, rutasCrudas, banderas, ids in
            guard let info else { return }
            let vigia = Unmanaged<Vigia>.fromOpaque(info).takeUnretainedValue()
            let lista = Unmanaged<CFArray>.fromOpaque(rutasCrudas).takeUnretainedValue() as? [String] ?? []
            if cantidad > 0 { vigia.ultimoEvento = max(vigia.ultimoEvento ?? 0, ids[cantidad - 1]) }
            let entera = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
            vigia.alCambiar((0..<min(cantidad, lista.count)).map { (lista[$0], banderas[$0] & entera != 0) })
        }
        let opciones = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagIgnoreSelf)
        guard let f = FSEventStreamCreate(nil, llamada, &contexto, rutas as CFArray,
                                          ultimoEvento ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, opciones) else { return }
        FSEventStreamSetDispatchQueue(f, DispatchQueue.main)
        FSEventStreamStart(f)
        flujo = f
        if ultimoEvento == nil { ultimoEvento = FSEventsGetCurrentEventId() }
    }

    /// Entrega ya lo que estaba esperando su par de segundos (antes de "Me voy" o de expulsar).
    func vaciar() { if let f = flujo { FSEventStreamFlushAsync(f) } }

    func detener() {
        guard let f = flujo else { return }
        FSEventStreamStop(f)
        FSEventStreamInvalidate(f)
        FSEventStreamRelease(f)
        flujo = nil
    }
}
