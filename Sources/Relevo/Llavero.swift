import Foundation
import Security

/// La clave de cada disco cifrado, guardada en el llavero de macOS (una por disco, por su UUID).
/// Primero intenta el llavero de iCloud (así aparece también en el iPhone, en la app Contraseñas). Eso pide un permiso
/// de Apple (entitlement + perfil de aprovisionamiento) que una app armada sin Xcode no tiene: si falla, queda en el
/// llavero de inicio de sesión de esta Mac y la hoja de cifrar recomienda copiarla a mano a Contraseñas o a un papel.
enum Llavero {
    enum Donde: String {
        case icloud
        case estaMac
    }

    static let servicio = "Relevo - clave del disco"

    /// Guarda la clave de un disco que todavía no tiene una. Devuelve dónde quedó, o nil si no se pudo guardar (o si ya
    /// había una: nunca se pisa ni se borra la clave de un disco cifrado; un disco que solo dice tener ese UUID podría
    /// hacer perder la clave del de verdad, auditoría del 23/10).
    @discardableResult
    static func guardar(_ clave: String, uuid: String, nombre: String) -> Donde? {
        guard donde(uuid) == nil else { ultimoError = errSecDuplicateItem; return nil }
        var item: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: uuid,
            kSecAttrLabel as String: T("Relevo: clave del disco %@", nombre),
            kSecAttrDescription as String: T("Clave de disco cifrado"),
            kSecAttrComment as String: T("La pide otra Mac al enchufar el disco “%@”. Relevo la usa para abrirlo solo en esta.", nombre),
            kSecValueData as String: Data(clave.utf8),
        ]
        // 1) iCloud: sincronizable + llavero moderno (el de iOS). Hace falta poder abrirla con la Mac bloqueada:
        //    "después del primer desbloqueo" (los "solo este dispositivo" no se sincronizan).
        var icloud = item
        icloud[kSecAttrSynchronizable as String] = kCFBooleanTrue
        icloud[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        icloud[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        ultimoError = SecItemAdd(icloud as CFDictionary, nil)
        if ultimoError == errSecSuccess { return .icloud }
        // 2) El llavero de inicio de sesión de esta Mac.
        item[kSecAttrSynchronizable as String] = kCFBooleanFalse
        let r = SecItemAdd(item as CFDictionary, nil)
        if r == errSecSuccess { return .estaMac }
        ultimoError = r
        return nil
    }

    /// Por qué falló lo último (código de Security, ej. -34018 = falta el permiso de iCloud). Para diagnosticar.
    private(set) static var ultimoError: OSStatus = errSecSuccess

    static func leer(_ uuid: String) -> String? {
        for consulta in consultas(uuid) {
            var q = consulta
            q[kSecReturnData as String] = kCFBooleanTrue
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var resultado: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &resultado) == errSecSuccess, let datos = resultado as? Data {
                return String(decoding: datos, as: UTF8.self)
            }
        }
        return nil
    }

    /// Dónde está guardada (nil si no está en ningún lado).
    static func donde(_ uuid: String) -> Donde? {
        let c = consultas(uuid)
        if SecItemCopyMatching(c[0] as CFDictionary, nil) == errSecSuccess { return .icloud }
        if SecItemCopyMatching(c[1] as CFDictionary, nil) == errSecSuccess { return .estaMac }
        return nil
    }

    /// Borra la clave de los dos llaveros. Devuelve true si había algo y se borró.
    @discardableResult
    static func borrar(_ uuid: String) -> Bool {
        var borro = false
        for q in consultas(uuid) where SecItemDelete(q as CFDictionary) == errSecSuccess { borro = true }
        return borro
    }

    /// Las dos búsquedas: llavero moderno (con iCloud) y llavero de inicio de sesión.
    private static func consultas(_ uuid: String) -> [[String: Any]] {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicio,
            kSecAttrAccount as String: uuid,
        ]
        var moderno = base
        moderno[kSecUseDataProtectionKeychain as String] = kCFBooleanTrue
        moderno[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        var local = base
        local[kSecAttrSynchronizable as String] = kSecAttrSynchronizableAny
        return [moderno, local]
    }
}
