import Foundation
import IOKit
import IOKit.pwr_mgt

/// Antes de que la Mac se duerma (por ejemplo, al cerrar la tapa), macOS avisa y espera un rato: se usa para copiar
/// lo que estaba pendiente. No expulsa nada (a veces querés dejar los discos enchufados).
final class AntesDeDormir {
    static let shared = AntesDeDormir()
    /// Recibe "listo": hay que llamarlo cuando terminó de copiar (si no, a los 20 segundos se deja dormir igual).
    var preparar: ((@escaping () -> Void) -> Void)?
    private var puertoRaiz: io_connect_t = 0
    private var notificador: io_object_t = 0
    private var puerto: IONotificationPortRef?

    func arrancar() {
        guard puertoRaiz == 0 else { return }
        let contexto = Unmanaged.passUnretained(self).toOpaque()
        puertoRaiz = IORegisterForSystemPower(contexto, &puerto, { contexto, _, tipo, argumento in
            guard let contexto else { return }
            Unmanaged<AntesDeDormir>.fromOpaque(contexto).takeUnretainedValue().mensaje(tipo, argumento)
        }, &notificador)
        guard puertoRaiz != 0, let puerto else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(puerto).takeUnretainedValue(), .commonModes)
    }

    private func mensaje(_ tipo: natural_t, _ argumento: UnsafeMutableRawPointer?) {
        let id = Int(bitPattern: argumento)
        switch tipo {
        case 0xE000_0270:   // kIOMessageCanSystemSleep: dormir por inactividad, se permite
            IOAllowPowerChange(puertoRaiz, id)
        case 0xE000_0280:   // kIOMessageSystemWillSleep: se va a dormir; hasta 20 s para copiar lo pendiente
            var hecho = false
            let terminar = { [weak self] in
                guard let self, !hecho else { return }
                hecho = true
                IOAllowPowerChange(self.puertoRaiz, id)
            }
            if let preparar { preparar(terminar) } else { terminar() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: terminar)
        default:
            break
        }
    }
}
