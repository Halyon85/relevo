import AppKit
import Combine
import Foundation
import RelevoNucleo

/// Una carpeta que necesita tu OK antes de seguir (muchos borrados, falta la carpeta, no entra).
struct PedidoOK: Identifiable {
    let carpeta: String
    let alertas: [Alerta]
    /// Archivos que esa carpeta tiene para copiar (de cualquier lado) y que esperan junto con el OK.
    var copiasPendientes = 0
    var id: String { carpeta }

    var explicacion: String {
        alertas.map { a in
            switch a {
            case .faltaCarpeta(let l):
                return T("No está en el %@, pero la última vez sí. Si la borraste o la moviste a propósito, seguí y se manda a la papelera del otro lado.", T(l.nombre))
            case .muchosBorrados(let l, let n):
                return T("Se mandarían %ld archivos a la papelera del %@. Puede ser una limpieza tuya o un error.", n, T(l.nombre))
            case .sinEspacio(let l, let necesita, let hay):
                return T("No entra en el %@: hacen falta %@ y hay %@.", T(l.nombre), Formato.bytes(necesita), Formato.bytes(hay))
            }
        }.joined(separator: " ")
    }

    var sePuedeSeguir: Bool { !alertas.contains { if case .sinEspacio = $0 { return true }; return false } }

    /// Solo borrados (carpeta que ya no está o muchos archivos a la papelera): lo único que se aplica solo pasados
    /// unos días sin respuesta (`Coordinador.diasParaAplicar`). Lo que no entra nunca se aplica solo.
    var soloBorrados: Bool {
        !alertas.isEmpty && alertas.allSatisfy { if case .sinEspacio = $0 { return false }; return true }
    }

    /// No deja nada sin copiar: solo borrados esperando el OK. No frena "Me voy" ni cuenta como copia incompleta.
    var noFrena: Bool { soloBorrados && copiasPendientes == 0 }

    /// Si es "la carpeta ya no está de este lado" (la borraste o la moviste), de qué lado falta.
    var faltaDe: Lado? {
        for a in alertas { if case .faltaCarpeta(let l) = a { return l } }
        return nil
    }

    /// ¿Tu OK a este pedido alcanza para lo que hay ahora (`ahora`, de un análisis nuevo)? Sí si no apareció nada que
    /// no viste: la misma carpeta faltante, o igual o menos borrados del mismo lado. Antes tenía que ser idéntico, y en
    /// una carpeta que cambia sola (un borrado más) el botón no hacía nada. Lo usan `confirmar` y `confirmarTodos`.
    func autoriza(_ ahora: [Alerta]) -> Bool {
        ahora.allSatisfy { a in
            switch a {
            case .faltaCarpeta(let l):
                return alertas.contains(.faltaCarpeta(l))
            case .muchosBorrados(let l, let n):
                return alertas.contains { if case .muchosBorrados(l, let visto) = $0 { return n <= visto }; return false }
            case .sinEspacio:
                return false
            }
        }
    }
}

extension PedidoOK {
    /// El pedido que arma un análisis con alertas (también cuenta un repo con commits distintos como algo por copiar).
    init(_ a: Analisis) {
        self.init(carpeta: a.carpeta, alertas: a.alertas,
                  copiasPendientes: a.plan.resumen.haciaPortatil + a.plan.resumen.haciaHub + a.plan.resumen.reposDistintos.count)
    }
}

struct Avance: Equatable {
    var carpeta = ""
    var hechos = 0
    var total = 0
    var bytesHechos: Int64 = 0
    var bytesTotal: Int64 = 0
    var fraccion: Double {
        if bytesTotal > 0 { return min(1, Double(bytesHechos) / Double(bytesTotal)) }
        return total > 0 ? Double(hechos) / Double(total) : 0
    }
}

/// Lleva un vínculo (un hub y un portátil): decide cuándo sincronizar (al enchufar, cuando algo cambia si los dos
/// están conectados y con "Me voy"). Una sincronización a la vez; los pedidos que llegan mientras tanto se juntan.
final class Coordinador: ObservableObject, Identifiable {
    enum Estado: Equatable {
        case sinCarpetas, faltaHub, faltaPortatil, alReves, primeraVez, pausado, revisando, copiando, alDia, necesitaOK, expulsando
    }

    let id: String
    @Published private(set) var estado: Estado = .sinCarpetas
    /// Lo que se muestra: "revisando/copiando" solo aparece si dura más de un segundo. Así una copia chica en vivo no
    /// hace saltar la pantalla.
    @Published private(set) var estadoVisible: Estado = .sinCarpetas
    private var mostrarOcupado: DispatchWorkItem?
    /// Los discos de cada lado (para expulsar, ocultar, ícono) y las carpetas raíz que se sincronizan.
    @Published private(set) var hub: Volumen?
    @Published private(set) var portatil: Volumen?
    @Published private(set) var raizHub: String?
    @Published private(set) var raizPortatil: String?
    @Published private(set) var avance = Avance()
    @Published private(set) var pedidos: [PedidoOK] = []
    @Published private(set) var ultima: Date?
    /// Novedad para mostrar arriba (por ejemplo "Ya podés desenchufarlo").
    @Published var aviso: String? {
        didSet { if Notificar.prueba, let aviso { print("PANTALLA \(aviso)"); fflush(stdout) } }
    }
    @Published private(set) var listoParaIrse = false
    @Published private(set) var revisionAFondo: RevisionAFondo?
    /// Proyectos con claves (.env) que viajan en un portátil sin cifrar (0 = nada que avisar).
    @Published private(set) var clavesSinCifrar = 0
    /// Afuera: proyectos que llegaron sin sus dependencias y el comando para instalarlas.
    @Published private(set) var faltanDependencias: [(proyecto: String, comando: String)] = []
    /// Cuántos cambios trajo de cada carpeta en la vuelta que arrancó al enchufar el portátil.
    private var resumenVuelta: [String: Int]?
    private var relojMensual: Timer?

    var alCambiarEstado: (() -> Void)?

    private let ajustes = Ajustes.shared
    private let cola: DispatchQueue
    private var corriendo = false
    /// Carpetas pedidas mientras corría, con qué parte de cada una mirar (`Zonas.todo` = entera). Vacío = todas.
    private var pedidoGuardado: [String: Zonas]?
    private var alTerminar: [(Bool) -> Void] = []
    private var cancelador: Cancelador?
    private var vigia: Vigia!
    /// Lo que avisó la copia en vivo y espera sus segundos: carpeta del par → dónde cambió algo.
    private var sucias: [String: Zonas] = [:]
    private var temporizador: Timer?
    private var desmontesPedidos: [String: Date] = [:]
    private var ultimaLimpieza: Date?
    private var observadores: [NSObjectProtocol] = []
    private var remontando = false
    /// Cambiando nombres de discos (`acomodarNombres`): mientras tanto no se copia ni se vuelve a montar nada.
    private var renombrando = false
    /// Un cambio de nombre falló: no se reintenta hasta que se enchufe o se saque un disco (o se toque "Acomodar").
    private var nombresTrabados = false
    /// No se pudo ocultar o mostrar el portátil (algo lo usaba): igual, hasta que cambien los discos.
    private var visibilidadTrabada = false
    /// Desde cuándo está el portátil sin el hub (para no ponerle el nombre del hub mientras el hub todavía monta).
    private var portatilSoloDesde: Date?
    /// El nombre con el que se vio el portátil ya acomodado, en casa o afuera, mientras sigue enchufado: si cambia a uno
    /// que Relevo no pone, se lo cambiaste vos en el Finder (ver `acomodarNombres`). nil al desenchufarlo.
    private var nombreAcomodado: String?
    private var esperaNombreProgramada = false
    /// Expulsando el portátil ("Me voy" o "Expulsar"): ya lleva el nombre de afuera y no hay que devolverle el de casa.
    private var expulsandoPortatil = false
    /// El portátil se acaba de enchufar y todavía no arrancó la copia automática de la vuelta.
    private var vueltaPendiente = false
    /// Recién se juntaron los dos discos (enchufaste el portátil en casa o prendiste la Mac con los dos): hasta que Relevo
    /// acomoda los nombres y trae lo de afuera, una app que abras en el disco puede tomar el equivocado o archivos viejos.
    /// Inicio y la barra de menú lo muestran; si dura más de unos segundos, avisa al empezar y al terminar. Lo manejan
    /// `empezarLlegada`, `revisarLlegada` y `terminarLlegada`.
    @Published private(set) var llegando = false
    private var avisoLlegada: DispatchWorkItem?
    /// Ya se mandó el "Esperá" de esta llegada (entonces también va el "Listo").
    private var llegadaAvisada = false
    /// Cuándo se juntaron los discos de esta llegada (para anotar cuánto tardó en `Bitacora`).
    private var llegadaDesde: Date?
    /// Lo que trajo de afuera la vuelta de esta llegada, para decirlo en el "Listo" (en vez de otro aviso aparte).
    private var traidoEnLlegada: String?
    /// Si alguna vuelta de una cadena (copias que esperaban a otra) salió mal: así nadie recibe "bien" por una ajena.
    private var cadenaBien = true
    /// La última copia dejó algo sin copiar (un problema, un corte): "Me voy" revisa todo en vez de solo lo pendiente.
    private var quedoAlgo = true
    /// Proyectos con commits distintos ya avisados (para no repetir el aviso en cada vuelta).
    private var reposAvisados = Set<String>()
    /// Archivos que cambiaban mientras se copiaban en la última pasada de cada carpeta (dónde están): "Me voy" los
    /// vuelve a copiar antes de expulsar (`meVoyYa`).
    private var enUsoPendiente: [String: Zonas] = [:]

    /// `activo: false` solo muestra (para las capturas): nunca copia ni vigila.
    private let activo: Bool

    var vinculo: Vinculo? { ajustes.vinculo(id) }

    /// Cuándo arrancó Relevo: recién prendida la Mac, el hub puede tardar en montarse.
    static let inicio = Date()
    /// Cuándo se despertó la Mac por última vez (mismo margen que al prender).
    static var despertar = Date.distantPast
    /// Pasados estos días sin respuesta, los pedidos de OK que son solo borrados se aplican solos.
    static let diasParaAplicar = 3
    /// Lo mismo en segundos. Solo las pruebas (RELEVO_PRUEBA) lo pueden achicar, con RELEVO_PRUEBA_APLICAR_SEGUNDOS.
    static let segundosParaAplicar: TimeInterval = {
        if Notificar.prueba, let s = ProcessInfo.processInfo.environment["RELEVO_PRUEBA_APLICAR_SEGUNDOS"].flatMap(Double.init) { return s }
        return TimeInterval(diasParaAplicar) * 86_400
    }()

