import Darwin
import Foundation
@testable import RelevoNucleo

/// Pruebas de la auditoría de seguridad del 23/10/2026: lo que llega en un portátil armado en otra máquina (enlaces
/// en lugar de carpetas, una base falsa, tamaños imposibles, carpetas que no se pueden leer, zonas con "..") nunca
/// hace que Relevo escriba fuera de lo que sincroniza, ni que se cierre o se trabe.
extension Escenarios {
    static let seguridad: [(String, () throws -> Void)] = [
        ("Seguridad: una carpeta cambiada por un enlace en el portátil no hace escribir fuera", { try Escenarios().enlaceIntermedio() }),
        ("Seguridad: una carpeta madre enlazada en el portátil no se sincroniza", { try Escenarios().raizEnlazada() }),
        ("Seguridad: zonas con \"..\" se miran enteras (no salen del par)", { try Escenarios().zonasConPuntos() }),
        ("Seguridad: una base falsa con una cantidad enorme no reserva memoria", { try Escenarios().baseFalsa() }),
        ("Seguridad: tamaños imposibles se suman sin cerrar la app", { try Escenarios().sumasSinDesborde() }),
        ("Seguridad: miles de carpetas ilegibles no traban el plan", { try Escenarios().muchasIlegibles() }),
    ]

    /// En el portátil, "sub" (ya sincronizada) se cambia por un enlace a una carpeta de afuera. Lo nuevo del hub abajo
    /// de "sub" no puede terminar en esa carpeta de afuera.
    func enlaceIntermedio() throws {
        let b = Banco()
        let afuera = b.raiz + "/afuera"
        try FileManager.default.createDirectory(atPath: afuera, withIntermediateDirectories: true)
        b.escribir(.hub, "sub/d/f.txt", "v1", hace: 100)
        try b.sincronizar()
        try FileManager.default.removeItem(atPath: b.ruta(.portatil, "sub"))
        symlink(afuera, b.ruta(.portatil, "sub"))
        b.escribir(.hub, "sub/d/f.txt", "v2", hace: 5)
        b.escribir(.hub, "sub/e/g.txt", "nuevo", hace: 5)
        _ = try? b.sincronizar(confirmado: true)
        let quedo = (try? FileManager.default.contentsOfDirectory(atPath: afuera)) ?? []
        espero(quedo.isEmpty)
        if !quedo.isEmpty { print("  DEBUG afuera:", quedo) }
    }

    /// "Proyectos" del portátil (la carpeta madre de los pares) es un enlace a otra carpeta: Relevo no la lee ni escribe.
    func raizEnlazada() throws {
        let b = Banco()
        let afuera = b.raiz + "/afuera"
        try FileManager.default.createDirectory(atPath: afuera + "/Demo", withIntermediateDirectories: true)
        try "secreto".write(toFile: afuera + "/Demo/secreto.txt", atomically: false, encoding: .utf8)
        b.escribir(.hub, "a.txt", "hub")
        symlink(afuera, b.portatil + "/Proyectos")
        esperoError { _ = try b.sinc.analizar(b.carpeta) }
        espero(!b.existe(.hub, "secreto.txt"))
        espero(!FileManager.default.fileExists(atPath: afuera + "/Demo/a.txt"))
        espero(Rutas.sinEnlaces(b.ruta(.portatil, ""), desde: b.portatil) == false)
    }

    func zonasConPuntos() throws {
        let b = Banco()
        b.escribir(.hub, "x.txt", "x", hace: 100)
        try b.sincronizar()
        let a = try b.sinc.analizar(b.carpeta, zonas: Zonas(planas: ["../.."]))
        espero(!a.porZonas)
        espero(Rutas.relativaSegura("a/b") && !Rutas.relativaSegura("a/../b") && !Rutas.relativaSegura("a//b") && Rutas.relativaSegura(""))
    }

    /// 12 bytes: "SGB1", cantidad 0xFFFFFFFF, "FIN!". Antes pedía memoria para 4 mil millones de registros.
    func baseFalsa() throws {
        let b = Banco()
        let url = URL(fileURLWithPath: b.raiz + "/falsa.base")
        try Data([0x53, 0x47, 0x42, 0x31, 0xFF, 0xFF, 0xFF, 0xFF, 0x46, 0x49, 0x4E, 0x21]).write(to: url)
        let t = Date()
        espero(Base.cargar(url) == nil)
        espero(Date().timeIntervalSince(t) < 1)
    }

    func sumasSinDesborde() throws {
        espero(Rutas.sumar(.max - 5, 10) == .max)
        espero(Rutas.sumar(.min + 5, -10) == .min)
        espero(Rutas.sumar(3, 4) == 7)
        var f = Foto()
        f.bytes = .max - 1
        f.bytes = Rutas.sumar(f.bytes, 1 << 62)
        espero(f.bytes == .max)
    }

    /// 3000 rutas "ilegibles": antes el plan miraba la lista entera por cada ruta (millones de comparaciones).
    func muchasIlegibles() throws {
        var hub = Foto(), port = Foto()
        for i in 0..<3000 {
            port.noLeidas.append("n\(i)")
            port.entradas["n\(i)"] = Entrada(tipo: .carpeta)
            hub.entradas["h\(i)/a.txt"] = Entrada(tipo: .archivo, tamano: 1, mtime: 1)
        }
        let t = Date()
        let plan = Planificador.planificar(hub: hub, portatil: port, base: Base()) { _ in false }
        espero(Date().timeIntervalSince(t) < 2)
        espero(plan.copias.count == 3000)
        espero(Foto.noLeida("n5/x/y", en: ["n5"]) && !Foto.noLeida("n50", en: ["n5"]) && Foto.noLeida("z", en: [""]))
    }
}
