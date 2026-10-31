import AppKit
import SwiftUI
import RelevoNucleo

struct PaginaInicio: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var navegacion: Navegacion
    @ObservedObject var historial = Historial.shared

    var body: some View {
        if gestor.coordinadores.isEmpty {
            TituloPagina(titulo: T("Hola"), subtitulo: T("Relevo mantiene iguales un disco que queda en casa y uno que te llevás."))
            bienvenida
        } else {
            TituloPagina(titulo: titular, subtitulo: bajada)
            if let aviso = gestor.aviso {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "externaldrive.badge.checkmark").foregroundStyle(Tema.acento)
                    Text(aviso).font(.system(size: 13)).foregroundStyle(Tema.texto).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { gestor.aviso = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.help(T("Cerrar"))
                        .buttonStyle(.plain).foregroundStyle(Tema.apagado)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
            }
            ForEach(gestor.bloqueos) { b in TarjetaBloqueo(bloqueo: b, gestor: gestor) }
            ForEach(gestor.coordinadores) { c in TarjetaVinculo(coordinador: c, navegacion: navegacion, unico: gestor.coordinadores.count == 1) }
            ForEach(gestor.coordinadores) { c in TarjetaComoSeUsa(coordinador: c) }
            if !historial.conflictosAbiertos.isEmpty {
                Tarjeta {
                    Fila(titulo: T("%ld archivo(s) con dos versiones", historial.conflictosAbiertos.count),
                         detalle: T("Cambiaron distinto en los dos lados. Elegí cuál queda."), divisor: false) {
                        BotonSecundario(texto: T("Ver"), icono: "arrow.right") { navegacion.pagina = .historial }
                    }
                }
            }
            if !historial.lista.isEmpty {
                Tarjeta(titulo: T("Últimos movimientos")) {
                    // Siempre los 5 últimos (agrupados); el resto está en Historial.
                    let ultimos = Array(PaginaHistorial.agrupar(Array(historial.lista.prefix(60))).prefix(5))
                    ForEach(Array(ultimos.enumerated()), id: \.element.id) { i, g in
                        Fila(titulo: g.primero.carpeta, detalle: g.resumen.texto, divisor: i < ultimos.count - 1) {
                            Text(Formato.haceCuanto(g.primero.fecha)).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                        }
                    }
                }
                BotonSecundario(texto: T("Ver todo el historial"), icono: "clock.arrow.circlepath") { navegacion.pagina = .historial }
            }
        }
    }

    private var titular: String {
        // Recién juntados los discos: antes que cualquier otra cosa, que no abras tus apps todavía.
        guard !gestor.llegando else { return T("Esperá un momento") }
        return switch gestor.estadoVisible {
        case .copiando: T("Copiando…")
        case .revisando: T("Revisando…")
        case .necesitaOK: T("Hace falta tu OK")
        case .alReves: T("Los discos quedaron al revés")
        case .primeraVez: T("Falta la primera copia")
        case .alDia: T("Todo al día")
        case .pausado: T("En pausa")
        case .expulsando: T("Expulsando…")
        case .faltaPortatil: T("Enchufá el portátil")
        case .faltaHub: T("Trabajando desde el portátil")
        case .sinCarpetas: T("Falta elegir qué se sincroniza")
        }
    }

    private var bajada: String {
        guard !gestor.llegando else {
            return T("Estoy acomodando los discos y trayendo lo que hiciste afuera. No abras Claude ni otras apps en el disco hasta que termine: te aviso.")
        }
        return switch gestor.estadoVisible {
        case .copiando, .revisando:
            gestor.coordinadores.contains(where: \.revisandoDeFondo)
                ? T("Revisión completa diaria. Si te vas, expulsá igual: se frena sola.")
                : T("Copiando solo lo que cambió.")
        case .alDia: T("Los dos lados tienen lo mismo.") + (Ajustes.shared.datos.enVivo ? " " + T("Lo que cambies se copia solo.") : "")
        case .faltaPortatil: T("Cuando lo enchufes, sincronizo solo lo que cambió.")
        case .faltaHub: T("El disco de casa no está: cuando vuelvas y lo conectes, te traigo los cambios.")
        case .primeraVez: T("Tocá “Sincronizar ahora”: la primera vez copia todo (puede tardar); después, solo lo que cambia.")
        case .sinCarpetas: T("Elegí qué carpetas se sincronizan en “Qué se sincroniza”.")
        default: ""
        }
    }

    private var bienvenida: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 18) {
                Logo(tam: 64)
                VStack(alignment: .leading, spacing: 8) {
                    Text(T("Cómo funciona")).font(.titulo(16, .semibold)).foregroundStyle(Tema.titulo)
                    paso("1", T("Elegís el disco de casa (o la carpeta de la Mac donde trabajás) y el portátil (el disco que te llevás)."))
                    paso("2", T("Elegís qué carpetas se sincronizan. Lo que se arma solo al compilar (como .next o DerivedData) no se copia."))
                    paso("3", T("Listo: mientras están los dos conectados, cada cambio pasa solo. Con “Me voy” copia lo último y expulsa los discos; al volver, trae lo que cambiaste afuera."))
                }
            }
            Text(T("Nada se borra del todo: lo borrado y lo reemplazado va a una papelera de Relevo en cada disco."))
                .font(.system(size: 12)).foregroundStyle(Tema.apagado)
            BotonPrimario(texto: T("Empezar")) { navegacion.asistente = true }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
    }

    private func paso(_ n: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.system(size: 12, weight: .bold)).foregroundStyle(Tema.pildoraTexto)
                .frame(width: 20, height: 20).background(Circle().fill(Tema.acento))
            Text(texto).font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Un vínculo en el inicio: los dos lados, el estado y los botones.
