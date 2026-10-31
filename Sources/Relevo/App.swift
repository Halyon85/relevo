import AppKit
import Combine
import ServiceManagement
import SwiftUI

@main
enum Principal {
    static func main() {
        let app = NSApplication.shared
        if Terminal.correr(CommandLine.arguments) { return }
        if TerminalCifrado.correr(CommandLine.arguments) { return }
        if let i = CommandLine.arguments.firstIndex(of: "--capturas"), i + 1 < CommandLine.arguments.count {
            app.setActivationPolicy(.accessory)
            Capturas.hacer(en: CommandLine.arguments[i + 1])
            return
        }
        if Instalada.abrirEnSuLugar() { return }
        _ = Coordinador.inicio   // la hora de arranque (para esperar al hub recién prendida la Mac)
        Cierre.arrancar()        // ¿se cerró bien la última vez? (si no, la próxima revisión mira todo)
        let delegado = Delegado()
        app.delegate = delegado
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class Delegado: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var gestor: Gestor!
    let navegacion = Navegacion()
    private var item: NSStatusItem!
    private var reloj: Timer?
    private var cuadro = 0
    private var ventana: NSWindow?
    private var observadores = Set<AnyCancellable>()

    // Enlaces relevo:// (para Atajos de macOS, Raycast, Alfred…): se registran antes de terminar de abrir.
    func applicationWillFinishLaunching(_ n: Notification) {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(abrirEnlace(_:respuesta:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationWillTerminate(_ n: Notification) {
        Cierre.cerrandoBien()
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        gestor = Gestor()
        // Discos que aparecen bloqueados (cifrados): cada vínculo intenta abrir el suyo con la clave del llavero.
        MonitorDiscos.shared.alAparecer = { [weak self] in self?.gestor.coordinadores.forEach { $0.intentarDesbloquear() } }
        MonitorDiscos.shared.arrancar()
        // Antes de que la Mac se duerma (tapa cerrada), copiar lo pendiente.
        AntesDeDormir.shared.preparar = { [weak self] listo in
            guard let self else { listo(); return }
            self.gestor.antesDeDormir(listo)
        }
        AntesDeDormir.shared.arrancar()
        Atajos.shared.alApretar = { [weak self] accion in self?.hacer(accion) }
        Atajos.shared.activar(Ajustes.shared.datos.atajos)
        crearMenu()
        aplicarApariencia()
        Notificar.pedirPermiso()
        Montajes.shared.arrancar()
        Actualizaciones.arrancar()
        Ajustes.shared.alCambiar = { [weak self] in
            self?.aplicarApariencia()
            self?.gestor.actualizar()
            Atajos.shared.activar(Ajustes.shared.datos.atajos)
            self?.actualizarMenu()
        }
        gestor.alCambiarEstado = { [weak self] in self?.actualizarMenu() }
        gestor.objectWillChange.throttle(for: 1, scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in self?.actualizarMenu() }.store(in: &observadores)
        if Ajustes.shared.datos.vinculos.isEmpty { abrirPanel(.inicio) }
        if Notificar.prueba {
            // Órdenes de prueba desde la terminal (solo con RELEVO_PRUEBA): mevoy, sincronizar, panel, expulsar, dormir, acomodar, cerrar.
            DistributedNotificationCenter.default().addObserver(forName: Notification.Name("team.halyon.relevo.prueba"),
                                                                object: nil, queue: .main) { [weak self] n in
                switch n.object as? String {
                case "mevoy": self?.gestor.meVoy(preguntar: false)
                case "sincronizar": self?.gestor.coordinadores.forEach { $0.sincronizarInteligente(aMano: true) }
                case "sincronizar-todo": self?.gestor.coordinadores.forEach { $0.sincronizar(aMano: true) }
                case "revision-completa": self?.gestor.coordinadores.forEach { $0.revisionCompletaSiToca(forzar: true) }
                case "panel": self?.abrirPanel(.inicio)
                // Solo discos de ensayo (empiezan con "SG"): una prueba nunca expulsa discos reales.
                case "expulsar": self?.gestor.expulsar(Discos.expulsables().filter { $0.nombre.hasPrefix("SG") })
                case "dormir": self?.gestor.antesDeDormir { print("DORMIR-LISTO"); fflush(stdout) }
                // Igual: solo vínculos cuyo hub es un disco de ensayo.
                case "acomodar": self?.gestor.coordinadores.filter { $0.alReves && ($0.hub?.nombre.hasPrefix("SG") ?? false) }.forEach { $0.acomodar() }
                case "cerrar": self?.ventana?.close()
                default: break
                }
            }
        }
    }

    // MARK: - Menú de la barra

    private func crearMenu() {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        actualizarMenu()
    }

    /// Ícono de la barra según el estado. Mientras copia, las líneas de velocidad se mueven (un reloj que existe
    /// solo mientras copia).
    private func ponerIcono() {
        let e = gestor.estadoVisible
        // Acomodando los discos recién juntados también se mueve: es el "esperá" de la barra.
        let copiando = e == .revisando || e == .copiando || e == .expulsando || gestor.llegando
        let marca: IconoBarra.Marca = [Coordinador.Estado.necesitaOK, .alReves, .primeraVez].contains(e) ? .punto : .ninguna
        let apagado = [Coordinador.Estado.faltaPortatil, .faltaHub, .sinCarpetas, .pausado].contains(e)
        item.button?.image = IconoBarra.imagen(marca: marca, copiando: copiando, cuadro: cuadro, apagado: apagado)
        if copiando, reloj == nil {
            reloj = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.cuadro += 1
                self.ponerIcono()
            }
        } else if !copiando {
            reloj?.invalidate()
            reloj = nil
            cuadro = 0
        }
    }

    static func lineaEstado(_ c: Coordinador) -> String {
        // Recién juntados los discos: lo primero es que no abras tus apps todavía (ver `Coordinador.llegando`).
        if c.llegando {
            let a = c.avance
            return c.estadoVisible == .copiando && a.total > 0
                ? T("Esperá: trayendo lo de afuera (%ld de %ld)…", a.hechos, a.total)
                : T("Esperá: acomodando los discos…")
        }
        switch c.estadoVisible {
        case .sinCarpetas: return T("Falta elegir qué se sincroniza")
        case .faltaHub: return T("Trabajando desde el portátil")
        case .faltaPortatil: return c.listoParaIrse ? T("Listo: ya podés desenchufarlo") : T("Portátil desconectado")
        case .alReves: return T("Los discos quedaron al revés")
        case .primeraVez: return T("Falta la primera copia")
        case .pausado: return c.vinculo?.pausadoHasta.map { T("En pausa hasta %@", Formato.hora($0)) } ?? T("En pausa")
        case .revisando: return T("Revisando…")
        case .copiando:
            let a = c.avance
            return a.total > 0 ? T("Copiando %ld de %ld…", a.hechos, a.total) : T("Copiando…")
        case .alDia: return T("Todo al día") + (c.ultima.map { " · " + Formato.haceCuanto($0) } ?? "")
        case .necesitaOK: return T("Hace falta tu OK")
        case .expulsando: return T("Expulsando…")
        }
    }

    private func actualizarMenu() {
        ponerIcono()
        let m = NSMenu()
        if gestor.coordinadores.isEmpty {
            let it = NSMenuItem(title: "Relevo · " + T("Falta configurar"), action: nil, keyEquivalent: "")
            it.isEnabled = false
            m.addItem(it)
        }
        for c in gestor.coordinadores {
            let titulo = NSMenuItem(title: c.vinculo?.portatil.descripcion ?? T("Vínculo"), action: nil, keyEquivalent: "")
            titulo.isEnabled = false
            titulo.attributedTitle = NSAttributedString(string: titulo.title, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
            m.addItem(titulo)
            let estado = NSMenuItem(title: Self.lineaEstado(c), action: nil, keyEquivalent: "")
            estado.isEnabled = false
            m.addItem(estado)
            let ocupado = c.estadoVisible == .copiando || c.estadoVisible == .revisando
            m.addItem(accion(ocupado ? T("Sincronizando…") : T("Sincronizar ahora"), #selector(sincronizar(_:)), c,
                             habilitado: c.conectados && !ocupado))
            if c.portatil != nil { m.addItem(accion(T("Mostrar el portátil en el Finder"), #selector(mostrarPortatil(_:)), c)) }
            let pausa = NSMenuItem(title: c.vinculo?.pausado == true ? T("Reanudar") : T("Pausar"), action: nil, keyEquivalent: "")
            if c.vinculo?.pausado == true {
                pausa.action = #selector(reanudar(_:)); pausa.target = self; pausa.representedObject = c.id
            } else {
                let sub = NSMenu()
                for (texto, segundos) in [(T("1 hora"), 3600.0), (T("Hasta mañana"), Formato.segundosHastaManana()), (T("Hasta que la reanude"), 3650 * 86400.0)] {
                    let it = accion(texto, #selector(pausar(_:)), c)
                    it.tag = Int(segundos)
                    sub.addItem(it)
                }
                pausa.submenu = sub
            }
            m.addItem(pausa)
            m.addItem(.separator())
        }
        let discos = Discos.expulsables()
        let meVoy = NSMenuItem(title: T("Me voy (copiar y expulsar todo)"), action: discos.isEmpty ? nil : #selector(meVoy), keyEquivalent: "")
        meVoy.target = self
        meVoy.isEnabled = !discos.isEmpty
        m.addItem(meVoy)
        if !discos.isEmpty {
            let expulsar = NSMenuItem(title: T("Expulsar discos"), action: nil, keyEquivalent: "")
            let sub = NSMenu()
            let todos = NSMenuItem(title: T("Todos (%ld)", discos.count), action: #selector(expulsarTodos), keyEquivalent: "")
            todos.target = self
            sub.addItem(todos)
            sub.addItem(.separator())
            for v in discos {
                let it = NSMenuItem(title: gestor.etiqueta(v), action: #selector(expulsarUno(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = v.uuid
                sub.addItem(it)
            }
            expulsar.submenu = sub
            m.addItem(expulsar)
            m.addItem(.separator())
        }
        m.addItem(withTitle: T("Abrir Relevo…"), action: #selector(abrirInicio), keyEquivalent: ",").target = self
        m.addItem(withTitle: T("Historial"), action: #selector(abrirHistorial), keyEquivalent: "").target = self
        if Actualizaciones.disponibles {
            m.addItem(withTitle: T("Buscar actualizaciones de Relevo…"), action: #selector(buscarActualizaciones), keyEquivalent: "").target = self
        }
        m.addItem(.separator())
        m.addItem(withTitle: T("Salir de Relevo"), action: #selector(salir), keyEquivalent: "q").target = self
        item.menu = m
    }

    private func accion(_ titulo: String, _ sel: Selector, _ c: Coordinador, habilitado: Bool = true) -> NSMenuItem {
        let it = NSMenuItem(title: titulo, action: sel, keyEquivalent: "")
        it.target = self
        it.representedObject = c.id
        it.isEnabled = habilitado
        return it
    }

    private func coordinador(_ it: NSMenuItem) -> Coordinador? { (it.representedObject as? String).flatMap { gestor.coordinador($0) } }

    @objc private func sincronizar(_ it: NSMenuItem) { coordinador(it)?.sincronizarInteligente(aMano: true) }
    @objc private func meVoy() { abrirPanel(.inicio); gestor.meVoy() }
    @objc private func mostrarPortatil(_ it: NSMenuItem) { coordinador(it)?.mostrarPortatil() }
    @objc private func pausar(_ it: NSMenuItem) { coordinador(it)?.pausar(hasta: Date().addingTimeInterval(Double(it.tag))) }
    @objc private func reanudar(_ it: NSMenuItem) { coordinador(it)?.pausar(hasta: nil) }
    @objc private func abrirInicio() { abrirPanel(nil) }
    @objc private func abrirHistorial() { abrirPanel(.historial) }
    @objc private func buscarActualizaciones() { Actualizaciones.buscar() }
    @objc private func expulsarTodos() { gestor.expulsar(Discos.expulsables()); abrirPanel(.inicio) }
    @objc private func expulsarUno(_ it: NSMenuItem) {
        guard let uuid = it.representedObject as? String, let v = Discos.buscar(uuid) else { return }
        gestor.expulsar([v])
        abrirPanel(.inicio)
    }

    private func hacer(_ accion: Atajos.Accion) {
        switch accion {
        case .sincronizar: gestor.coordinadores.forEach { $0.sincronizarInteligente(aMano: true) }
        case .meVoy: abrirPanel(.inicio); gestor.meVoy()
        case .expulsar: gestor.expulsar(Discos.expulsables())
        }
    }

    /// relevo://sincronizar · relevo://mevoy · relevo://expulsar · relevo://abrir · relevo://pausar?horas=2 · relevo://reanudar
    @objc private func abrirEnlace(_ evento: NSAppleEventDescriptor, respuesta: NSAppleEventDescriptor) {
        guard let texto = evento.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLComponents(string: texto), url.scheme == "relevo" else { return }
        // Cualquier página web o app puede abrir un enlace relevo://: lo que expulsa discos (y cierra lo que los usa) o
        // saca la pausa pide tu OK; sincronizar respeta la pausa (auditoría del 23/10).
        switch url.host ?? "" {
        case "sincronizar", "sync": gestor.coordinadores.forEach { $0.sincronizarInteligente(aMano: false) }
        case "mevoy", "leave":
            // "Me voy" ya pregunta siempre: acá solo se agrega que lo pidió un enlace.
            abrirPanel(.inicio)
            gestor.meVoy(desdeEnlace: true)
        case "expulsar", "eject":
            if confirmarEnlace(T("¿Expulsar todos los discos externos?")) { hacer(.expulsar) }
        case "pausar", "pause":
            // Entre unos minutos y 30 días (un número raro, infinito o negativo no vale).
            let pedido = Double(url.queryItems?.first { $0.name == "horas" || $0.name == "hours" }?.value ?? "") ?? 1
            let horas = pedido.isFinite && pedido > 0 ? min(pedido, 720) : 1
            gestor.coordinadores.forEach { $0.pausar(hasta: Date().addingTimeInterval(horas * 3600)) }
        case "reanudar", "resume":
            if confirmarEnlace(T("¿Volver a copiar automáticamente?")) { gestor.coordinadores.forEach { $0.pausar(hasta: nil) } }
        default: abrirPanel(.inicio)
        }
    }

    /// Pregunta antes de hacer algo que pidió un enlace relevo:// (puede venir de una página web).
    private func confirmarEnlace(_ pregunta: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = pregunta
        a.informativeText = T("Lo pidió un enlace relevo:// (desde Atajos, Raycast o una página web). Si no fuiste vos, tocá Cancelar.")
        a.addButton(withTitle: T("Sí"))
        a.addButton(withTitle: T("Cancelar"))
        return a.runModal() == .alertFirstButtonReturn
    }
    @objc private func salir() {
        gestor.cancelarTodo()
        NSApp.terminate(nil)
    }

    // MARK: - Panel

    func abrirPanel(_ pagina: Pagina?) {
        if let pagina { navegacion.pagina = pagina }
        if ventana == nil {
            let raiz = VistaPanel(gestor: gestor, ajustes: .shared, navegacion: navegacion)
            let v = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            v.titlebarAppearsTransparent = true
            v.titleVisibility = .hidden
            // El contenido va debajo de la barra (no por debajo): con la barra encima, macOS 27 pierde memoria
            // (CGRegion) cada vez que recalcula la zona de arrastre. La barra toma el color del fondo.
            v.backgroundColor = NSColor(name: nil) { a in
                a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: 0x1D1D1C) : NSColor(hex: 0xFBFAF9)
            }
            // Sin "mover desde el fondo": en macOS 27 SwiftUI pierde memoria (CGRegion) al calcular esas zonas.
            v.isMovableByWindowBackground = false
            v.minSize = NSSize(width: 760, height: 520)
            v.contentView = NSHostingView(rootView: raiz)
            v.isReleasedWhenClosed = false
            v.delegate = self
            v.center()
            v.setFrameAutosaveName("PanelRelevo")
            ventana = v
        }
        NSApp.setActivationPolicy(.regular)
        ventana?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        // Que no quede nada "seleccionado" al abrir (macOS le ponía el recuadro de foco al link de Halyon Team).
        DispatchQueue.main.async { [weak self] in self?.ventana?.makeFirstResponder(nil) }
    }

    // Al cerrar el panel se libera entero: la app queda solo en la barra, gastando lo mínimo.
    func windowWillClose(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)
        DispatchQueue.main.async { [weak self] in
            self?.ventana?.contentView = nil
            self?.ventana?.delegate = nil
            self?.ventana = nil
        }
    }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        abrirPanel(nil)
        return true
    }

    private func aplicarApariencia() {
        switch Ajustes.shared.datos.apariencia {
        case .sistema: NSApp.appearance = nil
        case .claro: NSApp.appearance = NSAppearance(named: .aqua)
        case .oscuro: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum InicioSesion {
    static var activo: Bool { SMAppService.mainApp.status == .enabled }

    static func cambiar(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Relevo: no pude cambiar el inicio de sesión: \(error)")
        }
    }
}
