import AppKit
import SwiftUI

// Piezas comunes de la interfaz.

// Atribución del desarrollo (regla de Halyon Team).
struct PieHalyon: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Text(T("Desarrollado por"))
                Link(destination: URL(string: "https://halyon.team")!) {
                    Text("Halyon Team").fontWeight(.semibold).underline(pattern: .dot)
                }
                .foregroundStyle(Tema.subtitulo)
                .focusable(false)   // si no, macOS le pone el recuadro de foco al abrir la ventana
            }
            Text(T("Hecho en Argentina 🇦🇷"))
        }
        .font(.system(size: 11))
        .foregroundStyle(Tema.apagado)
        .padding(8)
    }
}

// El logo de la app (el mismo ícono del Dock). El ícono trae un margen transparente: se agranda un poco para llenar.
struct Logo: View {
    var tam: CGFloat
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .scaleEffect(1.22)
            .frame(width: tam, height: tam)
    }
}

// MARK: Piezas comunes

struct TituloPagina: View {
    let titulo: String
    var subtitulo: String? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(titulo).font(.titulo(20)).foregroundStyle(Tema.titulo)
            if let s = subtitulo { Text(s).font(.system(size: 14)).foregroundStyle(Tema.apagado) }
        }
    }
}

struct Tarjeta<C: View>: View {
    var titulo: String? = nil
    @ViewBuilder var contenido: C
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let t = titulo {
                Text(t).font(.titulo(13)).foregroundStyle(Tema.apagado).padding(.leading, 4)
            }
            VStack(spacing: 0) { contenido }
                .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
                .shadow(color: .black.opacity(0.02), radius: 4, y: 2)
        }
    }
}

struct Fila<D: View>: View {
    let titulo: String
    var detalle: String? = nil
    var divisor = true
    /// Ancho mínimo del texto antes de que los controles bajen a la línea de abajo.
    var minimoTexto: CGFloat = 220
    @ViewBuilder var derecha: D
    var body: some View {
        VStack(spacing: 0) {
            TextoYControles(minimoTexto: minimoTexto) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(titulo).font(.titulo(14, .regular)).foregroundStyle(Tema.titulo)
                        .fixedSize(horizontal: false, vertical: true)
                    if let d = detalle {
                        Text(d).font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Fluir(espacio: 8) { derecha }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .frame(minHeight: 44)
            if divisor { Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 16) }
        }
    }
}

/// Texto a la izquierda y controles a la derecha. Si no entran juntos (ventana angosta o muchos botones), los
/// controles bajan debajo del texto en vez de taparlo o quedar cortados.
struct TextoYControles: Layout {
    var espacio: CGFloat = 16
    /// Lo mínimo que tiene que quedarle al texto para que los controles sigan al costado.
    var minimoTexto: CGFloat = 220

    private func alCostado(_ ancho: CGFloat, _ subviews: Subviews) -> (Bool, CGSize) {
        guard subviews.count > 1 else { return (true, .zero) }
        let c = subviews[1].sizeThatFits(.unspecified)
        return (c.width == 0 || ancho - c.width - espacio >= minimoTexto, c)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let texto = subviews.first else { return .zero }
        let ancho = proposal.width ?? 600
        let (costado, c) = alCostado(ancho, subviews)
        if costado {
            let anchoTexto = c.width == 0 ? ancho : ancho - c.width - espacio
            let t = texto.sizeThatFits(ProposedViewSize(width: anchoTexto, height: nil))
            return CGSize(width: ancho, height: max(t.height, c.height))
        }
        let t = texto.sizeThatFits(ProposedViewSize(width: ancho, height: nil))
        let abajo = subviews[1].sizeThatFits(ProposedViewSize(width: ancho, height: nil))
        return CGSize(width: ancho, height: t.height + 10 + abajo.height)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let texto = subviews.first else { return }
        let (costado, c) = alCostado(b.width, subviews)
        if costado {
            let anchoTexto = c.width == 0 ? b.width : b.width - c.width - espacio
            texto.place(at: CGPoint(x: b.minX, y: b.midY), anchor: .leading, proposal: ProposedViewSize(width: anchoTexto, height: nil))
            if subviews.count > 1 { subviews[1].place(at: CGPoint(x: b.maxX, y: b.midY), anchor: .trailing, proposal: .unspecified) }
        } else {
            let t = texto.sizeThatFits(ProposedViewSize(width: b.width, height: nil))
            texto.place(at: CGPoint(x: b.minX, y: b.minY), anchor: .topLeading, proposal: ProposedViewSize(width: b.width, height: nil))
            subviews[1].place(at: CGPoint(x: b.minX, y: b.minY + t.height + 10), anchor: .topLeading,
                              proposal: ProposedViewSize(width: b.width, height: nil))
        }
    }
}