struct TarjetaVinculo: View {
    @ObservedObject var coordinador: Coordinador
    @ObservedObject var navegacion: Navegacion
    /// Es el único vínculo (el título de la página ya dice su estado).
    var unico = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let aviso = coordinador.aviso {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: coordinador.listoParaIrse ? "checkmark.circle.fill" : "info.circle.fill")
                        .foregroundStyle(coordinador.listoParaIrse ? Tema.exito : Tema.acento)
                    Text(aviso).font(.system(size: 13)).foregroundStyle(Tema.texto).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { coordinador.aviso = nil } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }.help(T("Cerrar"))
                        .buttonStyle(.plain).foregroundStyle(Tema.apagado)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
            }
            discos
            if coordinador.estado == .alReves { alReves }
            if coordinador.clavesSinCifrar > 0 {
                Aviso(icono: "key.fill", color: Tema.acento,
                      texto: T("Estás llevando claves (.env) de %ld proyecto(s) en un portátil sin cifrar. Si lo perdés, cualquiera las puede leer.", coordinador.clavesSinCifrar)) {
                    HStack(spacing: 10) {
                        BotonPrimario(texto: T("Cifrar el portátil…")) { navegacion.vinculo = coordinador.id; navegacion.pagina = .discos }
                        BotonSecundario(texto: T("No volver a avisar")) { coordinador.noAvisarClaves() }
                    }
                }
            }
            if !coordinador.faltanDependencias.isEmpty {
                Aviso(icono: "shippingbox.fill", color: Tema.acento,
                      texto: T("A %ld proyecto(s) les faltan las dependencias en este disco: %@. Instalalas con el comando de cada uno.",
                               coordinador.faltanDependencias.count,
                               coordinador.faltanDependencias.prefix(4).map { ($0.proyecto as NSString).lastPathComponent }.joined(separator: ", "))) {
                    BotonSecundario(texto: T("Copiar los comandos"), icono: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(coordinador.faltanDependencias.map(\.comando).joined(separator: "\n"), forType: .string)
                    }
                }
            }
            // Uno solo: su tarjeta. Varios: una sola tarjeta con la lista (y "una por una" si querés decidir cada uno).
            if coordinador.pedidos.count == 1, let pedido = coordinador.pedidos.first {
                tarjetaPedido(pedido)
            } else if coordinador.pedidos.count > 1 {
                PedidosJuntos(coordinador: coordinador)
            }
        }
    }

    private var discos: some View {
        let v = coordinador.vinculo
        return VStack(spacing: 18) {
            HStack(spacing: 0) {
                DiscoAbrible(habilitado: coordinador.raizHub != nil, abrir: {
                    if let r = coordinador.raizHub { NSWorkspace.shared.open(URL(fileURLWithPath: r)) }
                }) {
                    disco(titulo: T("Disco de casa"), sub: T("Donde trabajás"), conectado: coordinador.raizHub != nil, lugar: v?.hub, libre: coordinador.hub?.libre)
                }
                flechas
                DiscoAbrible(habilitado: coordinador.portatil != nil, abrir: { coordinador.mostrarPortatil() }) {
                    disco(titulo: T("Portátil"), sub: T("Va con vos"), conectado: coordinador.portatil != nil, lugar: v?.portatil, libre: coordinador.portatil?.libre)
                }
            }
            if !linea.isEmpty { Text(linea).font(.system(size: 12)).foregroundStyle(Tema.apagado) }
            // El lugar del progreso queda siempre reservado: cuando aparece, nada se corre.
            let ocupado = coordinador.estadoVisible == .copiando || coordinador.estadoVisible == .revisando
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: coordinador.estadoVisible == .revisando ? nil : coordinador.avance.fraccion)
                    .progressViewStyle(.linear).tint(Tema.acento)
                let a = coordinador.avance
                Text(a.bytesTotal > 0 ? T("%@: %@ de %@", a.carpeta, Formato.bytes(a.bytesHechos), Formato.bytes(a.bytesTotal)) : a.carpeta)
                    .font(.system(size: 11)).foregroundStyle(Tema.apagado).lineLimit(1)
            }
            .frame(height: 30)
            .opacity(ocupado ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: ocupado)
            // Los botones de la izquierda y "Me voy" a la derecha; si no entran (ventana angosta), siguen abajo.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { botonesIzquierda(ocupado); Spacer(minLength: 10); botonesDerecha }
                Fluir(espacio: 10) { botonesIzquierda(ocupado); botonesDerecha }
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .shadow(color: .black.opacity(0.02), radius: 4, y: 2)
    }

    @ViewBuilder private func botonesIzquierda(_ ocupado: Bool) -> some View {
        if ocupado {
            // Mientras copia, el botón avisa y no se puede volver a tocar.
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
                Text(T("Sincronizando…")).font(.titulo(13)).lineLimit(1)
            }
            .fixedSize()
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Tema.relleno))
            .foregroundStyle(Tema.apagado)
        } else {
            BotonSecundario(texto: T("Sincronizar ahora"), icono: "arrow.triangle.2.circlepath") { coordinador.sincronizarInteligente(aMano: true) }
                .disabled(!puedeSincronizar).opacity(puedeSincronizar ? 1 : 0.45)
        }
        if coordinador.estado == .sinCarpetas {
            BotonSecundario(texto: T("Elegir qué se sincroniza"), icono: "folder") {
                navegacion.vinculo = coordinador.id
                navegacion.pagina = .carpetas
            }
        }
        if coordinador.estado == .pausado {
            BotonSecundario(texto: T("Reanudar"), icono: "play.fill") { coordinador.pausar(hasta: nil) }
        }
    }

    @ViewBuilder private var botonesDerecha: some View {
        if coordinador.estadoVisible == .copiando || coordinador.estadoVisible == .revisando {
            BotonSecundario(texto: T("Frenar"), icono: "pause.fill") { coordinador.cancelar() }
        }
        if !(coordinador.portatil?.esEstaMac ?? false) {
            BotonPrimario(texto: T("Me voy")) { Gestor.actual?.meVoy() }
                .disabled(coordinador.portatil == nil).opacity(coordinador.portatil == nil ? 0.45 : 1)
                .help(T("Copia lo último y expulsa todos los discos (el portátil, el disco de casa, Time Machine…) para que te vayas tranquilo."))
        }
    }

    /// Debajo de los discos: con un solo vínculo, el título de arriba ya dice el estado; acá va solo el dato que suma.
    private var linea: String {
        guard !unico else {
            switch coordinador.estadoVisible {
            case .alDia: return coordinador.ultima.map { T("Última copia: %@", Formato.haceCuanto($0)) } ?? ""
            case .copiando, .pausado, .faltaPortatil: return Delegado.lineaEstado(coordinador)
            default: return ""
            }
        }
        return Delegado.lineaEstado(coordinador)
    }

    private var puedeSincronizar: Bool {
        coordinador.conectados && !(coordinador.vinculo?.carpetas.isEmpty ?? true) && coordinador.estado != .copiando
    }

    private func disco(titulo: String, sub: String, conectado: Bool, lugar: Lugar?, libre: Int64?) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: lugar?.esEstaMac == true ? "laptopcomputer" : "externaldrive.fill")
                    .font(.system(size: 34, weight: .regular))
                    .foregroundStyle(conectado ? Tema.titulo : Tema.apagado.opacity(0.5))
                    .frame(width: 64, height: 52)
                Circle().fill(conectado ? Tema.exito : Tema.apagado.opacity(0.5)).frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Tema.tarjeta, lineWidth: 2))
            }
            Text(titulo).font(.titulo(14, .semibold)).foregroundStyle(Tema.titulo)
            Text((lugar?.descripcion ?? T("Sin elegir")) + (conectado ? (libre.map { " · " + T("%@ libres", Formato.bytes($0)) } ?? "") : " · " + T("no conectado")))
                .font(.system(size: 11)).foregroundStyle(Tema.apagado).lineLimit(1)
            Text(sub).font(.system(size: 11)).foregroundStyle(Tema.apagado.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
    }

    private var flechas: some View {
        let activo = coordinador.estadoVisible == .copiando || coordinador.estadoVisible == .revisando
        let unidos = coordinador.conectados
        return Image(systemName: "arrow.left.arrow.right")
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(activo ? Tema.acento : (unidos ? Tema.exito : Tema.apagado.opacity(0.4)))
            .symbolEffect(.pulse, isActive: activo)
            .frame(width: 60)
    }

    private func tarjetaPedido(_ p: PedidoOK) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tema.acento)
                Text(p.carpeta).font(.titulo(14, .semibold)).foregroundStyle(Tema.titulo)
            }
            Text(p.explicacion).font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                if p.sePuedeSeguir { BotonPrimario(texto: T("Sí, seguir")) { coordinador.confirmar(p) } }
                BotonSecundario(texto: T("Ahora no")) { coordinador.ahoraNo(p) }
            }
            if let cuando = coordinador.aplicaSolo(p) {
                Text(T("Si no respondés, se aplica solo el %@ (lo borrado queda en la papelera de Relevo).", Formato.hora(cuando)))
                    .font(.system(size: 11)).foregroundStyle(Tema.apagado)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .overlay(RoundedRectangle(cornerRadius: Tema.radioTarjeta).strokeBorder(Tema.acento.opacity(0.35)))
    }

    private var alReves: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(T("El portátil se montó primero y se quedó con el nombre del disco de casa, así que lo que abras iría al disco equivocado. Mientras tanto no sincronizo. “Acomodar” les cambia el nombre (no desmonta nada ni hace falta cerrar nada)."))
                .font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            BotonPrimario(texto: T("Acomodar")) { coordinador.acomodar() }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .overlay(RoundedRectangle(cornerRadius: Tema.radioTarjeta).strokeBorder(Tema.error.opacity(0.4)))
    }
}

