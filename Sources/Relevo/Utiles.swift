import AppKit
import Foundation
import RelevoNucleo
import UserNotifications

extension String {
    func estaDentroDe(_ carpeta: String) -> Bool { self == carpeta || hasPrefix(carpeta + "/") }
    /// "Proyectos/A/borradores" → "Proyectos/A" (vacío si no tiene carpeta madre).
    var padreDeRuta: String { (self as NSString).deletingLastPathComponent }
}

enum Formato {
    /// Tamaños con la coma o el punto del idioma de la app ("1,2 GB" en español, "1.2 GB" en inglés).
    static func bytes(_ b: Int64) -> String {
        b.formatted(.byteCount(style: .file, spellsOutZero: false).locale(Idioma.locale))   // "0 KB", no "Zero KB"
    }

    /// Cantidades con el separador de miles del idioma de la app ("68.000" / "68,000").
    static func numero(_ n: Int) -> String { n.formatted(.number.locale(Idioma.locale)) }

    static func haceCuanto(_ fecha: Date) -> String {
        let s = Date().timeIntervalSince(fecha)
        if s < 60 { return T("recién") }
        if s < 3600 { return T("hace %ld min", Int(s / 60)) }
        if s < 86400 { return T("hace %ld h", Int(s / 3600)) }
        return fechaCorta(fecha, "d/M HH:mm", plantillaIngles: "MMMdjmm")
    }

    static func hora(_ fecha: Date) -> String {
        let hoy = Calendar.current.isDateInToday(fecha)
        return fechaCorta(fecha, hoy ? "HH:mm" : "d/M HH:mm", plantillaIngles: hoy ? "jmm" : "MMMdjmm")
    }

    /// Fecha corta en el idioma de la app: en español con su formato fijo; en inglés, como la arma macOS ("Oct 21, 2:05 PM").
    private static func fechaCorta(_ fecha: Date, _ formatoEspanol: String, plantillaIngles: String) -> String {
        let f = DateFormatter()
        if Idioma.activo == .en {
            f.locale = Locale(identifier: "en_US")
            f.setLocalizedDateFormatFromTemplate(plantillaIngles)
        } else {
            f.locale = Locale(identifier: "es_AR")
            f.dateFormat = formatoEspanol
        }
        return f.string(from: fecha)
    }

    /// Segundos hasta mañana a las 8.
    static func segundosHastaManana() -> Double {
        let cal = Calendar.current
        let manana = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: Date()))!.addingTimeInterval(8 * 3600)
        return manana.timeIntervalSinceNow
    }
}

enum Notificar {
    /// RELEVO_PRUEBA=1: modo de prueba (sin avisos del sistema y con registro en la salida).
    static let prueba = ProcessInfo.processInfo.environment["RELEVO_PRUEBA"] != nil

    static func pedirPermiso() {
        guard !prueba else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func enviar(_ titulo: String, _ cuerpo: String) {
        if prueba { print("AVISO \(titulo): \(cuerpo)"); fflush(stdout); return }
        let c = UNMutableNotificationContent()
        c.title = titulo
        c.body = cuerpo
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

/// La papelera de cada disco guarda lo borrado y las versiones pisadas. Lo más viejo que los días elegidos se va.
enum Papelera {
    static func limpiar(_ volumenes: [String], dias: Int) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "es_AR")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let limite = Date().addingTimeInterval(-Double(dias) * 86400)
        for v in volumenes {
            let base = Sincronizador.papelera(v)
            // Solo si .Relevo/Papelera es una carpeta de verdad en ese disco (no un enlace armado en el portátil).
            guard Rutas.sinEnlaces(base, desde: v) else { continue }
            for sello in (try? FileManager.default.contentsOfDirectory(atPath: base)) ?? [] {
                guard let fecha = f.date(from: sello), fecha < limite else { continue }
                try? FileManager.default.removeItem(atPath: base + "/" + sello)
            }
        }
    }

    /// Cuánto ocupa la papelera de `volumen` (la carpeta raíz de un lado). Lo usa "Vaciar ahora" en General.
    static func tamano(_ volumen: String) -> Int64 {
        let base = Sincronizador.papelera(volumen)
        // Igual que al limpiar: si .Relevo/Papelera no es una carpeta de verdad (un enlace armado), no se recorre.
        guard Rutas.sinEnlaces(base, desde: volumen), let e = FileManager.default.enumerator(at: URL(fileURLWithPath: base), includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }
}

/// La copia de compilación (adentro de build/ o .build/) no se queda corriendo como la app de todos los días: si macOS
/// la abrió (por ejemplo, al iniciar sesión, porque encontró esa copia antes que la instalada) y hay una en
/// Aplicaciones, abre esa y se cierra. Así Relevo nunca deja ocupado el disco donde está el proyecto (que suele ser
/// el hub) y expulsar o acomodar no se traban. Las pruebas (RELEVO_PRUEBA) sí corren desde la copia de compilación.
enum Instalada {
    static let ruta = "/Applications/Relevo.app"

    /// Lo llama `Principal.main` antes de arrancar. Devuelve true si abrió la instalada (y esta tiene que terminar).
    static func abrirEnSuLugar() -> Bool {
        let aca = Bundle.main.bundleURL.standardizedFileURL.path
        guard !Notificar.prueba, aca != ruta, aca.contains("/build/") || aca.contains("/.build/"),
              FileManager.default.fileExists(atPath: ruta) else { return false }
        // Si la instalada ya está abierta, esta solo se cierra (nunca dos Relevo a la vez).
        if NSWorkspace.shared.runningApplications.contains(where: { $0.bundleURL?.standardizedFileURL.path == ruta }) { return true }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true   // si no, macOS "activa" esta misma en vez de abrir la otra
        config.activates = false
        let listo = DispatchSemaphore(value: 0)
        var abrio = false
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: ruta), configuration: config) { app, _ in
            abrio = app != nil
            listo.signal()
        }
        _ = listo.wait(timeout: .now() + 15)
        return abrio
    }
}
