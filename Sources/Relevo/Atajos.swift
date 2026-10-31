import Carbon.HIToolbox
import Foundation

/// Atajos de teclado globales (funcionan desde cualquier app, sin permisos especiales):
/// ⌃⌥⌘S sincronizar todo · ⌃⌥⌘L me voy · ⌃⌥⌘E expulsar discos.
final class Atajos {
    enum Accion: UInt32 { case sincronizar = 1, meVoy = 2, expulsar = 3 }
    static let shared = Atajos()
    static let descripcion: [(Accion, String)] = [(.sincronizar, "⌃⌥⌘S"), (.meVoy, "⌃⌥⌘L"), (.expulsar, "⌃⌥⌘E")]

    var alApretar: ((Accion) -> Void)?
    private var refs: [EventHotKeyRef] = []
    private var manejador: EventHandlerRef?

    func activar(_ encendido: Bool) {
        desactivar()
        guard encendido else { return }
        var tipo = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, evento, contexto in
            var id = EventHotKeyID()
            GetEventParameter(evento, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard let contexto, let accion = Accion(rawValue: id.id) else { return noErr }
            let yo = Unmanaged<Atajos>.fromOpaque(contexto).takeUnretainedValue()
            DispatchQueue.main.async { yo.alApretar?(accion) }
            return noErr
        }, 1, &tipo, Unmanaged.passUnretained(self).toOpaque(), &manejador)
        let modificadores = UInt32(controlKey | optionKey | cmdKey)
        for (accion, tecla) in [(Accion.sincronizar, kVK_ANSI_S), (.meVoy, kVK_ANSI_L), (.expulsar, kVK_ANSI_E)] {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x524C_5656), id: accion.rawValue)   // "RLVV"
            if RegisterEventHotKey(UInt32(tecla), modificadores, id, GetApplicationEventTarget(), 0, &ref) == noErr, let ref {
                refs.append(ref)
            }
        }
    }

    func desactivar() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        if let manejador { RemoveEventHandler(manejador) }
        manejador = nil
    }
}
