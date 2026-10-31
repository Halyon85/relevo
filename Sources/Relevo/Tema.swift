import AppKit
import SwiftUI

// Paleta: grises cálidos y acento coral.
enum Tema {
    static func dinamico(_ claro: UInt32, _ oscuro: UInt32, alfaClaro: CGFloat = 1, alfaOscuro: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { apariencia in
            let esOscuro = apariencia.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: esOscuro ? oscuro : claro, alfa: esOscuro ? alfaOscuro : alfaClaro)
        })
    }

    static let fondo = dinamico(0xFBFAF9, 0x1D1D1C)
    static let fondoMedio = dinamico(0xF6F0EC, 0x161616)
    static let tarjeta = dinamico(0xFFFFFF, 0x242321)
    static let relleno = dinamico(0x2B2A29, 0xFFE4D3, alfaClaro: 0.05, alfaOscuro: 0.08)
    static let rellenoSuave = dinamico(0x2B2A29, 0xFFDBB7, alfaClaro: 0.03, alfaOscuro: 0.06)
    static let titulo = dinamico(0x161616, 0xFAF7F7)
    static let texto = dinamico(0x1D1D1C, 0xF8F4F3)
    static let subtitulo = dinamico(0x494543, 0xD0C4C0)
    static let apagado = dinamico(0x877A76, 0x9F928E)
    static let borde = dinamico(0x2B2A29, 0xFFE8DC, alfaClaro: 0.12, alfaOscuro: 0.15)
    static let bordeSuave = dinamico(0x2B2A29, 0xFFDCC6, alfaClaro: 0.06, alfaOscuro: 0.10)
    static let acento = Color(nsColor: NSColor(hex: 0xF56138))
    static let violeta = Color(nsColor: NSColor(hex: 0x8B5CF6))
    static let exito = Color(nsColor: NSColor(hex: 0x00B489))
    static let error = Color(nsColor: NSColor(hex: 0xE5484D))
    // La píldora es "botón primario": casi negra en claro, casi blanca en oscuro.
    static let pildora = dinamico(0x1D1D1C, 0xFAF7F7)
    static let pildoraTexto = dinamico(0xFFFFFF, 0x000000)

    static let radioTarjeta: CGFloat = 14
    static let anchoBarra: CGFloat = 220
    static let anchoPagina: CGFloat = 640

    static let arcoiris = LinearGradient(
        colors: [Color(hex: 0xFF989A), Color(hex: 0xFF9BEB), Color(hex: 0x9173FF),
                 Color(hex: 0x54FE8A), Color(hex: 0xF0FE54), Color(hex: 0xFE8D54)],
        startPoint: .leading, endPoint: .trailing)

    // Curva "expo" que usan para entrar y salir.
    static let expo = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.36)
}

extension NSColor {
    convenience init(hex: UInt32, alfa: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alfa)
    }
}

extension Color {
    init(hex: UInt32) { self.init(nsColor: NSColor(hex: hex)) }
}

extension Font {
    static func titulo(_ tam: CGFloat, _ peso: Font.Weight = .medium) -> Font { .system(size: tam, weight: peso, design: .default) }
}

// En este SDK `@State` es un macro que solo trae Xcode completo; el alias usa el envoltorio clásico.
typealias Estado<Value> = SwiftUI.State<Value>