    init(id: String, activo: Bool = true) {
        self.id = id
        self.activo = activo
        cola = DispatchQueue(label: "team.halyon.relevo.\(id)", qos: .utility)
        vigia = Vigia { [weak self] rutas in self?.cambiaron(rutas) }
        ultima = UserDefaults.standard.object(forKey: "ultima-\(id)") as? Date
            ?? UserDefaults.standard.object(forKey: "ultima") as? Date
        guard activo else {
            refrescar()
            recalcularEstado()
            return
        }
        // Relevo no se cerró bien la última vez (corte de luz, Mac colgada): el registro de cambios puede no tener lo último.
        if !Cierre.anteriorFueLimpio { revisarTodoLaProxima = true }
        let centro = NSWorkspace.shared.notificationCenter
        observadores.append(centro.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] n in
            if let r = Self.ruta(n) { Bitacora.anotar("Se montó \(r) (aviso del Finder)") }
            self?.discosCambiaron(montado: Self.ruta(n))
        })
        // El aviso directo de macOS llega apenas se monta (el del Finder puede tardar decenas de segundos).
        observadores.append(NotificationCenter.default.addObserver(forName: Montajes.montado, object: nil, queue: .main) { [weak self] n in
            self?.discosCambiaron(montado: n.userInfo?["ruta"] as? String)
        })
        observadores.append(centro.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let r = Self.ruta(n) else { return }
            self.desmontesPedidos[r] = Date()
            // Que una sincronización en curso no trabe la expulsión.
            if r == self.portatil?.ruta || r == self.hub?.ruta { self.cancelador?.cancelar() }
        })
        observadores.append(centro.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] n in
            self?.discosCambiaron(desmontado: Self.ruta(n))
        })
        observadores.append(centro.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            // Al despertar, el hub puede tardar en volver: se le da el mismo margen que al prender la Mac.
            Coordinador.despertar = Date()
            self?.discosCambiaron()
        })
        // Un disco que cambió de nombre cambia de ruta (lo hace `acomodarNombres`, o alguien en el Finder).
        observadores.append(centro.addObserver(forName: NSWorkspace.didRenameVolumeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.discosCambiaron()
        })
        discosCambiaron()
        if UserDefaults.standard.object(forKey: "alta-\(id)") == nil { UserDefaults.standard.set(Date(), forKey: "alta-\(id)") }
        relojMensual = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            self?.revisionMensualSiToca()
            self?.aplicarVencidos()
            self?.revisionCompletaSiToca()
        }
    }

    /// Al quitar el vínculo: deja de vigilar y de escuchar avisos.
    func cerrar() {
        cancelador?.cancelar()
        vigia.detener()
        temporizador?.invalidate()
        relojMensual?.invalidate()
        observadores.forEach {
            NSWorkspace.shared.notificationCenter.removeObserver($0)
            NotificationCenter.default.removeObserver($0)
        }
        observadores = []
    }

    private static func ruta(_ n: Notification) -> String? {
        (n.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
    }

    // MARK: - Discos

    private func refrescar() {
        guard let v = vinculo else { hub = nil; portatil = nil; raizHub = nil; raizPortatil = nil; return }
        hub = v.hub.volumen()
        portatil = v.portatil.volumen()
        raizHub = v.hub.raiz()
        raizPortatil = v.portatil.raiz()
        // Si el portátil está pero todavía no tiene su carpeta (primera vez), se crea al copiar. Solo si no hay nada en
        // ese lugar: si hay algo que no es una carpeta de verdad (un enlace), no se usa (ver `Lugar.raiz`).
        if raizPortatil == nil, let p = portatil, !v.portatil.subcarpeta.isEmpty {
            let r = p.ruta + "/" + v.portatil.subcarpeta
            var st = stat()
            if lstat(r, &st) != 0, errno == ENOENT, Rutas.sinEnlaces(r, desde: p.ruta) { raizPortatil = r }
        }
    }

    func discosCambiaron(montado: String? = nil, desmontado: String? = nil) {
        let antesPortatil = portatil, antesHub = hub
        refrescar()
        if montado != nil || desmontado != nil { nombresTrabados = false; visibilidadTrabada = false }
        // Mientras cambia nombres, los discos se mueven de ruta: al terminar vuelve a pasar por acá.
        if renombrando { recalcularEstado(); return }

        if remontando, desmontado != nil { return }
        // Copia automática al aparecer cualquiera de los dos (portátil enchufado con el hub ya puesto, o al revés: el hub
        // llega con el portátil ya enchufado y lo de afuera tiene que copiarse enseguida).
        if (antesPortatil == nil || antesHub == nil), portatil != nil, hub != nil { vueltaPendiente = true; empezarLlegada() }
        // Se fue uno de los dos (no por volver a montarlo, eso sale antes): ya no hay nada que esperar.
        if portatil == nil || hub == nil { terminarLlegada(avisar: false) }
        if portatil == nil {
            vueltaPendiente = false; expulsandoPortatil = false; nombreAcomodado = nil
            cola.async { [weak self] in self?.identidadRevisada = nil }   // el próximo que se enchufe se mira de nuevo
        }
        if (portatil == nil || hub == nil), esperandoPortatilLibre { esperandoPortatilLibre = false; aviso = nil }
        // El hub se fue sin que nadie lo expulsara (corte de luz, cable): el registro de cambios de ese disco puede no
        // haber guardado lo último, así que la próxima revisión inteligente mira todo.
        if let d = desmontado, let antes = antesHub, hub == nil, !antes.esEstaMac,
           (desmontesPedidos[d] ?? desmontesPedidos[antes.ruta]).map({ Date().timeIntervalSince($0) >= 120 }) ?? true {
            revisarTodoLaProxima = true
        }
        // El portátil se fue (por su ruta de antes o por la nueva, si le cambiamos el nombre para irse).
        if let d = desmontado, let antes = antesPortatil, portatil == nil {
            listoParaIrse = false
            if let pedido = desmontesPedidos[d] ?? desmontesPedidos[antes.ruta], Date().timeIntervalSince(pedido) < 120 {
                // Expulsado bien: lo último que se le copió quedó guardado seguro.
                Sincronizador(volumenHub: "", volumenPortatil: "", estado: Ajustes.carpetaEstado(id)).expulsadoBien(.portatil)
            } else {
                aviso = T("Sacaste el portátil sin expulsarlo. Cuando lo vuelvas a enchufar reviso lo último que se le copió.")
                // Su registro de cambios puede no haber guardado lo último: al volver se mira todo, sin atajos.
                revisarTodoLaProxima = true
            }
        }
        recalcularEstado()
        vigilar()
        marcarDiscos()
        revisarAfuera()
        if antesPortatil == nil, portatil != nil { revisarEspacio() }
        if acomodarNombres() { return }       // cambia nombres: al terminar sigue desde acá
        if acomodarVisibilidad() { return }   // se vuelve a montar: al reaparecer sigue desde acá
        if vueltaPendiente, portatil != nil, hub != nil, ajustes.datos.automatico, estado != .alReves,
           !(vinculo?.pausado ?? false) {
            // Recién enchufado: un respiro para que macOS termine de montarlo.
            vueltaPendiente = false
            vueltaEnCurso = true
            resumenVuelta = [:]
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.sincronizarInteligente { [weak self] _ in
                    self?.vueltaEnCurso = false
                    // Lo que trajo de afuera, tanto si revisó todo como solo lo que cambió (antes solo salía al revisar
                    // todo, y como cada vuelta revisaba todo no se notaba: 31/10/2026).
                    if let r = self?.resumenVuelta { self?.resumenVuelta = nil; self?.avisarVuelta(r) }
                    self?.revisarLlegada()
                    // Si la última revisión completa fue hace mucho (por ejemplo, el portátil se usó en otra Mac),
                    // se hace una de fondo; si te vas, se frena sola.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 60) { self?.revisionCompletaSiToca(alVolver: true) }
                }
            }
        }
        revisarLlegada()
    }

    // MARK: - Llegada (esperá antes de abrir tus apps)

    /// Lo llama `discosCambiaron` cuando se juntan los dos discos. Si todo se acomoda en un par de segundos (nada que
    /// renombrar ni traer), no avisa nada; si tarda, manda el "Esperá" (el "Listo" lo manda `terminarLlegada`).
    private func empezarLlegada() {
        guard activo, !llegando else { return }
        llegando = true
        llegadaDesde = Date()
        Bitacora.anotar("Llegada: están los dos discos (hub \(hub?.ruta ?? "?"), portátil \(portatil?.ruta ?? "?"))")
        llegadaAvisada = false
        traidoEnLlegada = nil
        alCambiarEstado?()
        let w = DispatchWorkItem { [weak self] in
            guard let self, self.llegando, !self.llegadaAvisada else { return }
            self.llegadaAvisada = true
            Notificar.enviar(T("Esperá antes de abrir tus apps"),
                             T("Estoy acomodando los discos y trayendo lo que hiciste afuera. Te aviso cuando termine."))
        }
        avisoLlegada = w
        DispatchQueue.main.asyncAfter(deadline: .now() + (Notificar.prueba ? 0.5 : 3), execute: w)
    }

    /// Termina la llegada cuando ya no queda nada en curso: nombres, volver a montar, la vuelta de lo de afuera y una app
    /// usando el portátil con la ruta del hub (`esperandoPortatilLibre`: hasta que la cierres, el hub no recupera su
    /// lugar). Lo llaman `discosCambiaron` (al final) y la vuelta al terminar.
    private func revisarLlegada() {
        guard llegando, !renombrando, !remontando, !mirandoUso, !vueltaEnCurso, !esperandoPortatilLibre else { return }
        terminarLlegada(avisar: true)
    }

    /// `avisar`: false cuando se fue un disco (no hay "Listo" que dar).
    private func terminarLlegada(avisar: Bool) {
        guard llegando else { return }
        llegando = false
        if let d = llegadaDesde {
            Bitacora.anotar(String(format: "Llegada terminada en %.1f s%@", Date().timeIntervalSince(d), avisar ? "" : " (se fue un disco)"))
        }
        llegadaDesde = nil
        avisoLlegada?.cancel()
        avisoLlegada = nil
        alCambiarEstado?()
        if avisar, llegadaAvisada {
            let detalle = pedidos.isEmpty
                ? (traidoEnLlegada ?? T("Los discos están en su lugar y todo al día."))
                : T("Los discos están en su lugar. Quedó algo esperando tu OK: miralo en Relevo.")
            Notificar.enviar(T("Listo, ya podés abrir tus apps"), detalle)
        }
        llegadaAvisada = false
        traidoEnLlegada = nil
    }

    /// Los nombres de los discos, si el vínculo usa el nombre del hub afuera (`Vinculo.nombreAfuera`):
    /// - En casa (los dos conectados): el portátil se llama "<nombre> (portátil)" y, si el portátil le había ganado
    ///   la ruta al hub (macOS montó primero el portátil al prender), el hub recupera /Volumes/<nombre>.
    /// - Con el portátil solo (afuera), pasados 20 segundos por si el hub todavía está montándose: toma el nombre del hub.
    /// Cambiar el nombre no desmonta nada y anda aunque los discos estén en uso. Lo llama `discosCambiaron`; devuelve
    /// true si empezó a cambiar nombres (al terminar vuelve a llamar a `discosCambiaron`).
    private func acomodarNombres() -> Bool {
        guard activo, !renombrando, !nombresTrabados, !corriendo, !expulsandoPortatil, let v = vinculo,
              let p = portatil, Vinculo.discosEnteros(v.hub, v.portatil) else { portatilSoloDesde = nil; return false }
        // Dos discos enteros con el mismo nombre (por ejemplo, renombrados a mano): es que se quiere el mismo nombre afuera.
        if v.nombreAfuera == nil, let h = hub, h.nombre == p.nombre {
            ajustes.cambiar(id) { $0.nombreAfuera = h.nombre }
            if renombrando { return true }   // el cambio de ajustes ya volvió a pasar por acá y arrancó
        }
        // Si le cambiaste el nombre al hub, afuera el portátil toma el nombre nuevo.
        if let h = hub, let viejo = vinculo?.nombreAfuera, h.nombre != viejo, h.ruta == "/Volumes/" + h.nombre,
           !h.nombre.hasSuffix(" ·"), h.nombre != (vinculo?.nombreEnCasa ?? Discos.nombreEnCasa(viejo)) {
            ajustes.cambiar(id) { $0.nombreAfuera = h.nombre; $0.nombreEnCasa = nil }
            if renombrando { return true }
        }
        guard let afuera = vinculo?.nombreAfuera else { return false }
        var pasos: [() -> Bool] = []
        // Relevo solo pone el nombre de afuera o el de casa: si el portátil, ya acomodado y sin desenchufarse, pasó a
        // llamarse de otra forma, se lo cambiaste vos en el Finder.
        let enCasaAntes = vinculo?.nombreEnCasa ?? Discos.nombreEnCasa(afuera)
        let renombradoPorVos = nombreAcomodado != nil && nombreAcomodado != p.nombre && ![afuera, enCasaAntes].contains(p.nombre)
            && !p.nombre.hasSuffix(" ·") && !p.nombre.isEmpty
        if let h = hub {
            portatilSoloDesde = nil
            // En casa ese nombre se respeta: pasa a ser su nombre de casa (afuera sigue con el del hub).
            if renombradoPorVos {
                Bitacora.anotar("Le pusiste al portátil “\(p.nombre)”: queda como su nombre en casa")
                ajustes.cambiar(id) { $0.nombreEnCasa = p.nombre }
            }
            let enCasa = vinculo?.nombreEnCasa ?? Discos.nombreEnCasa(afuera)
            if vinculo?.nombreEnCasa == nil { ajustes.cambiar(id) { $0.nombreEnCasa = enCasa } }
            if p.nombre == enCasa, p.ruta == "/Volumes/" + enCasa { nombreAcomodado = p.nombre }
            // El portátil tiene la ruta de afuera y lo estás usando: cambiarle el nombre ahora haría que lo que guarda
            // por esa ruta pase a escribir en el hub a mitad de camino. Se espera a que quede libre (se copia igual).
            if p.nombre != enCasa, p.ruta == "/Volumes/" + afuera, !portatilLibreParaPasar(p) { return false }
            if esperandoPortatilLibre { esperandoPortatilLibre = false; aviso = nil }
            if p.nombre != enCasa { pasos.append { Discos.renombrar(uuid: p.uuid, a: enCasa) } }
            // Si un renombre anterior quedó a medias, el hub vuelve a su nombre.
            if h.nombre == afuera + " ·" { pasos.append { Discos.renombrar(uuid: h.uuid, a: afuera) } }
            else if h.ruta != "/Volumes/" + h.nombre, !Discos.rutaOcupada(h.nombre, salvo: p.uuid) {
                pasos.append { Discos.buscar(h.uuid).map(Discos.recuperarRuta) ?? false }
            }
        } else {
            // Afuera no: tiene que llamarse como el hub para que tus apps encuentren los proyectos. Se le devuelve el
            // nombre (más abajo) y se explica por qué.
            if renombradoPorVos {
                aviso = T("Afuera el portátil tiene que llamarse “%@”, como el disco de casa: así tus apps encuentran los proyectos en la misma ubicación. Le devolví ese nombre. En casa sí le podés poner el nombre que quieras.", afuera)
                nombreAcomodado = nil
                portatilSoloDesde = .distantPast   // sin esperar: ya se sabe que el hub no está
            }
            if p.nombre == afuera { nombreAcomodado = p.nombre }
            guard p.nombre != afuera else { portatilSoloDesde = nil; return false }
            let desde = portatilSoloDesde ?? Date()
            portatilSoloDesde = desde
            // Recién prendida la Mac se espera 20 s por si el hub todavía está montando; con Relevo ya andando (lo
            // enchufaste afuera), alcanza con un respiro. Así el nombre de afuera no depende de tocar "Me voy".
            let recien = min(Date().timeIntervalSince(Self.inicio), Date().timeIntervalSince(Self.despertar))
            let espera: TimeInterval = recien < 90 ? 20 : 3
            let falta = espera - Date().timeIntervalSince(desde)
            if falta > 0 {
                if !esperaNombreProgramada {
                    esperaNombreProgramada = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + falta + 0.5) { [weak self] in
                        self?.esperaNombreProgramada = false
                        self?.discosCambiaron()
                    }
                }
                return false
            }
            // Si otro disco ya se llama así, no se le saca el lugar.
            guard !Discos.rutaOcupada(afuera, salvo: p.uuid) else { return false }
            pasos.append { Discos.renombrar(uuid: p.uuid, a: afuera) }
        }
        guard !pasos.isEmpty else { return false }
        renombrando = true
        let desde = Date()
        Bitacora.anotar("Cambio los nombres de los discos")
        cola.async { [weak self] in
            let bien = pasos.allSatisfy { $0() }
            DispatchQueue.main.async {
                guard let self else { return }
                Bitacora.anotar(String(format: "Nombres %@ en %.1f s", bien ? "listos" : "trabados", Date().timeIntervalSince(desde)))
                self.renombrando = false
                if !bien {
                    self.nombresTrabados = true
                    self.aviso = T("No pude cambiarle el nombre a un disco. Probá “Acomodar” o cambiáselo a mano en el Finder.")
                }
                self.discosCambiaron()
            }
        }
        return true
    }

    /// Un disco con el UUID del portátil aparece sin cifrar, pero hay una clave guardada para ese UUID: no es el portátil
    /// que se cifró (puede ser otro armado con el mismo UUID). Se usa solo en la cola (ver `identidadDudosa`).
    private var identidadRevisada: (uuid: String, dudosa: Bool)?

    /// ¿El disco que dice ser el portátil es dudoso? Se mira una vez por disco enchufado (diskutil tarda un poco) y solo
    /// si hay una clave guardada para él (si nunca se cifró, no hay nada que comparar). Corre en la cola; lo llaman
    /// `sincronizar` y los "Sí, seguir" antes de copiar o borrar nada. Si es dudoso, avisa (auditoría del 23/10).
    private func identidadDudosa(_ uuid: String?, conClave: Bool) -> Bool {
        guard let uuid, conClave else { return false }
        if let r = identidadRevisada, r.uuid == uuid { return r.dudosa }
        let dudosa = Cifrado.estado(uuid: uuid) == .sinCifrar
        identidadRevisada = (uuid, dudosa)
        if dudosa {
            DispatchQueue.main.async { [weak self] in
                self?.aviso = T("El disco que dice ser tu portátil aparece sin cifrar, pero tu portátil está cifrado. No copio nada a ese disco. Si lo descifraste vos a propósito, borrá su clave en la app Llaves.")
            }
        }
        return dudosa
    }

    /// Para pasar a la cola: el UUID del portátil y si tiene una clave guardada (el llavero se consulta acá).
    private var datosIdentidad: (uuid: String?, conClave: Bool) {
        guard let p = portatil, !p.esEstaMac else { return (nil, false) }
        return (p.uuid, Llavero.donde(p.uuid) != nil)
    }

    /// El hub llegó mientras usabas el portátil con la ruta de afuera: se copia igual, pero el portátil sigue con esa
    /// ruta hasta que lo dejes de usar (ver `acomodarNombres`).
    @Published private(set) var esperandoPortatilLibre = false
    /// Mirando (en otra cola) si algo con ventana usa el portátil; y cuándo se lo vio libre por última vez.
    private var mirandoUso = false
    private var libreVisto: Date?, ultimaMirada: Date?
    /// "Acomodar" a mano: pasa al hub aunque el portátil esté en uso.
    private var forzarNombres = false
    /// Cada cuánto se vuelve a mirar si el portátil quedó libre.
    static let esperaUso: TimeInterval = Notificar.prueba ? 4 : 15

    /// ¿Se puede pasar al hub (cambiar el nombre del portátil)? Solo si nada con ventana (Claude, Terminal, un editor)
    /// está trabajando adentro del portátil; lo de fondo que arranca solo (servidores, scripts) no cuenta, si no nunca
    /// quedaría libre. Mirarlo tarda (lsof), así que se hace en otra cola: mientras tanto devuelve false y, al saberlo,
    /// vuelve a pasar por `discosCambiaron`. Lo llama `acomodarNombres`.
    private func portatilLibreParaPasar(_ p: Volumen) -> Bool {
        if forzarNombres { forzarNombres = false; return true }
        if let visto = libreVisto, Date().timeIntervalSince(visto) < 5 { return true }
        // Ya se sabe que está en uso: se vuelve a mirar en un rato (lo programa la mirada anterior).
        if mirandoUso || ultimaMirada.map({ Date().timeIntervalSince($0) < Self.esperaUso }) == true { return false }
        mirandoUso = true
        ultimaMirada = Date()
        cola.async { [weak self] in
            let uso = Procesos.usando(p.ruta)
            let trabajando = uso.conVentana.filter(\.cerrable)
            DispatchQueue.main.async {
                guard let self else { return }
                self.mirandoUso = false
                if trabajando.isEmpty {
                    self.libreVisto = Date()
                } else {
                    self.libreVisto = nil
                    Bitacora.anotar("El portátil está en uso (\(trabajando.map(\.app).joined(separator: ", "))): espero para cambiar los nombres")
                    if !self.esperandoPortatilLibre {
                        self.esperandoPortatilLibre = true
                        // Lo que más pasa: abriste Claude (o la Terminal) antes de que Relevo acomodara los discos y
                        // quedó trabajando en el portátil. Se dice qué app, para que la cierres y la vuelvas a abrir.
                        let apps = trabajando.map(\.app).joined(separator: ", ")
                        self.aviso = T("%@ quedó abierto en el portátil. Cerralo: paso al disco de casa y te aviso para que lo vuelvas a abrir.", apps)
                        Notificar.enviar(T("Cerrá %@ un momento", apps),
                                         T("Se abrió en el portátil antes de que acomodara los discos. Cuando lo cierres paso al disco de casa y te aviso para que lo vuelvas a abrir."))
                        // El "Listo" de la llegada es el aviso para volver a abrirla (ya no hace falta el "Esperá").
                        self.empezarLlegada()
                        self.llegadaAvisada = true
                        if Notificar.prueba { print("ESPERA \(UsoDeDisco(grupos: trabajando).texto)"); fflush(stdout) }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.esperaUso + 0.1) { [weak self] in self?.discosCambiaron() }
                }
                // Ya se sabe: si está libre, se cambian los nombres; si no, se sigue (copia en vivo, la vuelta) esperando.
                self.discosCambiaron()
            }
        }
        return false
    }

    /// Terminó "Expulsar discos" (bien o mal): si el portátil sigue enchufado, vuelve a llevar su nombre de casa.
    func terminoExpulsion() {
        expulsandoPortatil = false
        // Si el portátil sigue enchufado (no se pudo expulsar), lo anotado para reconocer la expulsión ya no vale.
        if let p = portatil, Discos.buscar(p.uuid) != nil { desmontesPedidos.removeAll() }
    }

    /// En casa el portátil va oculto (si se llama igual que el hub, en el Finder se ve uno solo); afuera, visible.
    /// Devuelve true si empezó a volver a montarlo.
    private func acomodarVisibilidad() -> Bool {
        guard activo, !remontando, !renombrando, !visibilidadTrabada, !corriendo, !expulsandoPortatil, let p = portatil,
              let v = vinculo, !alReves, !p.esEstaMac else { return false }
        let ocultar = v.ocultarEnCasa && hub != nil
        guard p.visible == ocultar else { return false }
        remontando = true
        desmontesPedidos[p.ruta] = Date()
        let desde = Date()
        Bitacora.anotar("Vuelvo a montar el portátil \(ocultar ? "oculto" : "visible")")
        cola.async { [weak self] in
            // Si está cifrado, al desmontarlo se cierra: `remontar` lo vuelve a abrir con la clave del llavero.
            let bien = Discos.remontar(p, oculto: ocultar, clave: Self.clave(p.uuid))
            let quedoAfuera = !bien && Discos.buscar(p.uuid) == nil
            DispatchQueue.main.async {
                guard let self else { return }
                Bitacora.anotar(String(format: "Portátil montado otra vez %@ en %.1f s", bien ? "bien" : "con problemas", Date().timeIntervalSince(desde)))
                self.remontando = false
                self.desmontesPedidos[p.ruta] = nil
                // Si algo lo está usando no se puede volver a montar: no se insiste hasta que cambien los discos.
                if !bien { self.visibilidadTrabada = true }
                // Nunca en silencio: enchufado pero sin montar parece desconectado (25/10/2026).
                if quedoAfuera {
                    self.aviso = T("No pude volver a abrir el portátil. Desenchufalo y volvelo a enchufar; si está cifrado y no se abre solo, poné su clave.")
                }
                self.discosCambiaron()
            }
        }
        return true
    }

    /// Si el portátil está enchufado pero cifrado y cerrado, lo abre con la clave del llavero (si está). En casa entra
    /// directamente oculto, así `acomodarVisibilidad` no tiene que desmontarlo. Lo llama `MonitorDiscos` al aparecer un disco.
    private var desbloqueando = false
    func intentarDesbloquear() {
        guard activo, !desbloqueando, portatil == nil, let v = vinculo, !v.portatil.esEstaMac,
              let clave = Self.clave(v.portatil.uuid) else { return }
        let uuid = v.portatil.uuid
        let oculto = v.ocultarEnCasa && hub != nil
        desbloqueando = true
        cola.async { [weak self] in
            var abierto = false
            if Cifrado.estado(uuid: uuid) == .bloqueado { abierto = Cifrado.abrir(uuid: uuid, clave: clave, oculto: oculto) }
            DispatchQueue.main.async {
                self?.desbloqueando = false
                if abierto { self?.discosCambiaron() }
            }
        }
    }

    /// La clave del portátil: la del llavero. Solo en las pruebas (RELEVO_PRUEBA, con un hogar falso que no tiene
    /// llavero) puede venir de RELEVO_PRUEBA_CLAVE; la lectura del llavero la prueba `prueba-cifrado.sh`.
    private static func clave(_ uuid: String) -> String? {
        if Notificar.prueba, let c = ProcessInfo.processInfo.environment["RELEVO_PRUEBA_CLAVE"], !c.isEmpty { return c }
        return Llavero.leer(uuid)
    }

    /// Abre el portátil en el Finder (aunque esté oculto de la barra lateral).
    func mostrarPortatil() {
        if let r = raizPortatil ?? portatil?.ruta { Discos.mostrarEnFinder(r) }
    }

    /// Que cada disco tenga su ícono ("HUB · CASA" / "PORTÁTIL"): aunque se llamen igual, no se confunden.
    private func marcarDiscos() {
        guard activo else { return }
        for (v, esHub) in [(hub, true), (portatil, false)] {
            // lstat: si ahí hay cualquier cosa (también un enlace roto armado en el disco), no se toca.
            var st = stat()
            guard let v, !v.esEstaMac, lstat(v.ruta + "/.VolumeIcon.icns", &st) != 0 else { continue }
            MarcaDisco.poner(v.ruta, hub: esHub)
        }
    }

    private func recalcularEstado() {
        guard !corriendo else { return }
        let nuevo: Estado
        if (vinculo?.carpetas ?? []).isEmpty { nuevo = .sinCarpetas }
        else if raizHub == nil { nuevo = .faltaHub }
        else if portatil == nil { nuevo = .faltaPortatil }
        else if trabadoAlReves { nuevo = .alReves }
        else if !pedidos.isEmpty { nuevo = .necesitaOK }
        else if vinculo?.pausado ?? false { nuevo = .pausado }
        else if ultima == nil { nuevo = .primeraVez }
        else { nuevo = .alDia }
        poner(nuevo)
    }

    private func poner(_ e: Estado) {
        guard estado != e else { return }
        estado = e
        let ocupado: (Estado) -> Bool = { $0 == .revisando || $0 == .copiando }
        if ocupado(e) {
            if ocupado(estadoVisible) { estadoVisible = e } else if mostrarOcupado == nil {
                let w = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.mostrarOcupado = nil
                    if ocupado(self.estado) { self.estadoVisible = self.estado; self.alCambiarEstado?() }
                }
                mostrarOcupado = w
                DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: w)
            }
        } else {
            mostrarOcupado?.cancel()
            mostrarOcupado = nil
            estadoVisible = e
        }
        if Notificar.prueba { print("ESTADO \(e)"); fflush(stdout) }
        alCambiarEstado?()
    }

    /// Si el portátil quedó montado con el nombre del hub (porque se enchufó primero), las rutas apuntarían al
    /// disco equivocado.
    var alReves: Bool {
        guard let hub, let portatil, !hub.esEstaMac else { return false }
        return portatil.ruta == "/Volumes/\(hub.nombre)" && hub.ruta != portatil.ruta
    }

    /// Al revés y sin poder copiar: las rutas de tus herramientas apuntan al disco equivocado. Mientras se espera que
    /// termines de usar el portátil para pasar al hub (`esperandoPortatilLibre`), al revés es a propósito y se copia igual
    /// (Relevo busca cada disco por su UUID, no por el nombre).
    var trabadoAlReves: Bool { alReves && !esperandoPortatilLibre }

    var conectados: Bool { raizHub != nil && portatil != nil }

    // MARK: - Qué se sincroniza

    /// Cada carpeta que se sincroniza por separado ("Proyectos/*" se abre en cada proyecto).
    func pares() -> [String] {
        guard let v = vinculo else { return [] }
        let raices = [raizHub, raizPortatil].compactMap { $0 }
        guard !raices.isEmpty else { return [] }
        var salida: [String] = []
        let excluidas = Set(ajustes.excluidasEfectivas)
        let omitidas = Set(v.omitidas)
        for c in v.carpetas {
            guard c.hasSuffix("/*") else { salida.append(c); continue }
            let base = String(c.dropLast(2))
            var nombres = Set<String>()
            for raiz in raices {
                let dir = raiz + "/" + base
                // Solo carpetas de verdad (no enlaces): un enlace armado en el portátil (por ejemplo "Proyectos" apuntando
                // a otra carpeta de la Mac) haría sincronizar lo que hay ahí (auditoría del 23/10).
                guard Rutas.sinEnlaces(dir, desde: raiz) else { continue }
                for n in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where !n.hasPrefix(".") && !excluidas.contains(n) {
                    var st = stat()
                    if lstat(dir + "/" + n, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR { nombres.insert(n) }
                }
            }
            salida += nombres.sorted().map { base + "/" + $0 }.filter { !omitidas.contains($0) }
        }
        return Self.sinPisarse(salida, carpetas: v.carpetas)
    }

    /// Que ningún archivo quede en dos carpetas del par: cada una guarda su propia memoria de lo copiado y, con dos, un
    /// cambio que una ya copió y la otra todavía no aparecía como conflicto (pasó el 31/10/2026: "Proyectos/*" y
    /// también "Proyectos/Apps/*"). Si una carpeta se abre en sus proyectos ("Apps/*"), no va además como un
    /// proyecto más: de ella solo van sus archivos sueltos ("Apps/."). Y lo que ya está adentro de otra carpeta del par
    /// viaja con esa. Lo usan `pares()` y `zonasDe` (que manda a "Apps/." los cambios sueltos de Apps).
    static func sinPisarse(_ pares: [String], carpetas: [String]) -> [String] {
        let abiertas = Set(carpetas.filter { $0.hasSuffix("/*") }.map(base))
        var salida: [String] = []
        for p in pares {
            let q = abiertas.contains(p) ? p + "/." : p
            if !salida.contains(q) { salida.append(q) }
        }
        let enteras = salida.filter { !$0.hasSuffix("/.") }
        return salida.filter { p in !enteras.contains { $0 != p && base(p).estaDentroDe($0) } }
    }

    func sincronizador() -> Sincronizador? {
        guard let raizHub, let raizPortatil else { return nil }
        let s = Sincronizador(volumenHub: raizHub, volumenPortatil: raizPortatil, reglas: ajustes.reglas,
                              estado: Ajustes.carpetaEstado(id))
        let gitignore = ajustes.datos.respetarGitignore, llevar = ajustes.datos.llevarDependencias
        // Carpetas puntuales que no se sincronizan (elegidas en "Lo que nunca se sincroniza" o destildadas en el árbol): rutas
        // desde la raíz del hub. Las que son una carpeta del par entera ya las saca `pares()`; acá, las de adentro.
        let omitidas = vinculo?.omitidas ?? []
        if gitignore || !omitidas.isEmpty {
            s.ignoradas = { carpeta in
                let base = Coordinador.base(carpeta)
                var salida = Set<String>()
                if gitignore {
                    let todas = Git.ignoradas(raizHub + "/" + base).union(Git.ignoradas(raizPortatil + "/" + base))
                    // Si se eligió llevar las dependencias, el .gitignore no las deja afuera.
                    salida = llevar ? todas.filter { r in !r.split(separator: "/").contains { Reglas.dependencias.contains(String($0)) } } : todas
                }
                for o in omitidas where o.hasPrefix(base + "/") { salida.insert(String(o.dropFirst(base.count + 1))) }
                return salida
            }
        }
        return s
    }

    // MARK: - En vivo

    private func vigilar() {
        guard activo, ajustes.datos.enVivo, let v = vinculo, let raizHub, let raizPortatil, portatil != nil,
              !v.carpetas.isEmpty, !trabadoAlReves, !v.pausado, !expulsandoPortatil else { vigia.detener(); return }
        var rutas: [String] = []
        for c in v.carpetas {
            let base = Self.base(c)
            rutas.append(raizHub + "/" + base)
            rutas.append(raizPortatil + "/" + base)
        }
        vigia.vigilar(rutas)
    }

    static func base(_ c: String) -> String {
        if c.hasSuffix("/*") || c.hasSuffix("/.") { return String(c.dropLast(2)) }
        return c
    }

    func ajustesCambiaron() {
        discosCambiaron()
    }

    /// Lo llama la copia en vivo (`Vigia`) con las carpetas donde pasó algo. Junta los avisos y, cuando dejás de
    /// guardar unos segundos, copia mirando solo esas carpetas (`Zonas`).
    private func cambiaron(_ eventos: [(ruta: String, entera: Bool)]) {
        for (par, z) in zonasDe(eventos) { sucias[par, default: Zonas()].unir(z) }
        guard !sucias.isEmpty else { return }
        // Se espera a que dejes de guardar unos segundos antes de copiar.
        temporizador?.invalidate()
        temporizador = Timer.scheduledTimer(withTimeInterval: 3, repeats: false) { [weak self] _ in
            self?.copiarSucias()
        }
    }

    /// Copia ya lo que juntó la copia en vivo. Devuelve false si no había nada.
    /// Si la copia en vivo viene al día, al terminar deja la marca del registro de cambios (`marcasGuardadas`) en el
    /// último aviso que llegó: así "Me voy", "Expulsar" o enchufar de nuevo miran solo lo que pasó después, y no todo
    /// lo que se tocó en el día (eso era lo que, al irte, se ponía a "encontrar archivos").
    @discardableResult
    private func copiarSucias(aMano: Bool = false, alTerminar: ((Bool) -> Void)? = nil) -> Bool {
        temporizador?.invalidate()
        let lista = sucias
        sucias = [:]
        guard !lista.isEmpty else { return false }
        var fin = alTerminar
        if alTerminar == nil, let nuevas = marcasDeLaCopiaEnVivo() {
            fin = { [weak self] _ in
                // Solo si no quedó nada atrás ni llegó nada nuevo mientras copiaba (eso entra en la próxima).
                guard let self, !self.quedoAlgo, self.sucias.isEmpty, !self.corriendo else { return }
                self.marcasGuardadas = nuevas
            }
        }
        sincronizar(Set(lista.keys), zonas: lista, aMano: aMano, alTerminar: fin)
        return true
    }

    /// La marca hasta donde la copia en vivo ya recibió todos los avisos (los de antes ya están en `sucias` o se
    /// copiaron). nil si no viene al día: sin marca anterior (falta una revisión entera), algo quedó atrás, recién
    /// enchufado o después de un corte (ahí manda `revisarTodoLaProxima`). Lo usa `copiarSucias`.
    private func marcasDeLaCopiaEnVivo() -> MarcasGuardadas? {
        guard ajustes.datos.enVivo, vigia.activo, let evento = vigia.ultimoEvento, !quedoAlgo, !vueltaPendiente,
              !vueltaEnCurso, !revisarTodoLaProxima, marcasGuardadas != nil,
              var ahora = marcasDeAhora(), var hub = ahora.hub, var portatil = ahora.portatil else { return nil }
        hub.evento = min(hub.evento, evento)
        portatil.evento = min(portatil.evento, evento)
        ahora.hub = hub; ahora.portatil = portatil
        return ahora
    }

    /// Las carpetas del par (las que se sincronizan por separado, ver `pares()`) que tocan esas rutas (completas, de
    /// cualquiera de los dos discos) y, de cada una, dónde cambió algo (`Zonas`, relativas a la carpeta del par;
    /// `entera`: macOS pide mirar todo lo de adentro). Lo usan la copia en vivo (`cambiaron`) y la revisión inteligente.
    /// `cambioArriba` (solo la revisión inteligente): si cambió una carpeta "madre" como Proyectos (se creó, borró o
    /// renombró un proyecto), cuenta.
    private func zonasDe(_ eventos: some Sequence<(ruta: String, entera: Bool)>,
                         cambioArriba: UnsafeMutablePointer<Bool>? = nil) -> [String: Zonas] {
        guard let v = vinculo, let raizHub, let raizPortatil else { return [:] }
        let excluidas = Set(ajustes.excluidasEfectivas)
        let abiertas = Set(v.carpetas.filter { $0.hasSuffix("/*") }.map(Self.base))
        var salida: [String: Zonas] = [:]
        func anotar(_ par: String, _ adentro: [String], _ entera: Bool) {
            let r = adentro.joined(separator: "/")
            var z = Zonas()
            if entera { z.enteras = [r] } else { z.planas = [r] }
            salida[par, default: Zonas()].unir(r.isEmpty && entera ? .todo : z)
        }
        for (r, entera) in eventos {
            var relativa: Substring
            if r.hasPrefix(raizHub + "/") { relativa = r.dropFirst(raizHub.count + 1) }
            else if r.hasPrefix(raizPortatil + "/") { relativa = r.dropFirst(raizPortatil.count + 1) }
            else if r == raizHub || r == raizPortatil { cambioArriba?.pointee = true; continue }
            else { continue }
            if relativa.hasSuffix("/") { relativa = relativa.dropLast() }
            let partes = relativa.split(separator: "/").map(String.init)
            if partes.contains(where: { excluidas.contains($0) || $0 == ".Relevo" || $0 == ".DS_Store" }) { continue }
            // Un `pnpm install` en una copia de trabajo de Claude Code no viaja: ni siquiera dispara una pasada.
            if Reglas.dependenciaDeCopiaDeTrabajo(String(relativa)) { continue }
            for c in v.carpetas {
                if c.hasSuffix("/*") {
                    let base = c.dropLast(2).split(separator: "/").map(String.init)
                    if partes.count > base.count, Array(partes.prefix(base.count)) == base {
                        let par = (base + [partes[base.count]]).joined(separator: "/")
                        if abiertas.contains(par) {
                            // Se abre en sus proyectos (ver `sinPisarse`): lo de adentro lo anota su "par/*"; acá, solo
                            // sus archivos sueltos. Si macOS pide mirarla entera, también todos sus proyectos.
                            if partes.count == base.count + 1 {
                                salida[par + "/."] = .todo
                                if entera { for q in pares() where Self.base(q).estaDentroDe(par) { salida[q] = .todo } }
                            }
                        } else if !v.omitidas.contains(par) { anotar(par, Array(partes.dropFirst(base.count + 1)), entera) }
                    } else if base.starts(with: partes) {
                        cambioArriba?.pointee = true
                    }
                } else if c.hasSuffix("/.") {
                    // Archivos sueltos: un cambio en esa misma carpeta (FSEvents avisa la carpeta). Son pocos: enteros.
                    let base = c.dropLast(2).split(separator: "/").map(String.init)
                    if partes == base || (partes.count == base.count + 1 && Array(partes.prefix(base.count)) == base) {
                        salida[c] = .todo
                    }
                } else if String(relativa).estaDentroDe(c) {
                    anotar(c, Array(partes.dropFirst(c.split(separator: "/").count)), entera)
                } else if c.estaDentroDe(String(relativa)) {
                    cambioArriba?.pointee = true
                }
            }
        }
        return salida
    }

    // MARK: - Revisión inteligente (solo lo que cambió)

    private struct MarcasGuardadas: Codable { var hub: Historia.Marca?; var portatil: Historia.Marca? }
    private var archivoMarcas: URL { Ajustes.carpetaEstado(id).appendingPathComponent("marcas.json") }
    private var marcasGuardadas: MarcasGuardadas? {
        get { (try? Data(contentsOf: archivoMarcas)).flatMap { try? JSONDecoder().decode(MarcasGuardadas.self, from: $0) } }
        set {
            try? FileManager.default.createDirectory(at: archivoMarcas.deletingLastPathComponent(), withIntermediateDirectories: true)
            if Notificar.prueba { print("MARCA guardada hub \(newValue?.hub?.evento ?? 0) \(newValue?.hub?.registro.prefix(8) ?? "-") · portátil \(newValue?.portatil?.evento ?? 0) \(newValue?.portatil?.registro.prefix(8) ?? "-")"); fflush(stdout) }
            if let newValue, let d = try? JSONEncoder().encode(newValue) { try? d.write(to: archivoMarcas, options: .atomic) }
            else { try? FileManager.default.removeItem(at: archivoMarcas) }
        }
    }
    /// Cuándo fue la última revisión completa que terminó bien (la de cada día, o la de cuando no se pudo saber qué cambió).
    private var ultimaCompleta: Date? {
        get { UserDefaults.standard.object(forKey: "completa-\(id)") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "completa-\(id)") }
    }
    /// La próxima revisión inteligente mira todo, sin atajos: Relevo no se cerró bien (corte de luz, Mac colgada) o un
    /// disco se fue sin expulsarlo, y el registro de cambios de macOS puede no tener lo último. Se apaga cuando una
    /// revisión de todo termina bien. Sobrevive a cerrar Relevo.
    private var revisarTodoLaProxima: Bool {
        get { UserDefaults.standard.bool(forKey: "revisar-todo-\(id)") }
        set { UserDefaults.standard.set(newValue, forKey: "revisar-todo-\(id)") }
    }
    /// Desde que se enchufa el portátil hasta que termina la revisión de lo que cambió: "Me voy" la espera.
    private var vueltaEnCurso = false
    /// Corriendo la revisión completa de fondo (la diaria): si te vas, se frena sola.
    @Published private(set) var revisandoDeFondo = false
    private var frenadaParaIrse = false

    /// Revisa solo lo que cambió en cualquiera de los dos discos desde la última copia, según el registro de cambios
    /// de macOS (`Historia`), aunque Relevo haya estado cerrado o el portátil se haya usado afuera. Si no se puede saber
    /// con seguridad (primera vez, registro borrado o perdido), revisa todo. Lo usan: enchufar el portátil, abrir
    /// Relevo, "Sincronizar ahora" y "Me voy" cuando no venía mirando.
    func sincronizarInteligente(aMano: Bool = false, alTerminar: ((Bool) -> Void)? = nil) {
        guard activo, conectados, !trabadoAlReves, let raizHub, let raizPortatil else {
            sincronizar(aMano: aMano, alTerminar: alTerminar)
            return
        }
        // La marca de ahora se toma antes de mirar: lo que cambie mientras tanto entra la próxima vez.
        let nuevas = MarcasGuardadas(hub: Historia.marca(raizHub), portatil: Historia.marca(raizPortatil))
        // Después de un corte de luz o de un disco sacado sin expulsar, el registro puede no tener lo último: todo.
        let guardadas = revisarTodoLaProxima ? nil : marcasGuardadas
        let motivoTodo = revisarTodoLaProxima ? "un corte o un disco sacado sin expulsar" : guardadas == nil ? "sin marca guardada" : nil
        let desde = Date()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var rutas: Historia.Cambios? = Historia.Cambios()
            var motivo = motivoTodo
            for (marca, raiz, lado) in [(guardadas?.hub, raizHub, "hub"), (guardadas?.portatil, raizPortatil, "portátil")] {
                guard let marca else { rutas = nil; motivo = motivo ?? "falta la marca del \(lado)"; break }
                let c = Historia.cambios(desde: marca, en: raiz)
                if Notificar.prueba {
                    print("HISTORIA \(lado) desde \(marca.evento) \(marca.registro.prefix(8)) ahora \(Historia.marca(raiz)?.registro.prefix(8) ?? "nil") → \(c.map { "\($0.carpetas.count) carpeta(s)" } ?? "no sirve")")
                    fflush(stdout)
                }
                guard let c else {
                    rutas = nil; motivo = "el registro de cambios del \(lado) no sirve"; break
                }
                rutas?.carpetas.formUnion(c.carpetas)
                rutas?.enteras.formUnion(c.enteras)
            }
            let leido = Date().timeIntervalSince(desde)
            DispatchQueue.main.async {
                guard let self else { return }
                if let motivo {
                    Bitacora.anotar(String(format: "Revisión: todos los proyectos (%@; registro leído en %.1f s)", motivo, leido))
                }
                let guardar: (Bool) -> Void = { [weak self] bien in
                    // Revisó todo lo que cambió: queda al día (la próxima vez, desde acá; "Me voy" ya puede ir rápido).
                    if bien { self?.quedoAlgo = false }
                    if bien, nuevas.hub != nil, nuevas.portatil != nil { self?.marcasGuardadas = nuevas }
                    alTerminar?(bien)
                }
                guard let rutas else {
                    if Notificar.prueba { print("REVISA todo"); fflush(stdout) }
                    self.sincronizar(aMano: aMano) { [weak self] bien in
                        if bien { self?.ultimaCompleta = Date(); self?.revisarTodoLaProxima = false }
                        guardar(bien)
                    }
                    return
                }
                var arriba = false
                // De cada proyecto, solo las carpetas donde pasó algo (el resto se da por sabido: ver `Zonas`).
                var zonas = self.zonasDe(rutas.carpetas.map { ($0, rutas.enteras.contains($0)) }, cambioArriba: &arriba)
                let todos = self.pares()
                // Si macOS pide revisar entera una carpeta madre (como Proyectos), van enteros todos los proyectos de adentro.
                for e in rutas.enteras {
                    for par in todos where [raizHub, raizPortatil].contains(where: { (raiz: String) in
                        (raiz + "/" + Coordinador.base(par)).estaDentroDe(e) }) { zonas[par] = .todo }
                }
                // Además, enteros: lo que espera tu OK (para que no se olvide) y los proyectos nuevos, borrados o
                // renombrados (si cambió la carpeta madre, los que están de un solo lado o todavía no se copiaron nunca).
                // Solo carpetas que hoy se sincronizan (no las destildadas).
                for par in self.esperas.keys where todos.contains(par) { zonas[par] = .todo }
                for par in self.paresSinCopiar(arriba: arriba) { zonas[par] = .todo }
                let pares = Set(zonas.keys)
                Bitacora.anotar(String(format: "Revisión: solo lo que cambió, %ld proyecto(s) (registro leído en %.1f s)", pares.count, leido))
                if Notificar.prueba { print("REVISA \(pares.count): \(pares.sorted().joined(separator: ", "))"); fflush(stdout) }
                if pares.isEmpty {
                    guardar(true)
                    self.recalcularEstado()
                } else {
                    self.sincronizar(pares, zonas: zonas, aMano: aMano, alTerminar: guardar)
                }
            }
        }
    }

    private func marcasDeAhora() -> MarcasGuardadas? {
        guard let raizHub, let raizPortatil, let h = Historia.marca(raizHub), let p = Historia.marca(raizPortatil) else { return nil }
        return MarcasGuardadas(hub: h, portatil: p)
    }

    /// Carpetas del par que nunca se copiaron (no tienen base: por ejemplo, recién tildadas en "Qué se sincroniza") y, si
    /// cambió una carpeta madre (`arriba`), las que están de un solo lado: proyectos nuevos, borrados o renombrados
    /// mientras Relevo no miraba.
    private func paresSinCopiar(arriba: Bool) -> Set<String> {
        guard let raizHub, let raizPortatil, let s = sincronizador() else { return [] }
        let fm = FileManager.default
        return Set(pares().filter { par in
            let base = Coordinador.base(par)
            if !fm.fileExists(atPath: s.archivoBase(par).path) { return true }
            guard arriba else { return false }
            return fm.fileExists(atPath: raizHub + "/" + base) != fm.fileExists(atPath: raizPortatil + "/" + base)
        })
    }

    /// La revisión completa de fondo: una vez por día (de madrugada, o cuando la Mac está sin usar) y un minuto después de
    /// cada vuelta con el portátil, si la última fue hace más de media hora. La de la vuelta cubre lo que el registro de
    /// cambios de macOS no ve: el portátil usado en otra Mac y lo escrito en el primer instante después de enchufarlo
    /// (macOS todavía no anota ese disco: probado el 31/10/2026, se pierde la mitad de las veces). La vuelta ya avisó
    /// "Listo"; esta corre después, sin apuro. No escribe nada si todo
    /// está igual; si te vas mientras corre, se frena sola (`frenarRevisionDeFondo`). Lo llaman el reloj de cada media
    /// hora y la vuelta del portátil.
    func revisionCompletaSiToca(alVolver: Bool = false, forzar: Bool = false) {
        guard activo, ajustes.datos.revisionDiaria, conectados, !trabadoAlReves, !corriendo, !revisandoDeFondo, !expulsandoPortatil,
              estado != .expulsando, !(vinculo?.pausado ?? false) else { return }
        let hace = ultimaCompleta.map { Date().timeIntervalSince($0) } ?? .infinity
        let hora = Calendar.current.component(.hour, from: Date())
        let toca = alVolver ? hace > 30 * 60 : hace > 20 * 3600 && ((2...5).contains(hora) || Energia.inactiva > 20 * 60)
        guard toca || forzar else { return }
        revisandoDeFondo = true
        let nuevas = [raizHub, raizPortatil].map { $0.flatMap(Historia.marca) }
        if Notificar.prueba { print("REVISION COMPLETA"); fflush(stdout) }
        sincronizar { [weak self] bien in
            guard let self else { return }
            self.revisandoDeFondo = false
            if bien {
                self.ultimaCompleta = Date()
                self.revisarTodoLaProxima = false
                if let h = nuevas[0], let p = nuevas[1] { self.marcasGuardadas = MarcasGuardadas(hub: h, portatil: p) }
            }
        }
    }

    /// Te vas (o expulsás) mientras corre la revisión completa de fondo: se frena (no escribía nada que no se pueda
    /// retomar) y `listo` sigue con lo de irse. Si no estaba corriendo, sigue de una.
    func frenarRevisionDeFondo(_ listo: @escaping () -> Void) {
        guard revisandoDeFondo, corriendo else { listo(); return }
        frenadaParaIrse = true
        alTerminar.append { _ in listo() }
        cancelador?.cancelar()
    }

    // MARK: - Sincronizar

    /// `carpetas` nil = todas. `zonas`: de qué parte de cada carpeta se sabe que cambió (las que no están, enteras).
    /// `aMano`: lo pidió el usuario (vale aunque esté en pausa).
    func sincronizar(_ carpetas: Set<String>? = nil, zonas: [String: Zonas] = [:], aMano: Bool = false,
                     alTerminar: ((Bool) -> Void)? = nil) {
        if let alTerminar { self.alTerminar.append(alTerminar) }
        guard activo, conectados, !trabadoAlReves, let s = sincronizador(), aMano || !(vinculo?.pausado ?? false) else {
            recalcularEstado()
            // Si hay otra corriendo, los avisos esperan a esa (no se les dice "mal" antes de tiempo).
            if !corriendo { terminar(false) }
            return
        }
        if corriendo {
            // Queda para después. Vacío = todo: si ya se pidió todo, un pedido parcial no lo achica.
            if pedidoGuardado?.isEmpty == true {} else if let carpetas {
                guard !carpetas.isEmpty else { return }
                var p = pedidoGuardado ?? [:]
                for c in carpetas { p[c, default: Zonas()].unir(zonas[c] ?? .todo) }
                pedidoGuardado = p
            } else { pedidoGuardado = [:] }
            return
        }
        corriendo = true
        listoParaIrse = false
        poner(.revisando)
        let todas = pares()
        // Solo carpetas que hoy se sincronizan: una destildada (u omitida) no se toca aunque se haya pedido.
        let lista = carpetas.map { pedidas in todas.filter { pedidas.contains($0) } } ?? todas
        let c = Cancelador()
        cancelador = c
        let diasPapelera = ajustes.datos.diasPapelera
        let limpiar = ultimaLimpieza.map { Date().timeIntervalSince($0) > 6 * 3600 } ?? true
        if limpiar { ultimaLimpieza = Date() }
        let raices = [s.volumenHub, s.volumenPortatil]
        let identidad = datosIdentidad
        // En la bitácora va el detalle de la vuelta al llegar y de las revisiones de todo; de la copia en vivo, solo lo lento.
        let detallar = llegando || vueltaEnCurso || carpetas == nil

        cola.async { [weak self] in
            guard let self else { return }
            if self.identidadDudosa(identidad.uuid, conClave: identidad.conClave) {
                DispatchQueue.main.async {
                    self.terminoVuelta(pedidos: [], analizadas: [], completas: false, bien: false, alDia: false, enUso: [:])
                }
                return
            }
            if limpiar {
                let desde = Date()
                Papelera.limpiar(raices, dias: diasPapelera)
                Bitacora.anotar(String(format: "Papelera de Relevo limpiada en %.1f s", Date().timeIntervalSince(desde)))
            }
            let vueltaDesde = Date()
            var nuevosPedidos: [PedidoOK] = []
            var analizadas = Set<String>()
            var todoBien = true
            // Quedó algo atrás de verdad (no solo archivos que cambiaban mientras se copiaban: ver `quedoAlgo`).
            var algoAtras = false
            // Archivos que cambiaban mientras se copiaban, por carpeta: "Me voy" los vuelve a intentar enseguida.
            var enUso: [String: Zonas] = [:]
            var ultimoAviso = Date.distantPast
            for carpeta in lista {
                if c.cancelado { todoBien = false; algoAtras = true; break }
                // Cada carpeta suelta su memoria al terminar (las grandes pueden tener cientos de miles de archivos).
                let seguir: Bool = autoreleasepool {
                    do {
                        let desde = Date()
                        let a = try s.analizar(carpeta, zonas: zonas[carpeta])
                        analizadas.insert(carpeta)
                        defer {
                            // Solo lo que tardó o movió algo (si no, la bitácora se llena de renglones iguales).
                            let total = Date().timeIntervalSince(desde)
                            if detallar && (total >= 0.5 || !a.plan.vacio) || total >= 2 {
                                Bitacora.anotar(String(format: "  %@: %.1f s (%@)", carpeta, total, a.porZonas ? "solo lo que cambió" : "entera"))
                            }
                        }
                        if Notificar.prueba {
                            print(String(format: "ANALISIS %@ %@ %.2f s", carpeta, a.porZonas ? "zonas" : "entera", a.duracion))
                            fflush(stdout)
                        }
                        if a.requiereOK {
                            // Un repo con commits distintos cuenta como algo nuevo: nunca se aplica solo ni deja irse
                            // como si no faltara nada.
                            let pedido = PedidoOK(a)
                            nuevosPedidos.append(pedido)
                            // Solo borrados esperando tu OK: no queda nada sin copiar (ver `terminoVuelta`).
                            if !pedido.noFrena { todoBien = false; algoAtras = true }
                            return true
                        }
                        if a.plan.vacio && !a.plan.soloAnotar {
                            // Nada que copiar, pero quizás números de carpeta nuevos: así la próxima no entra.
                            if a.baseActualizada { try? s.guardarBase(a) }
                            return true
                        }
                        if !a.plan.vacio {
                            DispatchQueue.main.async { self.avance = Avance(carpeta: carpeta); self.poner(.copiando) }
                        }
                        let r = s.ejecutar(a, cancelador: c) { p in
                            guard Date().timeIntervalSince(ultimoAviso) > 0.25 else { return }
                            ultimoAviso = Date()
                            DispatchQueue.main.async {
                                self.avance = Avance(carpeta: carpeta, hechos: p.hechos, total: p.total,
                                                     bytesHechos: p.bytesHechos, bytesTotal: p.bytesTotal)
                            }
                        }
                        if !a.plan.vacio { self.registrar(carpeta, a, r) }
                        if !r.completo { todoBien = false }
                        if !r.completoSalvoEnUso { algoAtras = true }
                        if !r.enUso.isEmpty {
                            enUso[carpeta] = Zonas(planas: Set(r.enUso.map { ($0 as NSString).deletingLastPathComponent }))
                        }
                        if r.desconectado != nil || r.cancelado { return false }
                    } catch {
                        todoBien = false
                        algoAtras = true
                        // Si se fue un disco, no tiene sentido seguir con las otras carpetas.
                        if access(s.volumenHub, F_OK) != 0 || access(s.volumenPortatil, F_OK) != 0 { return false }
                    }
                    return true
                }
                if !seguir { break }
            }
            let duro = Date().timeIntervalSince(vueltaDesde)
            if detallar || duro >= 2 { Bitacora.anotar(String(format: "Vuelta de %ld carpeta(s) en %.1f s", analizadas.count, duro)) }
            // Lo que se usó para revisar vuelve al sistema (si no, la app queda "ocupando" lo del pico).
            malloc_zone_pressure_relief(nil, 0)
            DispatchQueue.main.async {
                self.terminoVuelta(pedidos: nuevosPedidos, analizadas: analizadas, completas: carpetas == nil && !c.cancelado,
                                   bien: todoBien, alDia: !algoAtras, enUso: enUso)
            }
        }
    }

    /// `bien`: no quedó nada sin copiar. `alDia`: lo mismo, salvo archivos que cambiaban mientras se copiaban (`enUso`,
    /// por carpeta), que entran solos en la próxima pasada.
    private func terminoVuelta(pedidos nuevos: [PedidoOK], analizadas: Set<String>, completas: Bool, bien: Bool,
                               alDia: Bool, enUso: [String: Zonas]) {
        corriendo = false
        cancelador = nil
        enUsoPendiente = enUsoPendiente.filter { !analizadas.contains($0.key) }.merging(enUso) { $1 }
        // Solo cambian los pedidos de las carpetas que se revisaron (si se cortó a mitad, los otros siguen).
        pedidos = pedidos.filter { !analizadas.contains($0.carpeta) } + nuevos
        if Notificar.prueba { for p in nuevos { print("PEDIDO \(p.carpeta): \(p.explicacion)") }; fflush(stdout) }
        anotarEsperas(analizadas: analizadas)
        if let raizHub, let raizPortatil {
            Historial.shared.olvidarConflictosSinOtraVersion(vinculo: id, raizHub: raizHub, raizPortatil: raizPortatil)
        }
        if bien || !nuevos.isEmpty {
            ultima = Date()
            UserDefaults.standard.set(ultima, forKey: "ultima-\(id)")
        }
        if !nuevos.isEmpty { Notificar.enviar(T("Relevo necesita tu OK"), nuevos.map(\.carpeta).joined(separator: ", ")) }
        if completas {
            revisarEspacio()
            revisarClaves()
        }
        avance = Avance()
        recalcularEstado()
        if let p = pedidoGuardado {
            pedidoGuardado = nil
            sincronizar(p.isEmpty ? nil : Set(p.keys), zonas: p, aMano: true)
            return
        }
        // Bien = no quedó nada sin copiar. Un borrado esperando tu OK no cuenta: lo de más sigue en el otro disco y
        // no falta nada (así "Me voy" no se traba por eso).
        if frenadaParaIrse { frenadaParaIrse = false } else {
            // Un archivo que cambiaba mientras se copiaba no cuenta: si no, una base de datos o un editor que guarda
            // seguido hacían que "Me voy" y "Expulsar" revisaran todo en vez de copiar solo lo pendiente.
            quedoAlgo = !(alDia && pedidos.allSatisfy(\.noFrena)) || (quedoAlgo && !completas)
            cadenaBien = cadenaBien && bien
        }
        // Lo que esperaba ("Me voy", la revisión de fondo…) recibe "bien" solo si toda la cadena salió bien.
        let todoBien = cadenaBien && pedidos.allSatisfy(\.noFrena)
        cadenaBien = true
        terminar(todoBien)
    }

    private func terminar(_ bien: Bool) {
        let l = alTerminar
        alTerminar = []
        l.forEach { $0(bien) }
    }

    private func registrar(_ carpeta: String, _ a: Analisis, _ r: Resultado) {
        let res = a.plan.resumen
        var problemas = r.problemas.map { "\($0.ruta): \($0.detalle)" }
        if !r.enUso.isEmpty { problemas.append(T("%ld archivo(s) cambiaban mientras se copiaban: van en la próxima.", r.enUso.count)) }
        let distintos = res.reposDistintos.map { $0.isEmpty ? carpeta : carpeta + "/" + $0 }
        for repo in distintos {
            problemas.append(T("%@: commits distintos en los dos discos. Su carpeta .git no se tocó; unilos con git.", repo))
        }
        let m = Movimiento(fecha: Date(), carpeta: carpeta, haciaPortatil: res.haciaPortatil, haciaHub: res.haciaHub,
                           bytes: r.bytes, aPapelera: r.aPapelera, conflictos: r.conflictos, recuperados: res.recuperados,
                           repos: res.reposEnLosDosLados, problemas: problemas, desconectado: r.desconectado?.nombre,
                           duracion: r.duracion, vinculo: id, cambios: r.cambios, cambiosTotales: r.cambiosTotales,
                           sello: r.sello)
        DispatchQueue.main.async {
            Historial.shared.agregar(m)
            if self.resumenVuelta != nil, res.haciaHub > 0 { self.resumenVuelta?[carpeta, default: 0] += res.haciaHub }
            if let d = r.desconectado {
                self.aviso = T("Se desconectó el %@ a mitad de %@. Lo hecho quedó bien; al volver a enchufarlo sigo donde quedé.", T(d.nombre), carpeta)
            } else if !r.conflictos.isEmpty {
                self.aviso = T("En %@ cambiaste lo mismo en los dos lados: guardé las dos versiones. Elegí cuál queda en Historial › Dos versiones.", carpeta)
            } else if let nuevo = distintos.first(where: { !self.reposAvisados.contains($0) }) {
                // Una vez por proyecto mientras Relevo esté abierto (se vuelve a ver en cada vuelta hasta que se unan).
                self.reposAvisados.formUnion(distintos)
                self.aviso = T("%@ tiene commits distintos en el disco de casa y en el portátil. Para no mezclar las dos historias no copié su carpeta .git (el resto del proyecto, sí). Unilos con git: hacé commit y push de un lado y pull del otro.", nuevo)
                Notificar.enviar(T("Commits distintos en %@", (nuevo as NSString).lastPathComponent),
                                 T("No copié su .git para no mezclar las historias. Unilos con git (push de un lado, pull del otro)."))
            }
            // Cambios internos de git en los dos discos sin commits distintos (`reposEnLosDosLados`) no se avisan: casi
            // siempre es el índice, que git reescribe solo con cada `git status` de un editor, y no se pierde nada (la
            // versión que no quedó está en la papelera y figura en el historial). Lo que sí importa, commits distintos,
            // tiene su aviso arriba. Antes salía "Trabajaste … en los dos lados" sin que hubiera nada que hacer (30/10/2026).
        }
    }

    // MARK: - Acciones

    /// "Sí, seguir" de un pedido. Si hay una copia corriendo (con la copia en vivo pasa seguido), queda anotado y se
    /// hace apenas termine; antes el botón no hacía nada. Lo llama Inicio.
    func confirmar(_ pedido: PedidoOK) {
        guard activo else { return }
        guard let s = sincronizador() else { aviso = T("Para eso tienen que estar conectados los dos discos."); return }
        if corriendo {
            aviso = T("Lo hago apenas termine la copia que está corriendo.")
            alTerminar.append { [weak self] _ in self?.confirmar(pedido) }
            return
        }
        corriendo = true
        poner(.copiando)
        avance = Avance(carpeta: pedido.carpeta)
        let c = Cancelador()
        cancelador = c
        let identidad = datosIdentidad
        cola.async { [weak self] in
            guard let self else { return }
            var bien = false, revisada = false
            var cambiado: PedidoOK?
            if self.identidadDudosa(identidad.uuid, conClave: identidad.conClave) { c.cancelar() }
            // Solo se confirma lo que se vio: si apareció algo nuevo, no se ejecuta y se vuelve a preguntar con lo de ahora.
            if !c.cancelado, let a = try? s.analizar(pedido.carpeta) {
                revisada = true
                if pedido.autoriza(a.alertas) {
                    let r = s.ejecutar(a, confirmado: true, cancelador: c)
                    if !a.plan.vacio { self.registrar(pedido.carpeta, a, r) }
                    bien = r.completo
                } else {
                    cambiado = PedidoOK(a)
                }
            }
            DispatchQueue.main.async {
                self.corriendo = false
                if bien { self.pedidos.removeAll { $0.carpeta == pedido.carpeta }; self.esperas[pedido.carpeta] = nil }
                self.avisarSiNoSeHizo(pedido.carpeta, revisada: revisada, bien: bien, cambiado: cambiado, cancelado: c.cancelado)
                self.avance = Avance()
                self.recalcularEstado()
                self.seguirConLoPendiente(bien)
            }
        }
    }

    /// Después de un "Sí, seguir" que no se pudo hacer, dice por qué (nunca un botón que no hace nada) y, si el pedido
    /// cambió, lo muestra con lo de ahora. Lo usan `confirmar` y `confirmarTodos`.
    private func avisarSiNoSeHizo(_ carpeta: String, revisada: Bool, bien: Bool, cambiado: PedidoOK?, cancelado: Bool) {
        if let cambiado {
            if let i = pedidos.firstIndex(where: { $0.carpeta == carpeta }) { pedidos[i] = cambiado } else { pedidos.append(cambiado) }
            aviso = T("%@ cambió desde que lo viste. Fijate de nuevo y confirmá.", carpeta)
        } else if bien || cancelado {
            return
        } else if !revisada {
            aviso = T("No pude revisar %@ ahora. Probá de nuevo en un rato.", carpeta)
        } else {
            aviso = T("En %@ quedó algo sin hacer (mirá el historial). Lo vuelvo a intentar en la próxima copia.", carpeta)
        }
    }

    /// "Sí, seguir con todas": confirma de una vez todos los pedidos que se pueden seguir (no los que no entran).
    func confirmarTodos(_ solo: [PedidoOK]? = nil, alTerminar listo: ((_ hechas: [String]) -> Void)? = nil) {
        guard activo else { return }
        guard let s = sincronizador() else {
            if solo == nil { aviso = T("Para eso tienen que estar conectados los dos discos.") }
            return
        }
        let lista = (solo ?? pedidos).filter(\.sePuedeSeguir)
        guard !lista.isEmpty else { return }
        // Igual que `confirmar`: con una copia corriendo, queda anotado (lo de "aplicar solo" se reintenta en su reloj).
        if corriendo {
            guard solo == nil else { return }
            aviso = T("Lo hago apenas termine la copia que está corriendo.")
            self.alTerminar.append { [weak self] _ in self?.confirmarTodos() }
            return
        }
        corriendo = true
        poner(.copiando)
        let c = Cancelador()
        cancelador = c
        let identidad = datosIdentidad
        cola.async { [weak self] in
            guard let self else { return }
            var hechas: [String] = []
            var cambiados: [PedidoOK] = []
            if self.identidadDudosa(identidad.uuid, conClave: identidad.conClave) { c.cancelar() }
            for pedido in lista where !c.cancelado {
                DispatchQueue.main.async { self.avance = Avance(carpeta: pedido.carpeta) }
                guard let a = try? s.analizar(pedido.carpeta) else { continue }
                guard pedido.autoriza(a.alertas) else { cambiados.append(PedidoOK(a)); continue }
                let r = s.ejecutar(a, confirmado: true, cancelador: c)
                if !a.plan.vacio { self.registrar(pedido.carpeta, a, r) }
                if r.completo { hechas.append(pedido.carpeta) }
            }
            DispatchQueue.main.async {
                self.corriendo = false
                self.pedidos.removeAll { hechas.contains($0.carpeta) }
                for p in cambiados { self.avisarSiNoSeHizo(p.carpeta, revisada: true, bien: false, cambiado: p, cancelado: false) }
                if solo == nil, cambiados.isEmpty, hechas.count < lista.count, !c.cancelado {
                    self.aviso = T("Hice %ld de %ld. Lo que falta sigue arriba; mirá el historial.", hechas.count, lista.count)
                }
                self.esperas = self.esperas.filter { k, _ in !hechas.contains(k) }
                self.avance = Avance()
                self.recalcularEstado()
                listo?(hechas)
                self.seguirConLoPendiente(hechas.count == lista.count)
            }
        }
    }

    /// Al terminar algo que ocupó la cola (confirmar pedidos): si mientras tanto se pidió copiar algo, se hace ahora;
    /// si no, se avisa a quien esperaba ("Me voy", "Expulsar").
    private func seguirConLoPendiente(_ bien: Bool) {
        if let p = pedidoGuardado {
            pedidoGuardado = nil
            sincronizar(p.isEmpty ? nil : Set(p.keys), zonas: p, aMano: true)
        } else {
            terminar(bien)
        }
    }

    // MARK: - Borrados que se aplican solos

    private var claveEsperas: String { "pedidos-desde-\(id)" }

    /// Desde cuándo espera tu OK cada carpeta (sobrevive a "Ahora no" y a cerrar Relevo).
    private var esperas: [String: Date] {
        get { (UserDefaults.standard.dictionary(forKey: claveEsperas) as? [String: Date]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: claveEsperas) }
    }

    /// Cómo era el pedido cuando empezó a esperar (si cambia, el plazo vuelve a empezar).
    private var firmas: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: "pedidos-firma-\(id)") as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "pedidos-firma-\(id)") }
    }
    private static func firma(_ p: PedidoOK) -> String { "\(p.alertas)|\(p.copiasPendientes)" }

    /// Cuándo se aplica solo un pedido (nil si no se aplica solo: lo que no entra, o si además hay algo nuevo para copiar).
    func aplicaSolo(_ p: PedidoOK) -> Date? {
        guard p.noFrena, let desde = esperas[p.carpeta], firmas[p.carpeta] == Self.firma(p) else { return nil }
        return desde.addingTimeInterval(Self.segundosParaAplicar)
    }

    /// Lo llama `terminoVuelta`: anota los pedidos nuevos, olvida los que ya no están (si se revisó todo) y aplica
    /// los vencidos.
    private func anotarEsperas(analizadas: Set<String>) {
        var e = esperas, f = firmas
        for p in pedidos where p.soloBorrados {
            // Si el pedido cambió (por ejemplo, ahora hay archivos nuevos), el plazo vuelve a empezar.
            let firma = Self.firma(p)
            if e[p.carpeta] == nil || f[p.carpeta] != firma { e[p.carpeta] = Date(); f[p.carpeta] = firma }
        }
        // Carpetas revisadas que ya no piden nada, o que ya no se sincronizan: se olvidan.
        let vigentes = Set(pares())
        e = e.filter { k, _ in vigentes.contains(k) && (!analizadas.contains(k) || pedidos.contains { $0.carpeta == k }) }
        f = f.filter { k, _ in e[k] != nil }
        esperas = e
        firmas = f
        DispatchQueue.main.async { [weak self] in self?.aplicarVencidos() }
    }

    /// Los borrados que esperaron más de `diasParaAplicar` días se aplican solos (van a la papelera de Relevo).
    /// Si alguno se ocultó con "Ahora no", se vuelve a revisar esa carpeta y se aplica al terminar. Lo llama
    /// `anotarEsperas` y el reloj de cada media hora.
    func aplicarVencidos() {
        // Igual que cualquier copia automática: no en pausa, ni con los discos al revés, ni mientras se expulsa.
        guard activo, conectados, !corriendo, !(vinculo?.pausado ?? false), !trabadoAlReves, !expulsandoPortatil else { return }
        let ahora = Date()
        let vencidos = pedidos.filter { aplicaSolo($0).map { $0 <= ahora } ?? false }
        if !vencidos.isEmpty {
            confirmarTodos(vencidos) { [weak self] hechas in
                guard let self, !hechas.isEmpty else { return }
                let lista = hechas.joined(separator: ", ")
                Notificar.enviar(T("Apliqué los borrados pendientes"),
                                 T("Pasaron %ld días sin respuesta: %@. Lo borrado está en la papelera de Relevo.", Self.diasParaAplicar, lista))
                self.aviso = T("Pasaron %ld días sin respuesta y apliqué los borrados de %@. Lo borrado está en la papelera de Relevo (lo recuperás desde Historial).", Self.diasParaAplicar, lista)
            }
            return
        }
        // Vencidos que no están en pantalla (se tocó "Ahora no"): se revisan de nuevo esas carpetas.
        let ocultos = esperas.filter { k, d in d.addingTimeInterval(Self.segundosParaAplicar) <= ahora
                                         && !pedidos.contains { $0.carpeta == k } }.map(\.key)
        if !ocultos.isEmpty {
            sincronizar(Set(ocultos)) { [weak self] _ in
                // Si ya no hace falta el OK (por ejemplo, la carpeta tampoco está del otro lado), se olvida.
                guard let self else { return }
                self.esperas = self.esperas.filter { k, _ in !ocultos.contains(k) || self.pedidos.contains { $0.carpeta == k } }
            }
        }
    }

    /// "Ahora no" para todos: no se toca nada; vuelven a preguntarse en la próxima sincronización.
    func ahoraNoTodos() {
        pedidos.removeAll()
        recalcularEstado()
    }

    func ahoraNo(_ pedido: PedidoOK) {
        pedidos.removeAll { $0.carpeta == pedido.carpeta }
        recalcularEstado()
    }

    func cancelar() { cancelador?.cancelar(); revisionAFondo?.cancelador.cancelar() }

    /// Sin copias automáticas hasta esa fecha (nil = reanudar).
    func pausar(hasta: Date?) {
        ajustes.cambiar(id) { $0.pausadoHasta = hasta }
        if hasta == nil { sincronizar(aMano: true) } else { cancelador?.cancelar(); vigia.detener() }
        recalcularEstado()
        vigilar()
    }

    /// La parte de este vínculo en "Me voy" (lo arranca `Gestor.meVoy`, que después expulsa todos los discos juntos):
    /// copia lo último y llama a `listo` con `bien` (se puede expulsar) y, si hay, la nota de git. No expulsa nada.
    /// Si algo necesita tu OK o quedó sin copiar, lo dice en `aviso` y devuelve `bien` = false.
    func prepararseParaIrse(_ listo: @escaping (_ bien: Bool, _ nota: String?) -> Void) {
        guard let p = portatil, !p.esEstaMac else { listo(true, nil); return }
        aviso = nil
        if revisionAFondo?.automatica == true { revisionAFondo?.cancelador.cancelar() }
        frenarRevisionDeFondo { [weak self] in
            guard let self else { listo(false, nil); return }
            self.meVoyYa(listo: listo)
        }
    }

    /// `intento`: cuántas veces se volvió a probar porque un archivo cambiaba mientras se copiaba (ver `seguir`).
    private func meVoyYa(intento: Int = 0, listo: @escaping (_ bien: Bool, _ nota: String?) -> Void) {
        if trabadoAlReves {
            aviso = T("Los discos quedaron al revés: tocá “Acomodar” y después “Me voy”.")
            listo(false, nil)
            return
        }
        // Afuera (sin el hub) no hay nada que copiar: solo se mira git.
        if hub == nil || raizHub == nil { revisarGit { nota in listo(true, nota) }; return }
        let seguir: (Bool) -> Void = { [weak self] bien in
            guard let self else { listo(false, nil); return }
            // Lo que no entra en el portátil sí frena (afuera te faltaría). Los borrados pendientes no: quedan esperando
            // tu OK (o se aplican solos) y no se pierde nada.
            if !self.pedidos.allSatisfy(\.noFrena) {
                self.aviso = T("Antes de irte, fijate lo que necesita tu OK.")
                listo(false, nil)
                return
            }
            if !bien {
                // Solo archivos que cambiaban justo mientras se copiaban: se prueban de nuevo enseguida, solos.
                if !self.quedoAlgo, !self.enUsoPendiente.isEmpty {
                    if intento < 3 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            guard let self else { listo(false, nil); return }
                            self.meVoyYa(intento: intento + 1, listo: listo)
                        }
                    } else {
                        let donde = self.enUsoPendiente.keys.sorted().joined(separator: ", ")
                        self.aviso = T("Hay archivos que no paran de cambiar en %@. Cerrá lo que los está usando y tocá “Me voy” de nuevo.", donde)
                        listo(false, nil)
                    }
                    return
                }
                self.aviso = T("Quedó algo sin copiar (mirá el historial). Probá de nuevo antes de irte.")
                listo(false, nil)
                return
            }
            self.revisarGit { nota in listo(true, nota) }
        }
        // Con la copia en vivo andando desde la última revisión completa, casi todo ya está en el portátil: solo se
        // copia lo pendiente (segundos). Si no estaba mirando (copia en vivo apagada o recién conectado), revisa todo.
        if ajustes.datos.enVivo, vigia.activo, ultima != nil, !vueltaPendiente, !vueltaEnCurso, !quedoAlgo {
            // Lo que se copia ahora deja la marca al día: al volver, solo se revisa lo que hagas afuera.
            let nuevas = marcasDeAhora()
            let conMarca: (Bool) -> Void = { [weak self] bien in
                if bien, let nuevas { self?.marcasGuardadas = nuevas }
                seguir(bien)
            }
            // Lo que guardaste hace un segundo todavía puede no haber llegado: se pide ya y se espera un instante.
            vigia.vaciar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                // Los que cambiaban mientras se copiaban en la última pasada van sí o sí.
                for (carpeta, z) in self.enUsoPendiente { self.sucias[carpeta, default: Zonas()].unir(z) }
                if self.copiarSucias(aMano: true, alTerminar: conMarca) {}
                else if self.corriendo { self.alTerminar.append(conMarca) }
                else { conMarca(true) }
            }
        } else {
            sincronizarInteligente(aMano: true, alTerminar: seguir)
        }
    }

    /// Los discos quedaron al revés (el portátil le ganó el nombre al hub): se arregla cambiando nombres, sin
    /// desmontar nada. Lo usa el botón "Acomodar"; normalmente `acomodarNombres` lo hace solo.
    func acomodar() {
        guard activo, let h = hub, portatil != nil, let v = vinculo, Vinculo.discosEnteros(v.hub, v.portatil) else { return }
        if v.nombreAfuera == nil { ajustes.cambiar(id) { $0.nombreAfuera = h.nombre } }
        nombresTrabados = false
        forzarNombres = true   // lo pediste vos: aunque el portátil esté en uso
        discosCambiaron()
    }

    // MARK: - Revisar a fondo

    /// Compara el contenido de todo (no solo fecha y tamaño). Lento: es para hacerlo de vez en cuando.
    func revisarAFondo(automatica: Bool = false) {
        guard activo, let s = sincronizador(), !corriendo, revisionAFondo == nil else { return }
        let revision = RevisionAFondo()
        revision.automatica = automatica
        revisionAFondo = revision
        let lista = pares()
        cola.async { [weak self] in
            var distintos: [(String, String)] = []
            for (i, carpeta) in lista.enumerated() {
                if revision.cancelador.cancelado { break }
                DispatchQueue.main.async { revision.carpeta = carpeta; revision.fraccionCarpetas = Double(i) / Double(max(1, lista.count)) }
                let d = (try? s.revisarAFondo(carpeta, cancelador: revision.cancelador)) ?? []
                distintos += d.map { (carpeta, $0) }
            }
            DispatchQueue.main.async {
                revision.terminada = true
                revision.distintos = distintos.map { RevisionAFondo.Diferencia(carpeta: $0.0, ruta: $0.1) }
                revision.fraccionCarpetas = 1
                if !revision.cancelador.cancelado { UserDefaults.standard.set(Date(), forKey: "revision-\(self?.id ?? "")") }
                if automatica {
                    if revision.distintos.isEmpty { self?.revisionAFondo = nil } else {
                        let n = revision.distintos.count
                        self?.aviso = T("La revisión mensual encontró %ld archivo(s) que no coinciden. Repará desde Discos.", n)
                        Notificar.enviar(T("Revisión a fondo"), T("%ld archivo(s) no coinciden entre los dos discos.", n))
                    }
                }
                self?.objectWillChange.send()
            }
        }
    }

    /// Repara lo que encontró la revisión copiando desde el hub (lo del portátil queda en su papelera).
    func repararDesdeHub() {
        // No mientras corre una copia: escribirían la misma base a la vez.
        guard !corriendo, let r = revisionAFondo, let s = sincronizador() else { return }
        for (carpeta, rutas) in Dictionary(grouping: r.distintos, by: \.carpeta) {
            try? s.forzarCopia(carpeta, rutas: rutas.map(\.ruta), desde: .hub)
        }
        revisionAFondo = nil
        sincronizar(aMano: true)
    }

    func cerrarRevision() { revisionAFondo = nil }

    var ultimaRevisionAFondo: Date? { UserDefaults.standard.object(forKey: "revision-\(id)") as? Date }
}

