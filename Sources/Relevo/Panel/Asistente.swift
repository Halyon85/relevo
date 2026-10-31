import AppKit
import SwiftUI

/// Arma un vínculo nuevo en tres pasos: el hub, el portátil y listo. Después se eligen las carpetas.
struct Asistente: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var navegacion: Navegacion
    @Estado private var paso = 1
    @Estado private var discos: [Volumen] = Asistente.externos()
    @Estado private var hub: Lugar?
    @Estado private var portatil: Volumen?
    @Estado private var enCarpeta = false
    @Estado private var nombreCarpeta = ""
    @Estado private var mismoNombre = true
    @Estado private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(T("Paso %ld de 3", paso)).font(.system(size: 12, weight: .semibold)).foregroundStyle(Tema.acento)
                Spacer()
                BotonSecundario(texto: T("Cancelar")) { navegacion.asistente = false }
            }
            switch paso {
            case 1: pasoHub
            case 2: pasoPortatil
            default: pasoListo
            }
            Spacer(minLength: 0)
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(Tema.error) }
            HStack {
                if paso > 1 { BotonSecundario(texto: T("Atrás"), icono: "chevron.left") { paso -= 1; error = nil } }
                Spacer()
                if paso < 3 {
                    BotonPrimario(texto: T("Seguir")) { seguir() }.disabled(!puedeSeguir).opacity(puedeSeguir ? 1 : 0.45)
                } else {
                    BotonPrimario(texto: T("Crear y elegir qué se sincroniza")) { crear() }
                }
            }
        }
        .padding(24)
        .frame(width: 640, height: 560)
        .background(Tema.fondo)
        .foregroundStyle(Tema.texto)
    }

    // MARK: Pasos

    private var pasoHub: some View {
        VStack(alignment: .leading, spacing: 14) {
            TituloPagina(titulo: T("¿Dónde trabajás?"),
                         subtitulo: T("El hub: el disco (o la carpeta de esta Mac) que queda en casa y tiene todo."))
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(discos) { v in
                        opcion(titulo: v.nombre, detalle: "\(v.formato) · \(Formato.bytes(v.capacidad)) · " + T("%@ libres", Formato.bytes(v.libre)),
                               icono: "externaldrive.fill", elegida: hub?.uuid == v.uuid) {
                            hub = Lugar(uuid: v.uuid, nombre: v.nombre)
                        }
                    }
                    opcion(titulo: hub?.esEstaMac == true ? T("Esta Mac") + " › " + (hub!.subcarpeta as NSString).lastPathComponent : T("Una carpeta de esta Mac…"),
                           detalle: T("Por ejemplo, tu carpeta de Proyectos en el disco de la Mac."), icono: "laptopcomputer",
                           elegida: hub?.esEstaMac == true) { elegirCarpetaDeLaMac() }
                }
            }
            BotonSecundario(texto: T("Volver a buscar discos"), icono: "arrow.clockwise") { discos = Asistente.externos() }
        }
    }

    private var pasoPortatil: some View {
        VStack(alignment: .leading, spacing: 14) {
            TituloPagina(titulo: T("¿Qué disco te llevás?"),
                         subtitulo: T("El portátil: queda igual al hub y lo usás afuera. Tiene que estar en formato de Mac (APFS)."))
            ScrollView {
                VStack(spacing: 8) {
                    let opciones = discos.filter { $0.uuid != hub?.uuid }
                    if opciones.isEmpty {
                        Text(T("Enchufá el disco que te vas a llevar y tocá “Volver a buscar discos”.")).font(.system(size: 13)).foregroundStyle(Tema.apagado)
                    }
                    ForEach(opciones) { v in
                        let sirve = v.formatoDeMac
                        opcion(titulo: v.nombre,
                               detalle: sirve ? "\(v.formato) · \(Formato.bytes(v.capacidad)) · " + T("%@ libres", Formato.bytes(v.libre))
                                              : T("%@: es formato de Windows. Pasalo a APFS en la Utilidad de Discos para usarlo (eso lo borra).", v.formato),
                               icono: "externaldrive.fill", elegida: portatil?.uuid == v.uuid, habilitada: sirve) {
                            portatil = v
                        }
                    }
                }
            }
            HStack {
                BotonSecundario(texto: T("Volver a buscar discos"), icono: "arrow.clockwise") { discos = Asistente.externos() }
                BotonSecundario(texto: T("Utilidad de Discos"), icono: "externaldrive") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                }
            }
            Toggle(isOn: $enCarpeta) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Guardar en una carpeta del portátil")).font(.system(size: 13)).foregroundStyle(Tema.titulo)
                    Text(T("Para usar el mismo disco en más de un vínculo (por ejemplo, Proyectos y Fotos).")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
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

    private var pasoListo: some View {
        VStack(alignment: .leading, spacing: 14) {
            TituloPagina(titulo: T("Casi listo"), subtitulo: T("Después elegís qué carpetas se sincronizan."))
            if let hub, let portatil {
                Tarjeta {
                    Fila(titulo: T("Hub"), detalle: hub.descripcion) { Image(systemName: hub.esEstaMac ? "laptopcomputer" : "externaldrive.fill") }
                    Fila(titulo: T("Portátil"), detalle: portatil.nombre + (enCarpeta && !nombreCarpeta.isEmpty ? " › \(nombreCarpeta)" : ""), divisor: false) {
                        Image(systemName: "externaldrive.fill")
                    }
                }
                if sugerirNombre {
                    Toggle(isOn: $mismoNombre) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(T("Ponerle al portátil el nombre “%@”", hub.nombre)).font(.system(size: 13)).foregroundStyle(Tema.titulo)
                            Text(T("Así, afuera tus proyectos quedan en la misma ubicación (/Volumes/%@/…) y tus apps los encuentran sin cambiar nada. En casa se llama “%@”, para que nunca haya dos discos con el mismo nombre.", hub.nombre, Discos.nombreEnCasa(hub.nombre)))
                                .font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(.switch)
                }
                Label(T("Si querés, después podés cifrar el portátil desde Discos (por si lo perdés)."), systemImage: "lock")
                    .font(.system(size: 12)).foregroundStyle(Tema.apagado)
            }
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

    private var puedeSeguir: Bool { paso == 1 ? hub != nil : (portatil != nil && (!enCarpeta || !nombreCarpeta.isEmpty)) }

    private var sugerirNombre: Bool {
        guard let hub, let portatil, !hub.esEstaMac, hub.subcarpeta.isEmpty, !enCarpeta else { return false }
        return hub.nombre != portatil.nombre
    }

    private func seguir() {
        error = nil
        if paso == 2, let p = portatil, Ajustes.shared.datos.vinculos.contains(where: { $0.portatil.uuid == p.uuid && $0.portatil.subcarpeta == (enCarpeta ? nombreCarpeta : "") }) {
            error = T("Ese portátil ya está en otro vínculo. Usá “Guardar en una carpeta del portátil” para compartirlo.")
            return
        }
        paso += 1
    }

    private func elegirCarpetaDeLaMac() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = T("Usar como hub")
        panel.message = T("Elegí la carpeta donde trabajás (por ejemplo, Proyectos).")
        if panel.runModal() == .OK, let u = panel.url {
            hub = Lugar(uuid: Lugar.estaMac, nombre: "Esta Mac", subcarpeta: u.path)
        }
    }

    private func crear() {
        guard let hub, let p = portatil else { return }
        // Mismo nombre afuera: no se renombra acá; el coordinador le pone "<nombre> (portátil)" mientras esté el hub
        // y el nombre del hub cuando el portátil está solo (ver `Vinculo.nombreAfuera`).
        let usarNombreDelHub = (sugerirNombre && mismoNombre) || p.nombre == hub.nombre
        let carpeta = enCarpeta ? nombreCarpeta.trimmingCharacters(in: .whitespaces) : ""
        if !carpeta.isEmpty { try? FileManager.default.createDirectory(atPath: p.ruta + "/" + carpeta, withIntermediateDirectories: true) }
        var v = Vinculo(hub: hub, portatil: Lugar(uuid: p.uuid, nombre: usarNombreDelHub ? hub.nombre : p.nombre, subcarpeta: carpeta))
        if usarNombreDelHub, Vinculo.discosEnteros(v.hub, v.portatil) { v.nombreAfuera = hub.nombre }
        Ajustes.shared.datos.vinculos.append(v)
        navegacion.vinculo = v.id
        navegacion.pagina = .carpetas
        navegacion.asistente = false
    }

    /// Discos externos montados (también los que Relevo ocultó del Finder).
    static func externos() -> [Volumen] {
        Discos.montados().filter { $0.externo && $0.ruta.hasPrefix("/Volumes/") }
            .sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
    }
}
