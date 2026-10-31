import SwiftUI

struct OpcionDias: Identifiable, Hashable {
    let dias: Int
    var id: Int { dias }
}

struct PaginaGeneral: View {
    static func nombre(_ a: Atajos.Accion) -> String {
        switch a {
        case .sincronizar: "sincronizar"
        case .meVoy: "me voy"
        case .expulsar: "expulsar discos"
        }
    }

    @ObservedObject var gestor: Gestor
    @ObservedObject var ajustes: Ajustes
    @Estado private var alInicio = InicioSesion.activo
    /// Cuánto ocupa la papelera de Relevo en los discos conectados (nil = midiendo; puede tardar con muchos archivos).
    @Estado private var tamanoPapelera: Int64?
    @Estado private var vaciando = false
    @Estado private var confirmarVaciar = false

    var body: some View {
        TituloPagina(titulo: T("General"), subtitulo: T("Opciones para todos los discos."))

        Tarjeta(titulo: T("Automático")) {
            Fila(titulo: T("Sincronizar sola al enchufar"), detalle: T("Apenas conectás el portátil, trae y lleva lo que cambió.")) {
                Toggle("", isOn: $ajustes.datos.automatico).toggleStyle(.switch).labelsHidden()
            }
            Fila(titulo: T("Copia en vivo"), detalle: T("Con los dos conectados, cada cambio se copia a los pocos segundos. Así “Me voy” es instantáneo.")) {
                Toggle("", isOn: $ajustes.datos.enVivo).toggleStyle(.switch).labelsHidden()
            }
            Fila(titulo: T("Abrir al iniciar sesión"), detalle: T("Relevo vive en la barra de menú y gasta muy poco."), divisor: false) {
                Toggle("", isOn: $alInicio).toggleStyle(.switch).labelsHidden()
                    .onChange(of: alInicio) { _, v in InicioSesion.cambiar(v) }
            }
        }

        Tarjeta(titulo: T("Cuidados")) {
            Fila(titulo: T("Revisión completa diaria"),
                 detalle: T("Normalmente Relevo revisa solo lo que cambió (macOS lleva la cuenta, aunque Relevo esté cerrado). Una vez por día, de madrugada o cuando no usás la Mac, revisa todo por las dudas. Si te vas mientras corre, se frena sola.")) {
                BotonSecundario(texto: T("Revisar todo ahora")) { gestor.coordinadores.forEach { $0.sincronizar(aMano: true) } }
                    .disabled(!gestor.coordinadores.contains(where: \.conectados))
                    .opacity(gestor.coordinadores.contains(where: \.conectados) ? 1 : 0.45)
                Toggle("", isOn: $ajustes.datos.revisionDiaria).toggleStyle(.switch).labelsHidden()
            }
            Fila(titulo: T("Revisión a fondo una vez por mes"),
                 detalle: T("Con la Mac enchufada, los dos discos conectados y sin usarla un rato, compara el contenido de todo para encontrar copias dañadas. Solo avisa si encuentra algo.")) {
                Toggle("", isOn: $ajustes.datos.revisionMensual).toggleStyle(.switch).labelsHidden()
            }
            Fila(titulo: T("Antes de que la Mac se duerma"),
                 detalle: T("Al cerrar la tapa, Relevo copia lo que tenga pendiente antes de dormirse. No expulsa los discos."), divisor: false) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Tema.exito)
            }
        }

        Tarjeta(titulo: T("Atajos")) {
            Fila(titulo: T("Atajos de teclado"),
                 detalle: Atajos.descripcion.map { "\($0.1) " + T(Self.nombre($0.0)) }.joined(separator: " · ")) {
                Toggle("", isOn: $ajustes.datos.atajos).toggleStyle(.switch).labelsHidden()
            }
            Fila(titulo: T("Enlaces para otras apps"),
                 detalle: T("Para Atajos de macOS, Raycast o Alfred: relevo://sincronizar, relevo://mevoy, relevo://expulsar, relevo://pausar?horas=1 y relevo://reanudar."), divisor: false) { EmptyView() }
        }

        Tarjeta(titulo: T("Papelera de Relevo")) {
            Fila(titulo: T("Cuánto tiempo guardar lo que se borra o se reemplaza"),
                 detalle: T("Cuando borrás algo en un disco, en el otro no se borra del todo: va a una papelera escondida de ese disco. Cuando un archivo se reemplaza por uno más nuevo, la versión vieja también. Desde el Historial lo podés recuperar. Pasado este tiempo, se borra solo.")) {
                Segmentos(valor: Binding(get: { OpcionDias(dias: ajustes.datos.diasPapelera) }, set: { ajustes.datos.diasPapelera = $0.dias }),
                          opciones: [3, 7, 30, 90].map(OpcionDias.init), nombre: { T("%ld días", $0.dias) })
            }
            Fila(titulo: T("Vaciar ahora"), detalle: detallePapelera, divisor: false) {
                if vaciando {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 14, height: 14)
                        Text(T("Vaciando…")).font(.titulo(13)).lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 12).frame(height: 32)
                    .background(Capsule().fill(Tema.relleno))
                    .foregroundStyle(Tema.apagado)
                } else {
                    let hayAlgo = (tamanoPapelera ?? 0) > 0
                    BotonSecundario(texto: T("Vaciar ahora"), icono: "trash", peligro: true) { confirmarVaciar = true }
                        .disabled(!hayAlgo).opacity(hayAlgo ? 1 : 0.45)
                }
            }
        }
        .onAppear { medirPapelera() }
        .onChange(of: raicesPapelera) { _, _ in medirPapelera() }   // se enchufó o se fue un disco
        .alert(T("¿Vaciar la papelera de Relevo?"), isPresented: $confirmarVaciar) {
            Button(T("Vaciar"), role: .destructive) { vaciarPapelera() }
            Button(T("Cancelar"), role: .cancel) {}
        } message: {
            Text(T("Se borran para siempre las versiones viejas y lo borrado que guardaba Relevo (%@): después no se pueden recuperar desde el Historial. Tus archivos de los dos discos no se tocan.",
                   Formato.bytes(tamanoPapelera ?? 0)))
        }

        Tarjeta(titulo: T("Apariencia")) {
            Fila(titulo: T("Tema")) {
                Segmentos(valor: $ajustes.datos.apariencia, opciones: Apariencia.allCases, nombre: \.nombre)
            }
            Fila(titulo: T("Idioma"), detalle: T("Automático usa el idioma de la Mac."), divisor: false) {
                Segmentos(valor: $ajustes.datos.idioma, opciones: Idioma.allCases, nombre: \.nombre)
            }
        }
    }

    private var raicesPapelera: [String] { gestor.coordinadores.flatMap(\.raicesConPapelera) }

    private var detallePapelera: String {
        if raicesPapelera.isEmpty { return T("Conectá un disco para vaciar su papelera.") }
        guard let t = tamanoPapelera else { return T("Midiendo cuánto ocupa…") }
        if t == 0 { return T("Está vacía.") }
        return T("Ahora ocupa %@. Se borra para siempre lo que Relevo guardaba ahí; tus archivos no se tocan.", Formato.bytes(t))
    }

    /// Mide la papelera de los discos conectados fuera del hilo principal (con muchos archivos tarda unos segundos).
    private func medirPapelera() {
        let raices = raicesPapelera
        tamanoPapelera = nil
        DispatchQueue.global(qos: .utility).async {
            let total = raices.reduce(Int64(0)) { $0 + Papelera.tamano($1) }
            DispatchQueue.main.async { tamanoPapelera = total }
        }
    }

    /// Lo llama el "Vaciar" de la confirmación: cada vínculo vacía la suya en su cola (ver `Coordinador.vaciarPapeleras`).
    private func vaciarPapelera() {
        vaciando = true
        let grupo = DispatchGroup()
        for c in gestor.coordinadores {
            grupo.enter()
            c.vaciarPapeleras { grupo.leave() }
        }
        grupo.notify(queue: .main) {
            vaciando = false
            medirPapelera()
        }
    }
}