extension Coordinador {
    // MARK: - Antes de dormir

    /// Copia ya lo que estaba esperando (la copia en vivo espera unos segundos a que dejes de guardar) y avisa al
    /// terminar. Se usa antes de que la Mac se duerma y antes de expulsar discos.
    func copiarPendiente(_ listo: @escaping () -> Void, vaciado: Bool = false) {
        guard conectados, !trabadoAlReves else { listo(); return }
        if revisionAFondo?.automatica == true { revisionAFondo?.cancelador.cancelar() }
        if revisandoDeFondo { frenarRevisionDeFondo { [weak self] in self?.copiarPendiente(listo) }; return }
        // Recién enchufado o con algo sin copiar: primero lo que cambió (no solo lo que vio la copia en vivo).
        if vueltaEnCurso || quedoAlgo || !vigia.activo { sincronizarInteligente(aMano: true) { _ in listo() }; return }
        // Con la copia en vivo al día, lo que se copia ahora deja la marca: al volver, solo se revisa lo de afuera.
        let nuevas = marcasDeAhora()
        let listoOriginal = listo
        let listo: () -> Void = { [weak self] in
            if let self, let nuevas, !self.quedoAlgo { self.marcasGuardadas = nuevas }
            listoOriginal()
        }
        // Lo que guardaste hace un segundo todavía puede no haber llegado: se pide ya y se sigue en un instante.
        if !vaciado {
            vigia.vaciar()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.copiarPendiente(listoOriginal, vaciado: true) }
            return
        }
        // Los que cambiaban mientras se copiaban en la última pasada van sí o sí.
        for (carpeta, z) in enUsoPendiente { sucias[carpeta, default: Zonas()].unir(z) }
        if copiarSucias(aMano: true, alTerminar: { _ in listo() }) {
        } else if corriendo {
            alTerminar.append { _ in listo() }
        } else if !ajustes.datos.enVivo {
            sincronizarInteligente(aMano: true) { _ in listo() }
        } else {
            listo()
        }
    }

    /// Para "Expulsar discos": que el portátil se tome como expulsado bien (lo recién copiado ya quedó guardado).
    /// "Me voy" terminó y el portátil salió: Inicio y el menú dicen que ya se puede desenchufar. Lo llama `Gestor.expulsar`.
    func quedoListoParaIrse() { listoParaIrse = true }

    func vaASerExpulsado(_ v: Volumen) {
        vigia.detener()
        expulsandoPortatil = true
        desmontesPedidos[v.ruta] = Date()
        if let n = vinculo?.nombreAfuera { desmontesPedidos["/Volumes/" + n] = Date(); desmontesPedidos["/Volumes/" + n + " 1"] = Date() }
    }

    // MARK: - Papelera

    /// Las carpetas raíz conectadas de este vínculo: su papelera está en `<raíz>/.Relevo/Papelera` (la misma que limpia
    /// `sincronizar` por días). Las usa "Vaciar ahora" en General para mostrar cuánto ocupa y para vaciarla.
    var raicesConPapelera: [String] { [raizHub, portatil == nil ? nil : raizPortatil].compactMap { $0 } }

    /// "Vaciar ahora" (General): borra todo lo guardado en la papelera de Relevo de los discos conectados. Va por la
    /// misma cola que las copias, así nunca borra mientras una copia está guardando ahí la versión vieja de algo.
    /// Tus archivos no se tocan: solo lo borrado y las versiones anteriores. `listo` vuelve en el hilo principal.
    func vaciarPapeleras(listo: @escaping () -> Void) {
        let raices = raicesConPapelera
        cola.async {
            // Cero días: todo lo anterior a este momento (cada pasada guarda en una carpeta con su fecha y hora).
            Papelera.limpiar(raices, dias: 0)
            DispatchQueue.main.async { listo() }
        }
    }

    // MARK: - Avisos

    private func avisarVuelta(_ r: [String: Int]) {
        let total = r.values.reduce(0, +)
        guard total > 0 else { return }
        let detalle = r.sorted { $0.value > $1.value }.prefix(3).map { "\($0.value) " + T("en") + " \($0.key)" }.joined(separator: ", ")
        aviso = T("Traje %ld cambio(s) de afuera: %@.", total, detalle)
        // Si ya avisó "Esperá", esto va en el "Listo" de la llegada (un solo aviso en vez de dos seguidos).
        if llegando, llegadaAvisada { traidoEnLlegada = aviso; return }
        Notificar.enviar(T("Bienvenido de vuelta"), T("Traje %ld cambio(s) de afuera: %@.", total, detalle))
    }

    /// Avisa una vez por día si a algún lado le queda poco lugar.
    func revisarEspacio() {
        guard activo else { return }
        for (v, nombre) in [(portatil.flatMap { Discos.buscar($0.uuid) }, T("portátil")), (hub.flatMap { $0.esEstaMac ? nil : Discos.buscar($0.uuid) }, T("disco de casa"))] {
            guard let v, v.capacidad > 0 else { continue }
            let poco = v.libre < max(5 << 30, v.capacidad / 20)
            let clave = "espacio-\(id)-\(v.uuid)"
            let ultimo = UserDefaults.standard.object(forKey: clave) as? Date ?? .distantPast
            guard poco, Date().timeIntervalSince(ultimo) > 86400 else { continue }
            UserDefaults.standard.set(Date(), forKey: clave)
            aviso = T("Al %@ le queda poco lugar: %@ libres. Liberá espacio o sacá carpetas de “Qué se sincroniza”.", nombre, Formato.bytes(v.libre))
            Notificar.enviar(T("Poco lugar en el %@", nombre), T("Quedan %@ libres en %@.", Formato.bytes(v.libre), v.nombre))
        }
    }

    /// Proyectos con claves (.env) viajando en un portátil sin cifrar.
    func revisarClaves() {
        guard activo, let raizHub, let p = portatil, !p.esEstaMac,
              !UserDefaults.standard.bool(forKey: "noAvisarClaves-\(id)") else { clavesSinCifrar = 0; return }
        let lista = pares()
        cola.async { [weak self] in
            let n = Revisar.proyectosConClaves(raiz: raizHub, pares: lista)
            let cifrado = Cifrado.estado(uuid: p.uuid)
            DispatchQueue.main.async { self?.clavesSinCifrar = (cifrado == .sinCifrar) ? n : 0 }
        }
    }

    func noAvisarClaves() {
        UserDefaults.standard.set(true, forKey: "noAvisarClaves-\(id)")
        clavesSinCifrar = 0
    }

    /// Afuera (sin el hub): qué proyectos llegaron sin dependencias.
    private func revisarAfuera() {
        guard activo, raizHub == nil, let raiz = raizPortatil else { faltanDependencias = []; return }
        let lista = pares()
        cola.async { [weak self] in
            let f = Revisar.dependenciasFaltantes(raiz: raiz, pares: lista)
            DispatchQueue.main.async { self?.faltanDependencias = f }
        }
    }

    /// Antes de irte: proyectos con cambios sin commit o sin subir (avisa, no frena).
    func revisarGit(_ listo: @escaping (String?) -> Void) {
        guard let raiz = raizHub ?? raizPortatil, Git.ruta != nil else { listo(nil); return }
        let lista = pares().filter { !$0.hasSuffix("/.") }
        cola.async {
            var partes: [String] = []
            for par in lista {
                guard let p = Git.pendientes(raiz + "/" + par), p.sinCommit + p.sinSubir > 0 else { continue }
                let nombre = (par as NSString).lastPathComponent
                var cosas: [String] = []
                if p.sinCommit > 0 { cosas.append(T("%ld sin commit", p.sinCommit)) }
                if p.sinSubir > 0 { cosas.append(T("%ld sin subir", p.sinSubir)) }
                partes.append("\(nombre) (\(cosas.joined(separator: ", ")))")
            }
            let nota = partes.isEmpty ? nil : T("Ojo con git: %@.", partes.prefix(6).joined(separator: "; ") + (partes.count > 6 ? "…" : ""))
            DispatchQueue.main.async { listo(nota) }
        }
    }

    // MARK: - Revisión mensual

    /// Una vez por mes, si la Mac está enchufada, con los dos discos y sin usar hace 15 minutos.
    func revisionMensualSiToca() {
        guard activo, ajustes.datos.revisionMensual, conectados, !corriendo, revisionAFondo == nil,
              Energia.enchufada, Energia.inactiva > 15 * 60 else { return }
        let desde = ultimaRevisionAFondo ?? (UserDefaults.standard.object(forKey: "alta-\(id)") as? Date ?? Date())
        guard Date().timeIntervalSince(desde) > 30 * 86400 else { return }
        revisarAFondo(automatica: true)
    }
}

