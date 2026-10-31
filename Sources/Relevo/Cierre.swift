import AppKit
import Foundation

/// Si Relevo se cerró bien la última vez. Después de un corte de luz, la Mac colgada o Relevo cerrado de golpe, el
/// registro de cambios de macOS (FSEvents) puede no haber guardado lo último que pasó en los discos: entonces cada
/// vínculo mira todo en la próxima revisión inteligente, sin atajos (`Coordinador.revisarTodoLaProxima`).
/// Lo arranca `Principal.main` (antes de crear los coordinadores) y lo cierra `Delegado.applicationWillTerminate`.
enum Cierre {
    private static let clave = "cerradaBien"
    private static var senal: DispatchSourceSignal?

    /// Se lee una sola vez, al arrancar: queda anotado "abierta" hasta que se cierre bien.
    static let anteriorFueLimpio: Bool = {
        let limpio = UserDefaults.standard.bool(forKey: clave)
        UserDefaults.standard.set(false, forKey: clave)
        UserDefaults.standard.synchronize()
        return limpio
    }()

    /// Al arrancar la app: anota que está abierta y hace que la señal de terminar (kill, apagar desde la terminal)
    /// cierre prolijo, pasando por `cerrandoBien`.
    static func arrancar() {
        _ = anteriorFueLimpio
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        s.setEventHandler { NSApp.terminate(nil) }
        s.resume()
        senal = s
    }

    static func cerrandoBien() {
        UserDefaults.standard.set(true, forKey: clave)
        UserDefaults.standard.synchronize()
    }
}