/// Un disco que se abre en el Finder al tocarlo: al pasar el cursor se resalta, aparece "Abrir" y la manito.
struct DiscoAbrible<C: View>: View {
    let habilitado: Bool
    let abrir: () -> Void
    @ViewBuilder var contenido: C
    @Estado private var encima = false

    var body: some View {
        Button(action: abrir) {
            contenido
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(encima && habilitado ? Tema.rellenoSuave : Color.clear))
                .overlay(alignment: .topTrailing) {
                    Label(T("Abrir"), systemImage: "arrow.up.forward.app")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Tema.acento)
                        .padding(8)
                        .opacity(encima && habilitado ? 1 : 0)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!habilitado)
        .help(habilitado ? T("Abrir en el Finder") : "")
        .onHover { dentro in
            withAnimation(.easeOut(duration: 0.12)) { encima = dentro }
            if habilitado { if dentro { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
        }
        .onDisappear { if encima && habilitado { NSCursor.pop() } }
    }
}

/// Varios pedidos de OK juntos (por ejemplo, borraste varios proyectos del hub): una sola tarjeta compacta con la lista,
/// "Sí, seguir con todas" y, si querés, revisarlos uno por uno. Lo usa `TarjetaVinculo`.
struct PedidosJuntos: View {
    @ObservedObject var coordinador: Coordinador
    @Estado private var verLista = false
    @Estado private var unaPorUna = false