/// Estado de una revisión a fondo en curso o terminada.
final class RevisionAFondo: ObservableObject {
    struct Diferencia: Identifiable { let carpeta: String; let ruta: String; var id: String { carpeta + "/" + ruta } }
    let cancelador = Cancelador()
    var automatica = false
    @Published var carpeta = ""
    @Published var fraccionCarpetas = 0.0
    @Published var terminada = false
    @Published var distintos: [Diferencia] = []
}

/// Junta los coordinadores de todos los vínculos (para la barra de menú y el panel).
final class Gestor: ObservableObject {
    @Published private(set) var coordinadores: [Coordinador] = []
    /// Novedad general (por ejemplo, el resultado de "Expulsar discos").
    @Published var aviso: String? {
        didSet { if Notificar.prueba, let aviso { print("PANTALLA \(aviso)"); fflush(stdout) } }
    }
    /// Discos que no se pudieron expulsar porque algo los usa: Inicio muestra quién y ofrece "Cerrar y expulsar".
    @Published var bloqueos: [Bloqueo] = []
    /// "Me voy" está copiando lo último (para no arrancarlo dos veces).
    var yendose = false
    var alCambiarEstado: (() -> Void)?
    private let activo: Bool
    private var suscripciones: [String: AnyCancellable] = [:]
    /// El de la app (lo usa el botón "Me voy" de Inicio).
    private(set) static weak var actual: Gestor?

