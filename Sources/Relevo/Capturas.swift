import AppKit
import SwiftUI

// Modo de prueba: `Relevo --capturas <carpeta>` dibuja cada pantalla en PNG (claro y oscuro) y sale.
// Sirve para revisar el diseño sin abrir ventanas.
enum Capturas {
    static func hacer(en carpeta: String) {
        let url = URL(fileURLWithPath: carpeta, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        iconosBarra(en: url)
        for hub in [true, false] {
            let img = MarcaDisco.dibujar(hub: hub)
            if let t = img.tiffRepresentation, let rep = NSBitmapImageRep(data: t) {
                try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent(hub ? "disco-hub.png" : "disco-portatil.png"))
            }
        }
        let gestor = Gestor(activo: false)
        let nav = Navegacion()
        // Más alto para revisar páginas largas enteras (RELEVO_CAPTURAS_ALTO=1600).
        let alto = Double(ProcessInfo.processInfo.environment["RELEVO_CAPTURAS_ALTO"] ?? "") ?? 760
        // Y más angosto o más ancho para revisar cómo se acomoda (RELEVO_CAPTURAS_ANCHO=760, el mínimo de la ventana).
        let ancho = Double(ProcessInfo.processInfo.environment["RELEVO_CAPTURAS_ANCHO"] ?? "") ?? 920
        for (nombre, apariencia) in [("claro", NSAppearance(named: .aqua)!), ("oscuro", NSAppearance(named: .darkAqua)!)] {
            NSApp.appearance = apariencia
            // Repositorios muestra la cuenta de GitHub de quien la corre: solo si se pide (RELEVO_CAPTURAR_REPOS=1).
            for p in Pagina.allCases where p != .repos || ProcessInfo.processInfo.environment["RELEVO_CAPTURAR_REPOS"] != nil {
                nav.pagina = p
                let vista = VistaPanel(gestor: gestor, ajustes: .shared, navegacion: nav)
                guardar(vista, tam: NSSize(width: ancho, height: alto), apariencia: apariencia, espera: p == .repos ? 8 : 0.4,
                        en: url.appendingPathComponent("panel-\(p.rawValue)-\(nombre).png"))
                if p == .carpetas {
                    // La segunda pestaña: lo que nunca se sincroniza.
                    nav.pestanaReleva = .nunca
                    guardar(VistaPanel(gestor: gestor, ajustes: .shared, navegacion: nav), tam: NSSize(width: ancho, height: alto),
                            apariencia: apariencia, en: url.appendingPathComponent("panel-nunca-\(nombre).png"))
                    nav.pestanaReleva = .carpetas
                }
            }
            // El asistente para vincular, paso por paso, con los discos del primer vínculo (si están enchufados).
            let v = Ajustes.shared.datos.vinculos.first
            let hub = v.flatMap { Discos.buscar($0.hub.uuid) }.map { Lugar(uuid: $0.uuid, nombre: $0.nombre) }
            let portatil = v.flatMap { Discos.buscar($0.portatil.uuid) }
            for paso in [Asistente.Paso.bienvenida, .casa, .portatil, .rutas, .resumen] {
                guardar(Asistente(gestor: gestor, navegacion: nav, paso: paso, hub: hub, portatil: portatil),
                        tam: NSSize(width: 640, height: 600), apariencia: apariencia,
                        en: url.appendingPathComponent("asistente-\(paso)-\(nombre).png"))
            }
        }
    }

    /// El ícono de la barra en sus estados, grande (x8) y a tamaño real (x2), sobre barra clara y oscura.
    private static func iconosBarra(en url: URL) {
        let variantes: [(String, NSImage)] = [
            ("normal", IconoBarra.imagen()), ("copiando", IconoBarra.imagen(copiando: true, cuadro: 1)),
            ("aviso", IconoBarra.imagen(marca: .punto)), ("desconectado", IconoBarra.imagen(apagado: true)),
        ]
        let escala: CGFloat = 8
        let ancho = CGFloat(variantes.count) * 30 * escala, alto = 2 * 22 * escala
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ancho), pixelsHigh: Int(alto), bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        for (fila, (fondo, tinta)) in [(NSColor(white: 0.93, alpha: 1), NSColor.black), (NSColor(white: 0.16, alpha: 1), NSColor.white)].enumerated() {
            fondo.setFill()
            NSRect(x: 0, y: CGFloat(fila) * 22 * escala, width: ancho, height: 22 * escala).fill()
            for (i, (_, img)) in variantes.enumerated() {
                let destino = NSRect(x: (CGFloat(i) * 30 + 5) * escala, y: (CGFloat(fila) * 22 + 3) * escala, width: 20 * escala, height: 16 * escala)
                let teñida = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r); tinta.set(); r.fill(using: .sourceAtop); return true
                }
                teñida.draw(in: destino)
                teñida.draw(in: NSRect(x: destino.maxX - 6 * escala, y: destino.minY - 2.5 * escala, width: 40, height: 32))
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url.appendingPathComponent("icono-barra.png"))
    }

    private static func guardar<V: View>(_ vista: V, tam: NSSize, apariencia: NSAppearance, espera: TimeInterval = 0.4, en destino: URL) {
        let host = NSHostingView(rootView: vista)
        host.appearance = apariencia
        let ventana = NSWindow(contentRect: NSRect(origin: NSPoint(x: -20_000, y: -20_000), size: tam),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        ventana.appearance = apariencia
        ventana.contentView = host
        ventana.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(espera))
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: destino)
        ventana.orderOut(nil)
    }
}