    var body: some View {
        let pedidos = coordinador.pedidos
        let lado = pedidos.allSatisfy { $0.faltaDe != nil && $0.faltaDe == pedidos.first?.faltaDe } ? pedidos.first?.faltaDe : nil
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Tema.acento)
                Text(T("%ld carpetas esperan tu OK", pedidos.count)).font(.titulo(14, .semibold)).foregroundStyle(Tema.titulo)
            }
            Text(lado.map { l in
                T("Ya no están en el %@ (las borraste o las moviste). Si seguís, también se sacan del %@: van a la papelera de Relevo de ese disco y quedan %ld días por si te arrepentís.",
                  T(l.nombre), T(l.otro.nombre), Ajustes.shared.datos.diasPapelera)
            } ?? T("Son cambios grandes que Relevo no hace sin preguntarte. Lo que se borre va a la papelera de Relevo y queda ahí un tiempo."))
                .font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            if unaPorUna {
                VStack(spacing: 0) {
                    ForEach(Array(pedidos.enumerated()), id: \.element.id) { i, p in
                        Fila(titulo: p.carpeta, detalle: lado == nil ? p.explicacion : nil, divisor: i < pedidos.count - 1) {
                            if p.sePuedeSeguir { BotonSecundario(texto: T("Seguir")) { coordinador.confirmar(p) } }
                            BotonSecundario(texto: T("Ahora no")) { coordinador.ahoraNo(p) }
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10).fill(Tema.rellenoSuave))
            } else {
                let visibles = verLista ? pedidos : Array(pedidos.prefix(5))
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(visibles) { p in
                        Text("· " + p.carpeta).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tema.texto).lineLimit(1)
                    }
                    if pedidos.count > visibles.count {
                        Button { withAnimation(Tema.expo) { verLista = true } } label: {
                            Text(T("Y %ld más…", pedidos.count - visibles.count)).font(.system(size: 12)).foregroundStyle(Tema.subtitulo)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Fluir(espacio: 10) {
                BotonPrimario(texto: T("Sí, seguir con todas")) { coordinador.confirmarTodos() }
                BotonSecundario(texto: unaPorUna ? T("Ver la lista") : T("Revisar una por una")) { withAnimation(Tema.expo) { unaPorUna.toggle() } }
                BotonSecundario(texto: T("Ahora no")) { coordinador.ahoraNoTodos() }
            }
            let cuando = pedidos.compactMap { coordinador.aplicaSolo($0) }.min()
            Text(cuando.map { T("“Ahora no” no toca nada. Si no respondés, se aplican solos el %@ (lo borrado queda en la papelera de Relevo).", Formato.hora($0)) }
                 ?? T("“Ahora no” no toca nada: te lo vuelvo a preguntar en la próxima sincronización."))
                .font(.system(size: 11)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .overlay(RoundedRectangle(cornerRadius: Tema.radioTarjeta).strokeBorder(Tema.acento.opacity(0.35)))
    }
}

/// Un disco que no se pudo expulsar: quién lo usa (por app y proyecto) y "Cerrar y expulsar", que pregunta antes.
struct TarjetaBloqueo: View {
    let bloqueo: Bloqueo
    @ObservedObject var gestor: Gestor
    @Estado private var confirmar = false

    var body: some View {
        let cerrables = bloqueo.uso.cerrables
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "eject.fill").foregroundStyle(Tema.acento)
                Text(T("No pude expulsar %@", bloqueo.nombre)).font(.titulo(14, .semibold)).foregroundStyle(Tema.titulo)
            }
            Text(bloqueo.uso.vacio ? T("macOS no dijo qué lo está usando. Probá de nuevo en unos segundos.")
                                   : T("Lo están usando:"))
                .font(.system(size: 13)).foregroundStyle(Tema.subtitulo)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(bloqueo.uso.grupos) { g in
                    let donde = g.carpetas.sorted().prefix(4).joined(separator: ", ")
                    HStack(alignment: .top, spacing: 6) {
                        Text("·").foregroundStyle(Tema.apagado)
                        Text(g.app).font(.system(size: 13, weight: .medium)).foregroundStyle(Tema.titulo)
                        Text((donde.isEmpty ? "" : T("en %@", donde)) + (g.cerrable ? "" : " " + T("(cerralo vos)")))
                            .font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if bloqueo.uso.grupos.contains(where: { $0.app == "Claude" }) {
                Text(T("Son sesiones de Claude abiertas en ese disco. Si las cerrás, después las volvés a abrir desde la app."))
                    .font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
            }
            Fluir(espacio: 10) {
                if !cerrables.isEmpty { BotonPrimario(texto: T("Cerrar y expulsar")) { confirmar = true } }
                BotonSecundario(texto: T("Probar de nuevo")) { gestor.cerrarYExpulsar(Bloqueo(uuid: bloqueo.uuid, nombre: bloqueo.nombre, uso: UsoDeDisco(), nombreAfuera: bloqueo.nombreAfuera)) }
                BotonSecundario(texto: T("Ahora no")) { gestor.bloqueos.removeAll { $0.uuid == bloqueo.uuid } }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .overlay(RoundedRectangle(cornerRadius: Tema.radioTarjeta).strokeBorder(Tema.acento.opacity(0.35)))
        .alert(T("¿Cerrar y expulsar?"), isPresented: $confirmar) {
            Button(T("Cerrar y expulsar"), role: .destructive) { gestor.cerrarYExpulsar(bloqueo) }
            Button(T("Cancelar"), role: .cancel) {}
        } message: {
            Text(T("Se van a cerrar: %@. Lo que estén haciendo se corta; lo que ya guardaron queda guardado.",
                   cerrables.map(\.app).joined(separator: ", ")))
        }
    }
}

/// Después de la primera copia de un vínculo nuevo: cómo se usa en el día a día, una sola vez (con "Entendido" no
/// vuelve). Solo para vínculos creados hace menos de una semana: a quien ya lo usa no se le aparece de golpe.
struct TarjetaComoSeUsa: View {
    @ObservedObject var coordinador: Coordinador
    @Estado private var vista = false

    private var clave: String { "guia-uso-\(coordinador.id)" }
    private var mostrar: Bool {
        guard !vista, coordinador.ultima != nil, !UserDefaults.standard.bool(forKey: clave),
              let alta = UserDefaults.standard.object(forKey: "alta-\(coordinador.id)") as? Date else { return false }
        return Date().timeIntervalSince(alta) < 7 * 86400
    }

    var body: some View {
        if mostrar {
            Tarjeta {
                VStack(alignment: .leading, spacing: 12) {
                    Text(T("Listo, ya está todo copiado. Así se usa:")).font(.titulo(15, .semibold)).foregroundStyle(Tema.titulo)
                    renglon("arrow.left.arrow.right", T("Con los dos discos enchufados no hacés nada: cada cambio pasa solo."))
                    renglon("figure.walk", T("Cuando te vas, tocá “Me voy” (en el menú de Relevo o acá): copia lo último y expulsa los discos."))
                    renglon("house", T("Cuando volvés, enchufá el portátil y esperá el aviso “Listo” antes de abrir tus apps."))
                    BotonSecundario(texto: T("Entendido"), icono: "checkmark") {
                        UserDefaults.standard.set(true, forKey: clave)
                        withAnimation(Tema.expo) { vista = true }
                    }
                }
                .padding(18)
            }
            .transition(.opacity)
        }
    }

    private func renglon(_ icono: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icono).font(.system(size: 14)).foregroundStyle(Tema.acento).frame(width: 20)
            Text(texto).font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
        }
    }
}
