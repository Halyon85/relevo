import DiskArbitration
import Foundation

/// Avisa apenas macOS monta un disco, preguntándole directo al sistema de discos (DiskArbitration). El aviso del Finder
/// (`NSWorkspace.didMountNotification`) puede llegar mucho después: el 31/10/2026 el hub estuvo montado 28 segundos
/// antes de que Relevo se enterara. Publica `Montajes.montado` (con la ruta en `userInfo["ruta"]`); lo escucha cada
/// `Coordinador`, igual que el aviso del Finder (que sigue: si llegan los dos, el segundo no cambia nada).
/// Lo arranca `AppDelegate` una sola vez.
final class Montajes {
    static let montado = Notification.Name("team.halyon.relevo.montado")
    static let shared = Montajes()

    private var sesion: DASession?

    func arrancar() {
        guard sesion == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        sesion = s
        // Avisa cuando cambia la ruta de un volumen: aparece al montarlo (y cambia al renombrarlo).
        let claves = [kDADiskDescriptionVolumePathKey] as CFArray
        DARegisterDiskDescriptionChangedCallback(s, nil, claves, { disco, _, _ in
            guard let d = DADiskCopyDescription(disco) as? [CFString: Any],
                  let url = d[kDADiskDescriptionVolumePathKey] as? URL else { return }
            let ruta = url.path.hasSuffix("/") && url.path.count > 1 ? String(url.path.dropLast()) : url.path
            guard ruta.hasPrefix("/Volumes/") else { return }
            Bitacora.anotar("Se montó \(ruta) (aviso directo de macOS)")
            NotificationCenter.default.post(name: Montajes.montado, object: nil, userInfo: ["ruta": ruta])
        }, nil)
        DASessionSetDispatchQueue(s, .main)
    }
}
