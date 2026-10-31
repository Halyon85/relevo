import AppKit

/// Ícono de la barra de menú, dibujado en código (nítido en cualquier pantalla y sin archivos): el mismo "relevo"
/// del ícono de la app. El disco de casa va en contorno, el que se va relleno y con líneas de velocidad.
/// Es una imagen "plantilla": macOS la pinta blanca o negra según la barra.
enum IconoBarra {
    enum Marca { case ninguna, punto, vacio }

    /// `cuadro` (0…2) mueve las líneas de velocidad mientras copia.
    static func imagen(marca: Marca = .ninguna, copiando: Bool = false, cuadro: Int = 0, apagado: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: 20, height: 16), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let alfa: CGFloat = apagado ? 0.45 : 1

            // Disco de casa: contorno, abajo a la izquierda.
            let casa = disco(x: 1.0, y: 8.6, ancho: 9.4)
            casa.lineWidth = 1.4
            NSColor.black.withAlphaComponent(alfa).setStroke()
            casa.stroke()

            // Disco que se va: relleno, arriba a la derecha, encima del otro.
            let va = disco(x: 9.0, y: 2.6)
            NSGraphicsContext.current?.compositingOperation = .clear
            let aire = disco(x: 9.0, y: 2.6, crecer: 1.1)
            aire.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.withAlphaComponent(alfa).setFill()
            va.fill()

            // Líneas de velocidad (se corren mientras copia).
            let corrimiento = copiando ? CGFloat(cuadro % 3) * 0.9 : 0
            for (i, largo) in [CGFloat(4.4), 3.0].enumerated() {
                let y = 2.2 + CGFloat(i) * 2.3
                let x0 = 8.2 - corrimiento - largo
                let linea = NSBezierPath()
                linea.move(to: NSPoint(x: x0, y: y + largo * 0.32))
                linea.line(to: NSPoint(x: x0 + largo, y: y))
                linea.lineWidth = 1.3
                linea.lineCapStyle = .round
                NSColor.black.withAlphaComponent(alfa * (copiando ? 1 : 0.8)).setStroke()
                linea.stroke()
            }

            switch marca {
            case .ninguna: break
            case .punto:
                NSGraphicsContext.current?.compositingOperation = .clear
                NSBezierPath(ovalIn: NSRect(x: 13.6, y: 9.6, width: 6.4, height: 6.4)).fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 14.6, y: 10.6, width: 4.4, height: 4.4)).fill()
            case .vacio:
                break
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Relevo"
        return img
    }

    /// Un disco: rectángulo redondeado inclinado como en el ícono.
    private static func disco(x: CGFloat, y: CGFloat, ancho: CGFloat = 10, crecer: CGFloat = 0) -> NSBezierPath {
        let r = NSRect(x: x - crecer, y: y - crecer, width: ancho + crecer * 2, height: 5.6 + crecer * 2)
        let p = NSBezierPath(roundedRect: r, xRadius: 2 + crecer, yRadius: 2 + crecer)
        var t = AffineTransform(translationByX: r.midX, byY: r.midY)
        t.rotate(byDegrees: -18)
        t.translate(x: -r.midX, y: -r.midY)
        p.transform(using: t)
        return p
    }
}
