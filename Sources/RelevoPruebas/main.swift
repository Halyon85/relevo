import Foundation

// Pruebas del motor sin Xcode: `swift run RelevoPruebas` (o con un texto para filtrar por nombre).

nonisolated(unsafe) var fallas: [String] = []

func espero(_ condicion: @autoclosure () throws -> Bool, _ archivo: StaticString = #fileID, _ linea: UInt = #line) {
    do {
        if try !condicion() { fallas.append("línea \(linea)") }
    } catch {
        fallas.append("línea \(linea): \(error)")
    }
}

func esperoError(_ archivo: StaticString = #fileID, _ linea: UInt = #line, _ bloque: () throws -> Void) {
    do { try bloque(); fallas.append("línea \(linea): esperaba un error") } catch {}
}

let filtro = CommandLine.arguments.dropFirst().first
var mal = 0
let inicio = Date()
// Las de siempre, las de la revisión por zonas y otra vez las de siempre copiando por zonas (con avisos de todas las
// carpetas: tiene que dar lo mismo que mirar todo).
let todas = Escenarios.todas + Escenarios.porZonas + Escenarios.seguridad + Escenarios.todas.map { nombre, prueba in
    ("[por zonas] " + nombre, { Banco.porZonas = true; defer { Banco.porZonas = false }; try prueba() })
}
for (nombre, prueba) in todas where filtro == nil || nombre.localizedCaseInsensitiveContains(filtro!) {
    fallas = []
    let t = Date()
    do { try prueba() } catch { fallas.append("error: \(error)") }
    let ms = Int(Date().timeIntervalSince(t) * 1000)
    if fallas.isEmpty {
        print("✓ \(nombre) (\(ms) ms)")
    } else {
        mal += 1
        print("✗ \(nombre): \(fallas.joined(separator: ", "))")
    }
}
print(mal == 0 ? "\nTodo bien (\(String(format: "%.1f", Date().timeIntervalSince(inicio))) s)" : "\n\(mal) con problemas")
exit(mal == 0 ? 0 : 1)
