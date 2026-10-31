import Darwin
import Foundation

/// Controles de rutas frente a contenido armado en un disco que viaja (auditoría de seguridad del 23/10/2026).
/// El portátil puede haberse escrito en otra máquina: una carpeta cambiada por un enlace (atajo) haría que Relevo
/// lea o escriba fuera de las carpetas que sincroniza, en cualquier lugar de la Mac. Lo usan el motor (`Ejecutor`,
/// `Sincronizador`) y la app (`Lugar.raiz`, `Coordinador.pares`, `Restaurar`, `Papelera.limpiar`).
public enum Rutas {
    /// ¿Cada parte de `ruta`, desde `raiz` (que tiene que ser una carpeta de verdad), es una carpeta de verdad (no un
    /// enlace) en el mismo disco que `raiz`? Si una parte todavía no existe, se mira hasta ahí: lo que falta lo crea
    /// Relevo y es una carpeta de verdad. `ruta` tiene que ser `raiz` o estar adentro.
    public static func sinEnlaces(_ ruta: String, desde raiz: String) -> Bool {
        var st = stat()
        guard lstat(raiz, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { return false }
        let disco = st.st_dev
        guard ruta != raiz else { return true }
        guard ruta.hasPrefix(raiz + "/") else { return false }
        var actual = raiz
        for parte in ruta.dropFirst(raiz.count + 1).split(separator: "/", omittingEmptySubsequences: false) {
            if parte == "." { continue }   // "Xcode/." (archivos sueltos): no cambia de lugar
            guard !parte.isEmpty, parte != ".." else { return false }
            actual += "/" + parte
            guard lstat(actual, &st) == 0 else { return errno == ENOENT }
            guard (st.st_mode & S_IFMT) == S_IFDIR, st.st_dev == disco else { return false }
        }
        return true
    }

    /// Una ruta relativa que podría venir de un listado real: sin "..", "." ni partes vacías ("" es la raíz).
    /// Las zonas que avisa el registro de cambios del disco se miran con esto antes de usarlas.
    public static func relativaSegura(_ ruta: String) -> Bool {
        ruta.isEmpty || !ruta.split(separator: "/", omittingEmptySubsequences: false).contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// Suma de tamaños que nunca se desborda (los tamaños los informa el disco: uno armado podría pasarse del máximo
    /// y, con una suma común, cerrar la app en cada revisión).
    @inlinable public static func sumar(_ a: Int64, _ b: Int64) -> Int64 {
        let (r, desborde) = a.addingReportingOverflow(b)
        return desborde ? (b > 0 ? .max : .min) : r
    }
}
