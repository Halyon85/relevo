import AppKit
import SwiftUI
import RelevoNucleo

struct PaginaHistorial: View {
    @ObservedObject var historial: Historial
    @ObservedObject var gestor: Gestor
    @Estado private var vista: VistaHistorial = .movimientos
    @Estado private var abierto: UUID?
    @Estado private var filtro = ""

    enum VistaHistorial: String, CaseIterable, Identifiable {
        case movimientos, conflictos
        var id: String { rawValue }
        var nombre: String { self == .movimientos ? T("Movimientos") : T("Dos versiones") }
    }

    private var pestanas: some View {
        Segmentos(valor: $vista, opciones: VistaHistorial.allCases, nombre: { v in
            v == .conflictos && !historial.conflictosAbiertos.isEmpty ? "\(v.nombre) (\(historial.conflictosAbiertos.count))" : v.nombre
        })
        .fixedSize()
    }

    @ViewBuilder private var buscador: some View {
        if vista == .movimientos {
            TextField(T("Buscar archivo o carpeta"), text: $filtro)
                .textFieldStyle(.plain).font(.system(size: 13))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8).fill(Tema.rellenoSuave))
        }
    }

    var body: some View {
        TituloPagina(titulo: T("Historial"), subtitulo: T("Qué se copió, para dónde y cuándo. Nada se borra del todo: podés volver atrás."))
        ViewThatFits(in: .horizontal) {
            HStack { pestanas; Spacer(); buscador.frame(width: 220) }
            VStack(alignment: .leading, spacing: 8) { pestanas; buscador }
        }
        if vista == .movimientos { movimientos } else { conflictos }
    }

    // MARK: Movimientos

    /// Varias pasadas seguidas de la misma carpeta (la copia en vivo mientras trabajás) se muestran juntas.
    struct Grupo: Identifiable {
        var movimientos: [Movimiento]
        var id: UUID { movimientos[0].id }
        var primero: Movimiento { movimientos[0] }
        var resumen: Movimiento {
            var r = primero
            for m in movimientos.dropFirst() {
                r.haciaPortatil += m.haciaPortatil; r.haciaHub += m.haciaHub; r.aPapelera += m.aPapelera
                r.bytes += m.bytes; r.conflictos += m.conflictos; r.problemas += m.problemas
                if r.desconectado == nil { r.desconectado = m.desconectado }
            }
            return r
        }
    }

    private var lista: [Grupo] {
        let f = filtro.trimmingCharacters(in: .whitespaces).lowercased()
        let fuente = f.isEmpty ? Array(historial.lista.prefix(300)) : historial.lista.filter { m in
            m.carpeta.lowercased().contains(f) || (m.cambios ?? []).contains { $0.ruta.lowercased().contains(f) }
        }
        return Array(Self.agrupar(fuente).prefix(100))
    }

    static func agrupar(_ fuente: [Movimiento]) -> [Grupo] {
        var grupos: [Grupo] = []
        for m in fuente {
            if let g = grupos.last, g.primero.carpeta == m.carpeta, g.primero.vinculo == m.vinculo,
               g.movimientos.last!.fecha.timeIntervalSince(m.fecha) < 20 * 60 {
                grupos[grupos.count - 1].movimientos.append(m)
            } else {
                grupos.append(Grupo(movimientos: [m]))
            }
        }
        return grupos
    }

    @ViewBuilder private var movimientos: some View {
        if historial.lista.isEmpty {
            Tarjeta { Fila(titulo: T("Todavía no hubo movimientos"), divisor: false) { EmptyView() } }
        } else {
            Tarjeta {
                let grupos = lista
                ForEach(Array(grupos.enumerated()), id: \.element.id) { i, g in
                    filaGrupo(g)
                    if i < grupos.count - 1 { Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 16) }
                }
            }
            HStack {
                BotonSecundario(texto: T("Papeleras de Relevo"), icono: "trash") { abrirPapeleras() }
                Spacer()
                BotonSecundario(texto: T("Borrar historial"), icono: "xmark", peligro: true) { historial.borrarTodo() }
            }
        }
    }

    private func filaGrupo(_ g: Grupo) -> some View {
        let m = g.resumen
        return VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(Tema.expo) { abierto = abierto == g.id ? nil : g.id } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Tema.apagado)
                        .rotationEffect(.degrees(abierto == g.id ? 90 : 0))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.carpeta).font(.titulo(14)).foregroundStyle(Tema.titulo)
                        Text(m.texto + (m.bytes > 0 ? " · \(Formato.bytes(m.bytes))" : "") + (g.movimientos.count > 1 ? " · " + T("%ld pasadas en vivo", g.movimientos.count) : ""))
                            .font(.system(size: 12)).foregroundStyle(Tema.subtitulo)
                    }
                    Spacer()
                    if !m.problemas.isEmpty { Image(systemName: "exclamationmark.circle").foregroundStyle(Tema.error) }
                    if m.desconectado != nil { Image(systemName: "bolt.horizontal").foregroundStyle(Tema.acento) }
                    Text(Formato.haceCuanto(m.fecha)).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if abierto == g.id { ForEach(g.movimientos) { detalle($0) } }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    @ViewBuilder private func detalle(_ m: Movimiento) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(m.problemas.prefix(10), id: \.self) { p in
                Label(p, systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(Tema.error)
            }
            if let d = m.desconectado {
                Label(T("Se desconectó el %@ a mitad (se retomó después)", T(d)), systemImage: "bolt.horizontal").font(.system(size: 12)).foregroundStyle(Tema.acento)
            }
            let cambios = m.cambios ?? []
            ForEach(Array(cambios.prefix(200).enumerated()), id: \.offset) { _, c in filaCambio(m, c) }
            if let total = m.cambiosTotales, total > min(200, cambios.count) {
                Text(T("…y %@ más", Formato.numero(total - min(200, cambios.count)))).font(.system(size: 12)).foregroundStyle(Tema.apagado)
            }
            if cambios.isEmpty && m.problemas.isEmpty {
                Text(T("Sin detalle archivo por archivo (de una versión anterior de Relevo).")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
            }
        }
        .padding(.leading, 18)
    }

    private func filaCambio(_ m: Movimiento, _ c: Cambio) -> some View {
        let (icono, texto) = Self.describir(c)
        let raiz = raizDe(m, c.lado)
        let restaurable = (c.tipo == .reemplazado || c.tipo == .aPapelera)
            && Restaurar.disponible(raiz: raiz, sello: m.sello, carpeta: m.carpeta, ruta: c.ruta)
        return HStack(spacing: 6) {
            Image(systemName: icono).font(.system(size: 11)).foregroundStyle(Tema.apagado).frame(width: 16)
            Text(c.ruta).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tema.texto).lineLimit(1).truncationMode(.middle)
            Text(texto).font(.system(size: 11)).foregroundStyle(Tema.apagado)
            Spacer()
            if restaurable, let raiz, let sello = m.sello {
                Button(c.tipo == .reemplazado ? T("Volver a la anterior") : T("Recuperar")) {
                    if Restaurar.traer(raiz: raiz, sello: sello, carpeta: m.carpeta, ruta: c.ruta) {
                        gestor.coordinador(m.vinculo ?? "")?.sincronizar([m.carpeta], aMano: true)
                    }
                }
                .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Tema.acento)
            }
        }
    }

    static func describir(_ c: Cambio) -> (String, String) {
        let hacia = c.lado == .portatil ? T("→ portátil") : T("→ casa")
        switch c.tipo {
        case .copiado: return ("plus.circle", T("nuevo %@", hacia))
        case .reemplazado: return ("arrow.triangle.2.circlepath", T("actualizado %@", hacia))
        case .aPapelera: return ("trash", T("a la papelera del %@", T(c.lado.nombre)))
        case .carpeta: return ("folder", T("carpeta %@", hacia))
        case .conflicto: return ("doc.on.doc", T("dos versiones"))
        }
    }

    private func raizDe(_ m: Movimiento, _ lado: Lado) -> String? {
        guard let c = gestor.coordinador(m.vinculo ?? "") ?? (gestor.coordinadores.count == 1 ? gestor.coordinadores.first : nil) else { return nil }
        return lado == .hub ? c.raizHub : c.raizPortatil
    }

    private func abrirPapeleras() {
        for c in gestor.coordinadores {
            for r in [c.raizHub, c.raizPortatil].compactMap({ $0 }) { Discos.mostrar(Sincronizador.papelera(r), desde: r) }
        }
    }

    // MARK: Conflictos

    @ViewBuilder private var conflictos: some View {
        let abiertos = historial.conflictosAbiertos
        if abiertos.isEmpty {
            Tarjeta {
                Fila(titulo: T("No hay archivos con dos versiones"),
                     detalle: T("Si cambiás el mismo archivo distinto en los dos lados, Relevo guarda las dos y te pregunta acá cuál queda."), divisor: false) { EmptyView() }
            }
        } else {
            ForEach(Array(abiertos.enumerated()), id: \.offset) { _, par in tarjetaConflicto(par.0, par.1) }
        }
    }

    private func tarjetaConflicto(_ m: Movimiento, _ ruta: String) -> some View {
        let cambio = (m.cambios ?? []).first { $0.tipo == .conflicto && $0.ruta == ruta }
        let raizHub = raizDe(m, .hub)
        let ganador = cambio.map { T($0.lado.nombre) } ?? T("más nuevo")
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.on.doc.fill").foregroundStyle(Tema.acento)
                Text("\(m.carpeta)/\(ruta)").font(.titulo(14, .semibold)).foregroundStyle(Tema.titulo).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Formato.haceCuanto(m.fecha)).font(.system(size: 12)).foregroundStyle(Tema.apagado)
            }
            Text(T("Cambió distinto en los dos lados. Quedó con su nombre la versión del %@ (la más nueva); la otra está al lado como “%@”.", ganador, cambio?.otraVersion.map { ($0 as NSString).lastPathComponent } ?? T("… (otra versión)")))
                .font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            if let raizHub, let otra = cambio?.otraVersion {
                Fluir(espacio: 10) {
                    BotonSecundario(texto: T("Ver las dos"), icono: "eye") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: raizHub + "/" + m.carpeta + "/" + ruta),
                                                                        URL(fileURLWithPath: raizHub + "/" + m.carpeta + "/" + otra)])
                    }
                    BotonPrimario(texto: T("Quedarme con la del %@", ganador)) { resolver(m, ruta, raizHub, otra, laOtra: false) }
                    BotonSecundario(texto: T("Usar la otra")) { resolver(m, ruta, raizHub, otra, laOtra: true) }
                }
            } else {
                HStack {
                    Text(raizHub == nil ? T("Conectá el disco de casa para elegir.") : T("Las dos versiones están en la carpeta.")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                    Spacer()
                    BotonSecundario(texto: T("Ya lo resolví")) { historial.marcarResuelto(m.id, ruta) }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
    }

    private func resolver(_ m: Movimiento, _ ruta: String, _ raizHub: String, _ otra: String, laOtra: Bool) {
        if Restaurar.resolverConflicto(raizHub: raizHub, carpeta: m.carpeta, ruta: ruta, otraVersion: otra, quedarseConLaOtra: laOtra) {
            historial.marcarResuelto(m.id, ruta)
            gestor.coordinador(m.vinculo ?? "")?.sincronizar([m.carpeta], aMano: true)
        }
    }
}
