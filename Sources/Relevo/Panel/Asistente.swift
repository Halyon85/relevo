import AppKit
import SwiftUI

/// Arma un vínculo nuevo explicando cada paso, para que la primera vez no haya sorpresas: qué hace Relevo (solo con el
/// primer vínculo), el disco de casa (el hub), el portátil, cómo quedan las rutas afuera (lo que tus apps necesitan para
/// encontrar los proyectos) y qué va a pasar. Después se eligen las carpetas (`PaginaCarpetas`).
/// Casos que cubre (31/10/2026): un solo disco enchufado (la lista se actualiza sola al enchufar), formato de Windows,
/// el disco de Time Machine (no se ofrece), nombres distintos, el disco de casa en una carpeta de la Mac o el portátil en
/// una subcarpeta (las rutas no pueden quedar iguales: se dice), portátil con cosas (no se borra nada), poco lugar y
/// proyectos que Claude Code ya conoce con otra ruta.
struct Asistente: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var navegacion: Navegacion

    enum Paso { case bienvenida, casa, portatil, rutas, resumen }
    /// La bienvenida va solo con el primer vínculo.
    @Estado private var pasos: [Paso] = (Ajustes.shared.datos.vinculos.isEmpty ? [.bienvenida] : []) + [.casa, .portatil, .rutas, .resumen]
    @Estado private var paso: Paso = Ajustes.shared.datos.vinculos.isEmpty ? .bienvenida : .casa
    @Estado private var discos: [Volumen] = Asistente.externos()
    @Estado private var hub: Lugar?
    @Estado private var portatil: Volumen?
    @Estado private var enCarpeta = false
    @Estado private var nombreCarpeta = ""
    @Estado private var mismoNombre = true
    @Estado private var error: String?

    /// `paso`, `hub` y `portatil`: solo para las capturas (`Capturas`), que dibujan cada paso con los discos elegidos.
    init(gestor: Gestor, navegacion: Navegacion, paso: Paso? = nil, hub: Lugar? = nil, portatil: Volumen? = nil) {
        _gestor = ObservedObject(wrappedValue: gestor)
        _navegacion = ObservedObject(wrappedValue: navegacion)
        if let paso { _paso = Estado(initialValue: paso) }
        _hub = Estado(initialValue: hub)
        _portatil = Estado(initialValue: portatil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(T("Paso %ld de %ld", indice + 1, pasos.count)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tema.acento)
                Spacer()
                BotonSecundario(texto: T("Cancelar")) { navegacion.asistente = false }
            }
            Group {
                switch paso {
                case .bienvenida: pasoBienvenida
                case .casa: pasoCasa
                case .portatil: pasoPortatil
                case .rutas: pasoRutas
                case .resumen: pasoResumen
                }
            }
            .transition(.opacity)
            Spacer(minLength: 0)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Tema.error) }
            HStack {
                if indice > 0 { BotonSecundario(texto: T("Atrás"), icono: "chevron.left") { ir(-1) } }
                Spacer()
                if paso == .resumen {
                    BotonPrimario(texto: T("Crear y elegir qué se sincroniza")) { crear() }
                } else {
                    BotonPrimario(texto: paso == .bienvenida ? T("Empezar") : T("Seguir")) { seguir() }
                        .disabled(!puedeSeguir).opacity(puedeSeguir ? 1 : 0.45)
                }
            }
        }
        .padding(24)
        .frame(width: 640, height: 600)
        .background(Tema.fondo)
        .foregroundStyle(Tema.texto)
        // La lista de discos se actualiza sola al enchufar o expulsar uno (no hay que tocar "Volver a buscar").
        .onReceive(NotificationCenter.default.publisher(for: Montajes.montado)) { _ in actualizarDiscos() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didMountNotification)) { _ in actualizarDiscos() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didUnmountNotification)) { _ in actualizarDiscos() }
    }

    // MARK: Pasos

    private var pasoBienvenida: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                Logo(tam: 56)
                TituloPagina(titulo: T("Vinculemos tus discos"), subtitulo: T("Te explico cada paso antes de tocar nada."))
            }
            Tarjeta {
                VStack(alignment: .leading, spacing: 12) {
                    punto("house.fill", T("Elegís el disco de casa, donde trabajás, y el portátil, el que te llevás."))
                    punto("arrow.left.arrow.right", T("Relevo los mantiene iguales en los dos sentidos: lo que hacés afuera vuelve a casa sin que hagas nada."))
                    punto("mappin.and.ellipse", T("Tus proyectos quedan en la misma ubicación estés donde estés, así Claude y tus otras apps los encuentran."))
                    punto("trash", T("Nada se borra del todo: lo borrado o reemplazado va a una papelera de Relevo en cada disco."))
                }
                .padding(16)
            }
            Label(T("macOS te va a pedir permiso para usar discos externos y para mandarte avisos: aceptá los dos, Relevo los necesita."),
                  systemImage: "hand.raised").font(.system(size: 12)).foregroundStyle(Tema.apagado)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pasoCasa: some View {
        VStack(alignment: .leading, spacing: 14) {
            TituloPagina(titulo: T("¿Dónde trabajás?"),
                         subtitulo: T("El disco de casa: queda en casa y tiene todo. Si tus proyectos están en la Mac, elegí la carpeta."))
            ScrollView {
                VStack(spacing: 8) {
                    if discos.isEmpty {
                        Text(T("No veo discos externos. Enchufá el disco donde trabajás y aparece acá solo."))
                            .font(.system(size: 13)).foregroundStyle(Tema.apagado).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(discos) { v in
                        opcion(titulo: v.nombre, detalle: Self.datos(v), icono: "externaldrive.fill", elegida: hub?.uuid == v.uuid) {
                            hub = Lugar(uuid: v.uuid, nombre: v.nombre)
                            if portatil?.uuid == v.uuid { portatil = nil }
                        }
                    }
                    opcion(titulo: hub?.esEstaMac == true ? T("Esta Mac") + " › " + (hub!.subcarpeta as NSString).lastPathComponent : T("Una carpeta de esta Mac…"),
                           detalle: T("Por ejemplo, tu carpeta de Proyectos en el disco de la Mac. Ojo: afuera la ruta va a ser otra (te lo explico más adelante)."),
                           icono: "laptopcomputer", elegida: hub?.esEstaMac == true) { elegirCarpetaDeLaMac() }
                }
            }
        }
    }

    private var pasoPortatil: some View {
        VStack(alignment: .leading, spacing: 14) {
            TituloPagina(titulo: T("¿Qué disco te llevás?"),
                         subtitulo: T("El portátil: queda igual al disco de casa y lo usás afuera."))
            ScrollView {
                VStack(spacing: 8) {
                    let opciones = discos.filter { $0.uuid != hub?.uuid }
                    if opciones.isEmpty {
                        Text(T("Enchufá el disco que te vas a llevar: aparece acá solo."))
                            .font(.system(size: 13)).foregroundStyle(Tema.apagado).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(opciones) { v in
                        let sirve = v.formatoDeMac
                        opcion(titulo: v.nombre,
                               detalle: sirve ? Self.datos(v)
                                              : T("%@ es formato de Windows: no guarda permisos ni enlaces y se puede dañar si lo sacás de golpe. Pasalo a APFS en la Utilidad de Discos (eso lo borra: primero copiá lo que tenga).", v.formato),
                               icono: "externaldrive.fill", elegida: portatil?.uuid == v.uuid, habilitada: sirve) {
                            portatil = v
                        }
                    }
                }
            }
            if discos.contains(where: { $0.uuid != hub?.uuid && !$0.formatoDeMac }) {
                BotonSecundario(texto: T("Abrir Utilidad de Discos"), icono: "externaldrive") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                }
            }
            if let aviso = avisoLugar {
                Label(aviso, systemImage: "chart.bar.fill").font(.system(size: 12)).foregroundStyle(Tema.subtitulo)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Toggle(isOn: $enCarpeta) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Guardar en una carpeta del portátil")).font(.system(size: 13)).foregroundStyle(Tema.titulo)
                    Text(T("Solo si querés usar el mismo disco para más de un vínculo (por ejemplo, Proyectos y Fotos). Afuera la ruta suma esa carpeta.")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            if enCarpeta {
                TextField(T("Nombre de la carpeta"), text: $nombreCarpeta)
                    .textFieldStyle(.plain).font(.system(size: 13))
                    .padding(.horizontal, 10).frame(height: 32)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Tema.rellenoSuave))
            }
        }
    }

    private var pasoRutas: some View {
        VStack(alignment: .leading, spacing: 14) {
            TituloPagina(titulo: T("Tus rutas"),
                         subtitulo: T("Claude y tus otras apps recuerdan cada proyecto por su ubicación. Si afuera es la misma, encuentran todo."))
            if let hub, let portatil {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Tarjeta {
                            VStack(alignment: .leading, spacing: 10) {
                                ruta(T("En casa"), Self.raizEnCasa(hub) + "/" + ejemplo)
                                ruta(T("Afuera"), raizAfuera(hub, portatil) + "/" + ejemplo)
                                Divider()
                                if rutasIguales {
                                    Label(T("Iguales: afuera tus apps encuentran los proyectos en el mismo lugar."), systemImage: "checkmark.circle.fill")
                                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Tema.exito)
                                } else {
                                    Label(T("Distintas: afuera tus apps ven los proyectos como si fueran otros."), systemImage: "exclamationmark.triangle.fill")
                                        .font(.system(size: 13, weight: .medium)).foregroundStyle(Tema.acento)
                                }
                            }
                            .padding(16)
                        }
                        explicacionRutas(hub, portatil)
                        notasClaude(hub, portatil)
                    }
                }
            }
        }
    }

    @ViewBuilder private func explicacionRutas(_ hub: Lugar, _ portatil: Volumen) -> some View {
        if hub.esEstaMac {
            nota("laptopcomputer", T("El disco de casa es una carpeta de esta Mac: afuera vas a abrir los proyectos desde el portátil, en otra ubicación. Los archivos están todos, pero tus apps no van a encontrar los chats ni los recientes de antes. Si querés la misma ubicación, usá un disco externo como disco de casa."))
        } else if enCarpeta {
            nota("folder", T("Elegiste guardar en una carpeta del portátil, así que afuera la ruta suma esa carpeta. Si querés la misma ubicación, volvé y apagá “Guardar en una carpeta del portátil”."))
        } else if sugerirNombre {
            Toggle(isOn: $mismoNombre.animation(Tema.expo)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Afuera, el portátil se llama “%@”", hub.nombre)).font(.system(size: 13, weight: .medium)).foregroundStyle(Tema.titulo)
                    Text(mismoNombre
                         ? T("Relevo le cambia el nombre solo, sin borrar ni mover nada. En casa se llama “%@” para no confundirlos; ahí le podés poner el nombre que quieras.", Discos.nombreEnCasa(hub.nombre))
                         : T("Afuera se va a llamar “%@” y la ruta cambia. Para que tus apps encuentren todo, conviene dejarlo prendido.", portatil.nombre))
                        .font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
        } else {
            nota("checkmark.seal", T("Los dos discos se llaman “%@”: afuera todo queda en el mismo lugar. En casa el portátil va a llamarse “%@” para no confundirlos.", hub.nombre, Discos.nombreEnCasa(hub.nombre)))
        }
    }

    /// Lo que Claude Code ya conoce en estos discos (solo mira los nombres de las carpetas que guarda, sin abrir nada).
    @ViewBuilder private func notasClaude(_ hub: Lugar, _ portatil: Volumen) -> some View {
        // Lo del portátil en casa ("Trabajo (portátil)…") no cuenta como del disco de casa ("Trabajo…").
        let enCasa = Self.proyectosDeClaude(en: Self.raizEnCasa(hub), salvo: ["/Volumes/" + portatil.nombre])
        let conOtroNombre = usarNombreDelHub && portatil.nombre != hub.nombre ? Self.proyectosDeClaude(en: "/Volumes/" + portatil.nombre) : 0
        if enCasa > 0, rutasIguales {
            nota("sparkles", T("Claude Code ya conoce %ld proyecto(s) en el disco de casa: afuera los va a encontrar en el mismo lugar, con sus chats.", enCasa))
        }
        if conOtroNombre > 0 {
            nota("clock.arrow.circlepath", T("Ya usaste Claude Code en %ld proyecto(s) del portátil cuando se llamaba “%@”. Esos chats siguen guardados con la ruta vieja; desde ahora, afuera vas a trabajar en la ruta de casa.", conOtroNombre, portatil.nombre))
        }
    }

    private var pasoResumen: some View {
        VStack(alignment: .leading, spacing: 14) {
            TituloPagina(titulo: T("Qué va a pasar"), subtitulo: T("Después elegís qué carpetas se sincronizan."))
            ScrollView {
                Tarjeta {
                    VStack(alignment: .leading, spacing: 12) {
                        punto("folder", T("Ahora elegís qué carpetas se sincronizan. Lo que se arma solo al compilar (como .next o DerivedData) no se copia."))
                        punto("arrow.triangle.2.circlepath", T("La primera copia pasa todo lo elegido al portátil y puede tardar. Después copia solo lo que cambia, al momento."))
                        if let portatil, Self.ocupado(portatil) > 1 << 30 {
                            punto("tray.full", T("El portátil ya tiene %@ de cosas: no se borra nada. Se junta con lo de casa y, si un archivo está distinto en los dos, quedan las dos versiones para que elijas.", Formato.bytes(Self.ocupado(portatil))))
                        }
                        punto("figure.walk", T("Cuando te vas, tocá “Me voy”: copia lo último y expulsa los discos."))
                        punto("house", T("Cuando volvés, enchufás el portátil: te pide que esperes un momento y te avisa “Listo” con lo que trajo."))
                    }
                    .padding(16)
                }
            }
            if let portatil, (try? portatil.url.resourceValues(forKeys: [.volumeIsEncryptedKey]).volumeIsEncrypted) != true {
                Label(T("Si querés, después podés cifrar el portátil desde Discos (por si lo perdés)."), systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Tema.apagado)
            }
        }
    }

    // MARK: Piezas

    private func punto(_ icono: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icono).font(.system(size: 14)).foregroundStyle(Tema.acento).frame(width: 20)
            Text(texto).font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func nota(_ icono: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icono).font(.system(size: 13)).foregroundStyle(Tema.apagado).frame(width: 20)
            Text(texto).font(.system(size: 12)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func ruta(_ titulo: String, _ camino: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(titulo).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tema.apagado).frame(width: 64, alignment: .leading)
            Text(camino).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tema.titulo)
                .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }

    private func opcion(titulo: String, detalle: String, icono: String, elegida: Bool, habilitada: Bool = true,
                        accion: @escaping () -> Void) -> some View {
        Button(action: accion) {
            HStack(spacing: 12) {
                Image(systemName: icono).font(.system(size: 22)).frame(width: 32).foregroundStyle(habilitada ? Tema.titulo : Tema.apagado)
                VStack(alignment: .leading, spacing: 2) {
                    Text(titulo).font(.titulo(14, .semibold)).foregroundStyle(habilitada ? Tema.titulo : Tema.apagado)
                    Text(detalle).font(.system(size: 12)).foregroundStyle(habilitada ? Tema.apagado : Tema.error)
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                }
                Spacer()
                if elegida { Image(systemName: "checkmark.circle.fill").foregroundStyle(Tema.acento) }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Tema.tarjeta))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(elegida ? Tema.acento : Tema.bordeSuave, lineWidth: elegida ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!habilitada)
    }

    // MARK: Lógica

    private var indice: Int { pasos.firstIndex(of: paso) ?? 0 }

    private var puedeSeguir: Bool {
        switch paso {
        case .casa: hub != nil
        case .portatil: portatil != nil && (!enCarpeta || !nombreCarpeta.trimmingCharacters(in: .whitespaces).isEmpty)
        default: true
        }
    }

    /// Los dos son discos enteros con nombres distintos: se ofrece que afuera el portátil lleve el nombre del de casa.
    private var sugerirNombre: Bool {
        guard let hub, let portatil, !hub.esEstaMac, hub.subcarpeta.isEmpty, !enCarpeta else { return false }
        return hub.nombre != portatil.nombre
    }

    private var usarNombreDelHub: Bool {
        guard let hub, let portatil, !hub.esEstaMac, !enCarpeta else { return false }
        return (sugerirNombre && mismoNombre) || portatil.nombre == hub.nombre
    }

    private var rutasIguales: Bool {
        guard let hub, let portatil else { return false }
        return Self.raizEnCasa(hub) == raizAfuera(hub, portatil)
    }

    /// Dónde está la raíz del portátil cuando lo usás afuera (sin el disco de casa).
    private func raizAfuera(_ hub: Lugar, _ portatil: Volumen) -> String {
        let carpeta = enCarpeta ? "/" + nombreCarpeta.trimmingCharacters(in: .whitespaces) : ""
        return "/Volumes/" + (usarNombreDelHub ? hub.nombre : portatil.nombre) + carpeta
    }

    static func raizEnCasa(_ hub: Lugar) -> String { hub.esEstaMac ? hub.subcarpeta : "/Volumes/" + hub.nombre }

    /// Un proyecto real del disco de casa para el ejemplo de las rutas (por ejemplo "Proyectos/Cliente"): se entiende
    /// mejor con algo tuyo que con un nombre inventado. Busca, hasta dos niveles, una carpeta con `.git` o
    /// `package.json`; si no hay, la primera carpeta.
    private var ejemplo: String {
        guard let hub, let disco = hub.esEstaMac ? hub.subcarpeta : Discos.buscar(hub.uuid)?.ruta else { return T("Proyectos") }
        let fm = FileManager.default
        func carpetas(_ ruta: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: ruta)) ?? []).sorted()
                .filter { !$0.hasPrefix(".") && !["Applications", "Library", "System"].contains($0)
                    && (try? URL(fileURLWithPath: ruta + "/" + $0).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        }
        func esProyecto(_ ruta: String) -> Bool { fm.fileExists(atPath: ruta + "/.git") || fm.fileExists(atPath: ruta + "/package.json") }
        let arriba = carpetas(disco)
        for uno in arriba {
            if esProyecto(disco + "/" + uno) { return uno }
            if let dos = carpetas(disco + "/" + uno).first(where: { esProyecto(disco + "/" + uno + "/" + $0) }) { return uno + "/" + dos }
        }
        guard let uno = arriba.first else { return T("Proyectos") }
        return carpetas(disco + "/" + uno).first.map { uno + "/" + $0 } ?? uno
    }

    /// Si en el portátil no entra lo que hay en el disco de casa, se avisa antes (después se eligen las carpetas).
    private var avisoLugar: String? {
        guard let hub, !hub.esEstaMac, let casa = Discos.buscar(hub.uuid), let portatil else { return nil }
        let usado = Self.ocupado(casa)
        guard usado > portatil.libre else { return nil }
        return T("En el disco de casa hay %@ y en el portátil entran %@: en el próximo paso elegís qué carpetas llevar.", Formato.bytes(usado), Formato.bytes(portatil.libre))
    }

    static func ocupado(_ v: Volumen) -> Int64 { max(0, v.capacidad - v.libre) }

    /// "APFS · 1 TB · 300 GB libres · 12 carpetas".
    static func datos(_ v: Volumen) -> String {
        let carpetas = ((try? FileManager.default.contentsOfDirectory(atPath: v.ruta)) ?? []).filter { n in
            !n.hasPrefix(".") && (try? URL(fileURLWithPath: v.ruta + "/" + n).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        }.count
        return "\(v.formato) · \(Formato.bytes(v.capacidad)) · " + T("%@ libres", Formato.bytes(v.libre))
            + (carpetas > 0 ? " · " + T("%ld carpeta(s)", carpetas) : " · " + T("vacío"))
    }

    /// Cuántos proyectos de Claude Code hay adentro de `raiz`. Claude guarda cada proyecto en ~/.claude/projects con la
    /// ruta como nombre, cambiando todo lo que no es letra o número por "-" ("/Volumes/Trabajo/X" →
    /// "-Volumes-Trabajo-X"). Solo se leen esos nombres.
    /// `salvo`: otras raíces cuyo nombre empieza igual (ese cambio a "-" junta "Trabajo/" con "Trabajo (…").
    static func proyectosDeClaude(en raiz: String, salvo: [String] = []) -> Int {
        let carpeta = NSHomeDirectory() + "/.claude/projects"
        guard let nombres = try? FileManager.default.contentsOfDirectory(atPath: carpeta) else { return 0 }
        func codigos(_ r: String) -> Set<String> {
            Set([r.precomposedStringWithCanonicalMapping, r.decomposedStringWithCanonicalMapping].map { r in
                String(r.unicodeScalars.map { ($0.isASCII && CharacterSet.alphanumerics.contains($0)) ? Character($0) : "-" })
            })
        }
        let propios = codigos(raiz), ajenos = salvo.flatMap(codigos)
        func adentro(_ n: String, _ c: String) -> Bool { n == c || n.hasPrefix(c + "-") }
        return nombres.filter { n in propios.contains { adentro(n, $0) } && !ajenos.contains { adentro(n, $0) } }.count
    }

    private func ir(_ salto: Int) {
        error = nil
        let i = min(max(0, indice + salto), pasos.count - 1)
        withAnimation(Tema.expo) { paso = pasos[i] }
    }

    private func seguir() {
        error = nil
        if paso == .portatil, let p = portatil,
           Ajustes.shared.datos.vinculos.contains(where: { $0.portatil.uuid == p.uuid && $0.portatil.subcarpeta == (enCarpeta ? nombreCarpeta : "") }) {
            error = T("Ese portátil ya está en otro vínculo. Usá “Guardar en una carpeta del portátil” para compartirlo.")
            return
        }
        ir(1)
    }

    private func actualizarDiscos() {
        discos = Self.externos()
        // Si se fue el disco elegido, se deja de elegir.
        if let p = portatil, !discos.contains(where: { $0.uuid == p.uuid }) { portatil = nil }
        if let h = hub, !h.esEstaMac, !discos.contains(where: { $0.uuid == h.uuid }) { hub = nil }
    }

    private func elegirCarpetaDeLaMac() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = T("Usar como disco de casa")
        panel.message = T("Elegí la carpeta donde trabajás (por ejemplo, Proyectos).")
        if panel.runModal() == .OK, let u = panel.url {
            hub = Lugar(uuid: Lugar.estaMac, nombre: "Esta Mac", subcarpeta: u.path)
        }
    }

    private func crear() {
        guard let hub, let p = portatil else { return }
        // Mismo nombre afuera: no se renombra acá; el coordinador le pone "<nombre> (portátil)" mientras esté el hub
        // y el nombre del hub cuando el portátil está solo (ver `Vinculo.nombreAfuera`).
        let usar = usarNombreDelHub
        let carpeta = enCarpeta ? nombreCarpeta.trimmingCharacters(in: .whitespaces) : ""
        if !carpeta.isEmpty { try? FileManager.default.createDirectory(atPath: p.ruta + "/" + carpeta, withIntermediateDirectories: true) }
        var v = Vinculo(hub: hub, portatil: Lugar(uuid: p.uuid, nombre: usar ? hub.nombre : p.nombre, subcarpeta: carpeta))
        if usar, Vinculo.discosEnteros(v.hub, v.portatil) { v.nombreAfuera = hub.nombre }
        Ajustes.shared.datos.vinculos.append(v)
        navegacion.vinculo = v.id
        navegacion.pagina = .carpetas
        navegacion.asistente = false
    }

    /// Discos externos montados (también los que Relevo ocultó del Finder), menos los de Time Machine.
    static func externos() -> [Volumen] {
        let timeMachine = Discos.deTimeMachine()
        return Discos.montados().filter { $0.externo && $0.ruta.hasPrefix("/Volumes/") && !timeMachine.contains($0.ruta) }
            .sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
    }
}