    init(activo: Bool = true) {
        self.activo = activo
        actualizar()
        if activo { Gestor.actual = self }
    }

    /// Crea o quita coordinadores según los vínculos de los ajustes.
    func actualizar() {
        let ids = Ajustes.shared.datos.vinculos.map(\.id)
        for c in coordinadores where !ids.contains(c.id) { c.cerrar(); suscripciones[c.id] = nil }
        var nuevos: [Coordinador] = []
        for id in ids {
            if let c = coordinadores.first(where: { $0.id == id }) { c.ajustesCambiaron(); nuevos.append(c); continue }
            let c = Coordinador(id: id, activo: activo)
            c.alCambiarEstado = { [weak self] in self?.alCambiarEstado?() }
            suscripciones[id] = c.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            nuevos.append(c)
        }
        coordinadores = nuevos
        alCambiarEstado?()
    }

    func coordinador(_ id: String) -> Coordinador? { coordinadores.first { $0.id == id } }

    /// El estado más importante de todos (para el ícono de la barra).
    var estado: Coordinador.Estado {
        let estados = coordinadores.map(\.estado)
        for e in [Coordinador.Estado.copiando, .revisando, .expulsando, .necesitaOK, .alReves, .primeraVez, .alDia, .pausado,
                  .faltaPortatil, .faltaHub] where estados.contains(e) { return e }
        return .sinCarpetas
    }

    /// Igual, para mostrar (sin el parpadeo de las copias cortas).
    var estadoVisible: Coordinador.Estado {
        let estados = coordinadores.map(\.estadoVisible)
        for e in [Coordinador.Estado.copiando, .revisando, .expulsando, .necesitaOK, .alReves, .primeraVez, .alDia, .pausado,
                  .faltaPortatil, .faltaHub] where estados.contains(e) { return e }
        return .sinCarpetas
    }

    /// Algún vínculo está acomodando los discos recién juntados (ver `Coordinador.llegando`).
    var llegando: Bool { coordinadores.contains(where: \.llegando) }
    var avance: Avance { coordinadores.first { $0.estado == .copiando }?.avance ?? Avance() }
    var ultima: Date? { coordinadores.compactMap(\.ultima).max() }
    func cancelarTodo() { coordinadores.forEach { $0.cancelar() } }
}