/// Etiquetas o botones que siguen en la línea de abajo cuando no entran (como las palabras de un párrafo).
struct Fluir: Layout {
    var espacio: CGFloat = 6

    private func filas(_ ancho: CGFloat, _ subviews: Subviews) -> [[(Int, CGSize)]] {
        var filas: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            let t = v.sizeThatFits(.unspecified)
            if x > 0, x + t.width > ancho { filas.append([]); x = 0 }
            filas[filas.count - 1].append((i, t))
            x += t.width + espacio
        }
        return filas
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ancho = proposal.width ?? .infinity
        let f = filas(ancho, subviews)
        let alto = f.map { $0.map(\.1.height).max() ?? 0 }.reduce(0, +) + espacio * CGFloat(max(0, f.count - 1))
        let usado = f.map { $0.map(\.1.width).reduce(0, +) + espacio * CGFloat(max(0, $0.count - 1)) }.max() ?? 0
        return CGSize(width: proposal.width ?? usado, height: alto)
    }

    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = b.minY
        for fila in filas(b.width, subviews) {
            var x = b.minX
            let alto = fila.map(\.1.height).max() ?? 0
            for (i, t) in fila {
                subviews[i].place(at: CGPoint(x: x, y: y + alto / 2), anchor: .leading, proposal: ProposedViewSize(t))
                x += t.width + espacio
            }
            y += alto + espacio
        }
    }
}

struct BotonSecundario: View {
    let texto: String
    var icono: String? = nil
    var peligro = false
    let accion: () -> Void
    var body: some View {
        Button(action: accion) {
            HStack(spacing: 6) {
                if let i = icono { Image(systemName: i).font(.system(size: 12, weight: .medium)) }
                Text(texto).font(.titulo(13)).lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Tema.relleno))
            .foregroundStyle(peligro ? Tema.error : Tema.titulo)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct BotonPrimario: View {
    let texto: String
    let accion: () -> Void
    var body: some View {
        Button(action: accion) {
            Text(texto).font(.titulo(13))
                .padding(.horizontal, 14).frame(height: 32)
                .background(Capsule().fill(Tema.pildora))
                .foregroundStyle(Tema.pildoraTexto)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// Botones segmentados propios (para opciones cortas como el tamaño).
struct Segmentos<V: Hashable & Identifiable>: View {
    @Binding var valor: V
    let opciones: [V]
    let nombre: (V) -> String
    @Namespace private var espacio

    var body: some View {
        HStack(spacing: 2) {
            ForEach(opciones) { o in
                Button { withAnimation(Tema.expo) { valor = o } } label: {
                    Text(nombre(o)).font(.system(size: 12, weight: o == valor ? .semibold : .regular)).lineLimit(1).fixedSize()
                        .foregroundStyle(o == valor ? Tema.titulo : Tema.apagado)
                        .padding(.horizontal, 12).frame(height: 26)
                        .background {
                            if o == valor {
                                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Tema.tarjeta)
                                    .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "elegido", in: espacio)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Tema.relleno))
    }
}
