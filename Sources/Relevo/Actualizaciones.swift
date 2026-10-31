import AppKit
import Sparkle

/// Actualizaciones con Sparkle, solo en las versiones publicadas por Halyon Team. Esas llevan en su Info.plist la
/// dirección de la lista de versiones (`SUFeedURL`) y la clave pública con la que se firma cada una (`SUPublicEDKey`):
/// las pone `herramientas/publicar-version.sh`. La que compila cada uno con `compilar.sh` no las tiene y no busca nada
/// (si buscara, le cambiaría su app por la nuestra): se actualiza con `git pull`. Lo usan `Delegado` al arrancar y el
/// menú ("Buscar actualizaciones de Relevo…").
enum Actualizaciones {
    /// ¿Esta copia de Relevo es una versión publicada (con lista de versiones y clave)? Las pruebas nunca buscan.
    static var disponibles: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let lista = (info["SUFeedURL"] as? String) ?? "", clave = (info["SUPublicEDKey"] as? String) ?? ""
        return !lista.isEmpty && !clave.isEmpty && !Notificar.prueba
    }

    private static var controlador: SPUStandardUpdaterController?
    private static let aviso = AvisoActualizacion()

    /// Prende la búsqueda diaria (cada cuánto y que sea automática lo dice el Info.plist de la versión publicada).
    static func arrancar() {
        guard disponibles, controlador == nil else { return }
        controlador = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: aviso)
    }

    /// "Buscar actualizaciones de Relevo…" del menú.
    static func buscar() {
        NSApp.activate(ignoringOtherApps: true)
        controlador?.checkForUpdates(nil)
    }
}

/// Relevo vive en la barra de menú (sin ícono en el Dock): cuando Sparkle encuentra una versión nueva por su cuenta,
/// trae la app adelante para que la ventana no quede escondida detrás de las demás.
private final class AvisoActualizacion: NSObject, SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        true
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        if handleShowingUpdate { NSApp.activate(ignoringOtherApps: true) }
    }
}
