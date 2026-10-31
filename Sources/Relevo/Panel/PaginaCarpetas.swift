import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers
import RelevoNucleo

/// Tamaños de carpetas, medidos de a una en segundo plano (la primera vez tarda; después queda en memoria
/// mientras el panel está abierto).
final class Tamanos: ObservableObject {
    struct Medida { let archivos: Int; let bytes: Int64 }
    @Published private(set) var medidas: [String: Medida] = [:]
    private var pedidas = Set<String>()
    private let cola = DispatchQueue(label: "team.halyon.relevo.tamanos", qos: .utility)
    private var cerrado = false

    deinit { cerrado = true }

    func pedir(_ rutas: [String]) {
        let nuevas = rutas.filter { !pedidas.contains($0) }
        guard !nuevas.isEmpty else { return }
        pedidas.formUnion(nuevas)
        let reglas = Ajustes.shared.reglas
        cola.async { [weak self] in
            for r in nuevas {
                guard let self, !self.cerrado else { return }
                let m = Medidor.medir(r, reglas: reglas) { [weak self] in self?.cerrado ?? true }
                DispatchQueue.main.async { self.medidas[r] = Medida(archivos: m.archivos, bytes: m.bytes) }
            }
        }
    }
}

struct PaginaCarpetas: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var ajustes: Ajustes
    @ObservedObject var navegacion: Navegacion
    @StateObject private var tamanos = Tamanos()
    @Estado private var abiertas = Set<String>()

    /// Lo que nunca tiene sentido llevar (carpetas del sistema si el hub es la Mac, o de los discos).
    static let delSistema: Set<String> = ["Applications", "Library", "System", "Users", "Volumes", "private", "cores", "opt",
                                          "usr", "bin", "sbin", "etc", "var", "tmp", "dev"]

    var body: some View {
        TituloPagina(titulo: T("Qué se sincroniza"))
        Segmentos(valor: $navegacion.pestanaReleva, opciones: PestanaReleva.allCases) { $0.nombre }.fixedSize()
        if navegacion.pestanaReleva == .nunca {
            PaginaExcluidas(gestor: gestor, ajustes: ajustes, navegacion: navegacion)
        } else {
            carpetasQueSeRelevan
        }
    }

    @ViewBuilder private var carpetasQueSeRelevan: some View {
        Text(T("Tildá las carpetas que querés tener iguales en los dos discos. Van con todo lo de adentro, también lo oculto (.env, .git), y en la misma ubicación. Lo que no tildes queda solo en su disco."))
            .font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
        SelectorVinculo(gestor: gestor, navegacion: navegacion)

        if let c = SelectorVinculo.elegido(gestor, navegacion), let v = c.vinculo {
            if let raiz = c.raizHub {
                let lista = Self.carpetas(raiz, excluidas: Set(ajustes.excluidasEfectivas))
                resumen(c, v, raiz: raiz)
                Tarjeta(titulo: T("Todas tus carpetas")) {
                    if lista.isEmpty {
                        Fila(titulo: T("No hay carpetas"), detalle: T("Creá carpetas en el disco de casa y aparecen acá."), divisor: false) { EmptyView() }
                    }
                    ForEach(Array(lista.enumerated()), id: \.element) { i, nombre in
                        filaRaiz(nombre, raiz: raiz, v: v, ultima: i == lista.count - 1)
                    }
                }
                .onAppear { tamanos.pedir(lista.map { raiz + "/" + $0 }) }
            } else {
                Tarjeta {
                    Fila(titulo: T("Conectá el disco de casa para elegir"), detalle: T("Las carpetas se leen del disco de casa (%@).", v.hub.descripcion), divisor: false) { EmptyView() }
                }
            }
        } else {
            Tarjeta {
                Fila(titulo: T("Todavía no hay discos elegidos"), divisor: false) {
                    BotonPrimario(texto: T("Empezar")) { navegacion.asistente = true }
                }
            }
        }
    }

    // MARK: Filas

    private func filaRaiz(_ nombre: String, raiz: String, v: Vinculo, ultima: Bool) -> some View {
        let estado = Self.estado(nombre, v)
        let hijas = abiertas.contains(nombre) ? Self.carpetas(raiz + "/" + nombre, excluidas: Set(ajustes.excluidasEfectivas)) : []
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { alternarAbierta(nombre, raiz: raiz) } label: {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(abiertas.contains(nombre) ? 90 : 0))
                        .frame(width: 16, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Tema.apagado)
                Casilla(estado: estado) { cambiarRaiz(nombre, v, encender: estado == .no) }
                IconoCarpeta(ruta: raiz + "/" + nombre)
                VStack(alignment: .leading, spacing: 2) {
                    Text(nombre).font(.titulo(14, .regular)).foregroundStyle(Tema.titulo)
                    Text(detalle(nombre, v: v, estado: estado)).font(.system(size: 11)).foregroundStyle(Tema.apagado)
                }
                Spacer()
                Text(medida(raiz + "/" + nombre)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tema.apagado)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { alternarAbierta(nombre, raiz: raiz) }

            if abiertas.contains(nombre) {
                VStack(spacing: 0) {
                    if hijas.isEmpty {
                        Text(T("Sin subcarpetas")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 66).padding(.vertical, 8)
                    }
                    ForEach(hijas, id: \.self) { hija in
                        let ruta = nombre + "/" + hija
                        let encendida = Self.hijaEncendida(ruta, padre: nombre, v)
                        HStack(spacing: 10) {
                            Casilla(estado: encendida ? .si : .no) { cambiarHija(ruta, padre: nombre, v, encender: !encendida) }
                            IconoCarpeta(ruta: raiz + "/" + ruta)
                            Text(hija).font(.system(size: 13)).foregroundStyle(encendida ? Tema.titulo : Tema.subtitulo)
                            Spacer()
                            Text(medida(raiz + "/" + ruta)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tema.apagado)
                        }
                        .padding(.leading, 38).padding(.trailing, 12).padding(.vertical, 6)
                    }
                }
                .background(Tema.rellenoSuave)
            }
            if !ultima { Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 12) }
        }
    }

    private func detalle(_ nombre: String, v: Vinculo, estado: Casilla.Estado) -> String {
        switch estado {
        case .no:
            let sueltas = v.carpetas.filter { $0.hasPrefix(nombre + "/") && !$0.hasSuffix("/*") && !$0.hasSuffix("/.") }.count
            return sueltas > 0 ? T("Se sincronizan %ld carpeta(s) de adentro", sueltas) : T("No se sincroniza")
        case .si: return T("Se sincroniza todo (y lo nuevo que crees adentro)")
        case .parte:
            // Entera pero sin algunos proyectos, o no entera pero con algunas de adentro tildadas.
            guard v.carpetas.contains(nombre) || v.carpetas.contains(nombre + "/*") else {
                let sueltas = v.carpetas.filter { $0.hasPrefix(nombre + "/") && !$0.hasSuffix("/*") && !$0.hasSuffix("/.") }.count
                return T("Se sincronizan %ld carpeta(s) de adentro", sueltas)
            }
            // Solo los proyectos destildados acá (lo de más adentro se maneja en "Lo que nunca se sincroniza").
            let fuera = v.omitidas.filter { $0.padreDeRuta == nombre }.count
            return T("Se sincroniza todo menos %ld carpeta(s)", fuera)
        }
    }

    private func medida(_ ruta: String) -> String {
        guard let m = tamanos.medidas[ruta] else { return "…" }
        return Formato.bytes(m.bytes) + " · " + T("%@ arch.", Formato.numero(m.archivos))
    }

    private func alternarAbierta(_ nombre: String, raiz: String) {
        withAnimation(Tema.expo) {
            if abiertas.contains(nombre) { abiertas.remove(nombre) } else {
                abiertas.insert(nombre)
                tamanos.pedir(Self.carpetas(raiz + "/" + nombre, excluidas: Set(ajustes.excluidasEfectivas)).map { raiz + "/" + nombre + "/" + $0 })
            }
        }
    }

    // MARK: Resumen y notas

    private func resumen(_ c: Coordinador, _ v: Vinculo, raiz: String) -> some View {
        var bytes: Int64 = 0, archivos = 0, completo = true
        for e in v.carpetas {
            let base = Coordinador.base(e)
            if e.hasSuffix("/.") { continue }
            guard let m = tamanos.medidas[raiz + "/" + base] else { completo = false; continue }
            bytes += m.bytes; archivos += m.archivos
        }
        for o in v.omitidas {
            if let m = tamanos.medidas[raiz + "/" + o] { bytes -= m.bytes; archivos -= m.archivos }
        }
        let libre = c.portatil?.libre
        return Tarjeta {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(v.carpetas.isEmpty ? T("Todavía no elegiste nada") :
                            T("Se sincroniza %@ en %@ archivos", Formato.bytes(max(0, bytes)), Formato.numero(max(0, archivos))) + (completo ? "" : " " + T("(midiendo…)")))
                        .font(.titulo(14, .semibold)).foregroundStyle(Tema.titulo)
                    Spacer()
                    if let libre { Text(T("%@ libres en el portátil", Formato.bytes(libre))).font(.system(size: 12)).foregroundStyle(Tema.apagado) }
                }
                // Antes de la primera copia: si lo elegido no entra en el portátil, se dice ahora (y no a mitad de copia).
                if let libre, c.ultima == nil, completo, bytes > libre {
                    Label(T("No entra: elegiste %@ y en el portátil hay %@ libres. Destildá algo para que entre.", Formato.bytes(bytes), Formato.bytes(libre)),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Tema.error).fixedSize(horizontal: false, vertical: true)
                }
                if let libre, let total = c.portatil?.capacidad, total > 0 {
                    GeometryReader { g in
                        let usado = Double(total - libre) / Double(total)
                        ZStack(alignment: .leading) {
                            Capsule().fill(Tema.relleno)
                            Capsule().fill(Tema.acento).frame(width: max(4, g.size.width * min(1, usado)))
                        }
                    }
                    .frame(height: 6)
                }
            }
            .padding(16)
        }
    }

    // MARK: Modelo

    static func carpetas(_ ruta: String, excluidas: Set<String>) -> [String] {
        let nombres = (try? FileManager.default.contentsOfDirectory(atPath: ruta)) ?? []
        return nombres.filter { n in
            // Las apps (.app) son carpetas para macOS, pero no tiene sentido mostrarlas como carpetas de trabajo.
            guard !n.hasPrefix("."), !n.hasSuffix(".app"), !delSistema.contains(n), !excluidas.contains(n) else { return false }
            var esCarpeta: ObjCBool = false
            return FileManager.default.fileExists(atPath: ruta + "/" + n, isDirectory: &esCarpeta) && esCarpeta.boolValue
        }
        .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    static func estado(_ nombre: String, _ v: Vinculo) -> Casilla.Estado {
        let entera = v.carpetas.contains(nombre) || v.carpetas.contains(nombre + "/*")
        guard entera else {
            return v.carpetas.contains { $0.hasPrefix(nombre + "/") && !$0.hasSuffix("/.") } ? .parte : .no
        }
        return v.omitidas.contains { $0.padreDeRuta == nombre } ? .parte : .si
    }

    static func hijaEncendida(_ ruta: String, padre: String, _ v: Vinculo) -> Bool {
        if v.carpetas.contains(padre) || v.carpetas.contains(padre + "/*") { return !v.omitidas.contains(ruta) }
        return v.carpetas.contains(ruta)
    }

    /// Tildar una carpeta de la raíz = cada carpeta de adentro por separado (más rápido), sus archivos sueltos y
    /// las carpetas nuevas que aparezcan.
    private func cambiarRaiz(_ nombre: String, _ v: Vinculo, encender: Bool) {
        ajustes.cambiar(v.id) { v in
            v.carpetas.removeAll { $0 == nombre || $0 == nombre + "/*" || $0 == nombre + "/." || $0.hasPrefix(nombre + "/") }
            // Lo elegido en "Lo que nunca se sincroniza" (más adentro) se respeta.
            v.omitidas.removeAll { $0.padreDeRuta == nombre }
            if encender { v.carpetas += [nombre + "/*", nombre + "/."] }
        }
    }

    private func cambiarHija(_ ruta: String, padre: String, _ v: Vinculo, encender: Bool) {
        ajustes.cambiar(v.id) { v in
            if v.carpetas.contains(padre) {
                // Formato viejo ("la carpeta entera"): pasa al nuevo para poder sacar una de adentro.
                v.carpetas.removeAll { $0 == padre }
                v.carpetas += [padre + "/*", padre + "/."]
            }
            if v.carpetas.contains(padre + "/*") {
                if encender { v.omitidas.removeAll { $0 == ruta } } else if !v.omitidas.contains(ruta) { v.omitidas.append(ruta) }
            } else {
                if encender { if !v.carpetas.contains(ruta) { v.carpetas.append(ruta) } } else { v.carpetas.removeAll { $0 == ruta } }
            }
        }
    }
}

/// Casilla de tres estados (sí, no, una parte), con el estilo de la app.
struct Casilla: View {
    enum Estado { case si, no, parte }
    let estado: Estado
    let accion: () -> Void

    var body: some View {
        Button(action: accion) {
            ZStack {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(estado == .no ? Color.clear : Tema.acento)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(estado == .no ? Tema.borde : .clear, lineWidth: 1.5))
                if estado != .no {
                    Image(systemName: estado == .si ? "checkmark" : "minus").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// El ícono de una carpeta cualquiera (para nombres que no son una carpeta en particular).
struct IconoCarpetaGenerica: View {
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(for: .folder)).resizable().interpolation(.high).frame(width: 20, height: 20)
    }
}

/// El ícono real de la carpeta (el mismo del Finder).
struct IconoCarpeta: View {
    let ruta: String
    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: ruta)).resizable().interpolation(.high).frame(width: 20, height: 20)
    }
}
