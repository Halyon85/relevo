import AppKit
import SwiftUI
import RelevoNucleo

/// Lo que Relevo nunca copia al otro disco, aunque esté adentro de una carpeta que sí se sincroniza. Es la segunda
/// pestaña de "Qué se sincroniza" y se ve igual que la primera: carpetas (elegidas con el Finder, nunca escribiendo
/// nombres) con sus subcarpetas y un tilde. Tildado = no se sincroniza; destildado = vuelve a sincronizarse (queda en
/// la lista para volver a tildarlo cuando quieras).
struct PaginaExcluidas: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var ajustes: Ajustes
    @ObservedObject var navegacion: Navegacion
    @StateObject private var tamanos = Tamanos()
    @Estado private var abiertas = Set<String>()
    @Estado private var avisoElegir: String?

    var body: some View {
        Text(T("Lo que tildes acá no pasa al otro disco: queda solo en el disco donde está. Destildalo para que vuelva a sincronizarse."))
            .font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
        SelectorVinculo(gestor: gestor, navegacion: navegacion)
        if let c = SelectorVinculo.elegido(gestor, navegacion), let v = c.vinculo {
            tuyas(c, v)
        }
        regenerables
        Text(T("Además, nunca se copian los archivos propios de macOS (.DS_Store, papeleras) ni los candados de git: duran un instante y se arman solos."))
            .font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        if ajustes.datos.excluidas.sorted() != DatosAjustes().excluidas.sorted() || !ajustes.datos.excluidasPausadas.isEmpty {
            BotonSecundario(texto: T("Volver a la lista sugerida"), icono: "arrow.uturn.backward") {
                ajustes.datos.excluidas = DatosAjustes().excluidas
                ajustes.datos.excluidasPausadas = []
                ajustes.datos.llevarDependencias = DatosAjustes().llevarDependencias
            }
        }
    }

    // MARK: Tuyas: carpetas y archivos elegidos

    private func tuyas(_ c: Coordinador, _ v: Vinculo) -> some View {
        let elegidas = v.elegidasNunca
        let nombres = (ajustes.datos.excluidas.filter { !Reglas.regenerables.contains($0) } + ajustes.datos.excluidasPausadas)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return Tarjeta(titulo: T("Carpetas y archivos tuyos")) {
            ForEach(elegidas, id: \.self) { e in filaElegida(e, c, v) }
            ForEach(nombres, id: \.self) { n in filaNombre(n) }
            VStack(alignment: .leading, spacing: 6) {
                BotonPrimario(texto: T("Agregar carpeta o archivo…")) { elegir(c, v) }
                    .disabled(c.raizHub == nil).opacity(c.raizHub == nil ? 0.5 : 1)
                Text(avisoElegir ?? (c.raizHub == nil ? T("Conectá el disco de casa para elegir.")
                                                     : T("Se abre el Finder en tus carpetas: elegí lo que no querés sincronizar (por ejemplo, una carpeta de borradores adentro de un proyecto).")))
                    .font(.system(size: 11)).foregroundStyle(avisoElegir == nil ? Tema.apagado : Tema.acento)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .onAppear { if let r = c.raizHub { tamanos.pedir(elegidas.map { r + "/" + $0 }) } }
    }

    /// Un elegido (ruta desde la raíz del disco de casa): tildado = no se sincroniza; con sus subcarpetas al abrirlo.
    private func filaElegida(_ e: String, _ c: Coordinador, _ v: Vinculo) -> some View {
        let estado = Self.estado(e, v)
        let raiz = c.raizHub
        let esCarpeta = raiz.map { r in var d: ObjCBool = false; return FileManager.default.fileExists(atPath: r + "/" + e, isDirectory: &d) && d.boolValue } ?? true
        let hijas = abiertas.contains(e) && esCarpeta ? raiz.map { PaginaCarpetas.carpetas($0 + "/" + e, excluidas: []) } ?? [] : []
        let detalle: String = {
            switch estado {
            case .si: return e + " · " + T("No se sincroniza")
            case .parte: return e + " · " + T("No se sincronizan %ld carpeta(s) de adentro", v.omitidas.filter { $0.hasPrefix(e + "/") }.count)
            case .no: return e + " · " + T("Destildado: se sincroniza")
            }
        }()
        return VStack(spacing: 0) {
            FilaArbol(abierta: abiertas.contains(e), alternar: esCarpeta ? { alternar(e, raiz) } : nil,
                      casilla: estado, tildar: { tildar(e, v, estado) },
                      icono: raiz.map { AnyView(IconoCarpeta(ruta: $0 + "/" + e)) } ?? AnyView(IconoCarpetaGenerica()),
                      titulo: (e as NSString).lastPathComponent, detalle: detalle,
                      derecha: raiz.map { medida($0 + "/" + e) } ?? "") {
                Button { quitarDeLaLista(e, v) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Tema.apagado)
                        .frame(width: 22, height: 22).background(Circle().fill(Tema.relleno))
                }
                .buttonStyle(.plain).help(T("Sacar de la lista (vuelve a sincronizarse)"))
            }
            if abiertas.contains(e) {
                VStack(spacing: 0) {
                    if hijas.isEmpty {
                        Text(T("Sin subcarpetas")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 66).padding(.vertical, 8)
                    }
                    ForEach(hijas, id: \.self) { h in
                        let ruta = e + "/" + h
                        // Si la de arriba ya no se sincroniza entera, las de adentro tampoco (se ven tildadas y quietas).
                        let tildada = estado == .si || v.omitidas.contains(ruta)
                        HStack(spacing: 10) {
                            Casilla(estado: tildada ? .si : .no) { tildarHija(ruta, v) }
                                .disabled(estado == .si).opacity(estado == .si ? 0.5 : 1)
                            if let raiz { IconoCarpeta(ruta: raiz + "/" + ruta) }
                            Text(h).font(.system(size: 13)).foregroundStyle(tildada ? Tema.titulo : Tema.subtitulo)
                            Spacer()
                            if let raiz { Text(medida(raiz + "/" + ruta)).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tema.apagado) }
                        }
                        .padding(.leading, 38).padding(.trailing, 12).padding(.vertical, 6)
                    }
                }
                .background(Tema.rellenoSuave)
            }
            Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 12)
        }
    }

    /// Un nombre que se saltea en cualquier lugar (como "Cosas mías"): tildado = no se sincroniza.
    private func filaNombre(_ n: String) -> some View {
        let activo = ajustes.datos.excluidas.contains(n)
        return VStack(spacing: 0) {
            FilaArbol(abierta: false, alternar: nil, casilla: activo ? .si : .no, tildar: { tildarNombre(n, activo) },
                      icono: AnyView(IconoCarpetaGenerica()), titulo: n,
                      detalle: n == DatosAjustes.cosasMias ? T("Cualquier carpeta que se llame así, en cualquier disco: para guardar lo tuyo sin que pase al otro.")
                                                           : T("Cualquier carpeta que se llame así, en cualquier lugar."),
                      derecha: "") { EmptyView() }
            Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 12)
        }
    }

    // MARK: Se regeneran solas

    private static let dependencias = Reglas.regenerables.filter { Reglas.dependencias.contains($0) }
    private static let compilados = Reglas.regenerables.filter { !Reglas.dependencias.contains($0) }

    private var regenerables: some View {
        let llevar = ajustes.datos.llevarDependencias
        let enLista = Self.compilados.filter { ajustes.datos.excluidas.contains($0) }
        let estadoCompilados: Casilla.Estado = enLista.count == Self.compilados.count ? .si : (enLista.isEmpty ? .no : .parte)
        return Tarjeta(titulo: T("Se regeneran solas")) {
            grupo("dependencias", titulo: T("Dependencias"),
                  detalle: llevar ? T("Se sincronizan: afuera tus proyectos andan sin volver a bajarlas (ocupan más lugar).")
                                  : T("No se sincronizan: afuera se bajan de nuevo (pnpm install, pip, pod install)."),
                  casilla: llevar ? .no : .si, tildar: { ajustes.datos.llevarDependencias.toggle() },
                  nombres: Self.dependencias) { _ in llevar ? .no : .si }
            grupo("compilados", titulo: T("Compilados y cachés"),
                  detalle: T("Se arman de nuevo al compilar o al abrir el proyecto."),
                  casilla: estadoCompilados, tildar: {
                      if estadoCompilados == .si { ajustes.datos.excluidas.removeAll { Self.compilados.contains($0) } }
                      else { ajustes.datos.excluidas += Self.compilados.filter { !ajustes.datos.excluidas.contains($0) } }
                  }, nombres: Self.compilados, tildarNombre: { n in tildarNombre(n, ajustes.datos.excluidas.contains(n), regenerable: true) }) { n in
                ajustes.datos.excluidas.contains(n) ? .si : .no
            }
            VStack(spacing: 0) {
                FilaArbol(abierta: false, alternar: nil, casilla: ajustes.datos.respetarGitignore ? .si : .no,
                          tildar: { ajustes.datos.respetarGitignore.toggle() },
                          icono: AnyView(Image(systemName: "arrow.triangle.branch").font(.system(size: 13)).frame(width: 20, height: 20).foregroundStyle(Tema.subtitulo)),
                          titulo: T("Lo que ignora git"),
                          detalle: T("Lo que el .gitignore de cada proyecto deja afuera (dist, coverage, logs…). Los .env se sincronizan igual. Necesita git."),
                          derecha: "") { EmptyView() }
                    .disabled(Git.ruta == nil).opacity(Git.ruta == nil ? 0.5 : 1)
            }
        }
    }

    /// Un grupo plegable de nombres (dependencias o compilados), con su tilde y el de cada nombre.
    private func grupo(_ id: String, titulo: String, detalle: String, casilla: Casilla.Estado, tildar: @escaping () -> Void,
                       nombres: [String], tildarNombre: ((String) -> Void)? = nil,
                       estadoDe: @escaping (String) -> Casilla.Estado) -> some View {
        VStack(spacing: 0) {
            FilaArbol(abierta: abiertas.contains(id), alternar: { alternar(id, nil) }, casilla: casilla, tildar: tildar,
                      icono: AnyView(IconoCarpetaGenerica()), titulo: titulo,
                      detalle: detalle + " " + nombres.prefix(4).joined(separator: ", ") + (nombres.count > 4 ? "…" : ""),
                      derecha: "") { EmptyView() }
            if abiertas.contains(id) {
                VStack(spacing: 0) {
                    ForEach(nombres, id: \.self) { n in
                        HStack(spacing: 10) {
                            Casilla(estado: estadoDe(n)) { tildarNombre?(n) }
                                .disabled(tildarNombre == nil).opacity(tildarNombre == nil ? 0.5 : 1)
                            IconoCarpetaGenerica()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(n).font(.system(size: 13, design: .monospaced)).foregroundStyle(Tema.titulo)
                                if let e = Self.explicacion(n) { Text(e).font(.system(size: 11)).foregroundStyle(Tema.apagado) }
                            }
                            Spacer()
                        }
                        .padding(.leading, 38).padding(.trailing, 12).padding(.vertical, 6)
                    }
                }
                .background(Tema.rellenoSuave)
            }
            Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 12)
        }
    }

    // MARK: Acciones

    private func alternar(_ id: String, _ raiz: String?) {
        withAnimation(Tema.expo) {
            if abiertas.contains(id) { abiertas.remove(id) } else {
                abiertas.insert(id)
                if let raiz { tamanos.pedir(PaginaCarpetas.carpetas(raiz + "/" + id, excluidas: []).map { raiz + "/" + id + "/" + $0 }) }
            }
        }
    }

    static func estado(_ e: String, _ v: Vinculo) -> Casilla.Estado {
        if v.omitidas.contains(e) { return .si }
        return v.omitidas.contains { $0.hasPrefix(e + "/") } ? .parte : .no
    }

    /// Tildar uno elegido: no se sincroniza entero. Destildarlo: vuelve a sincronizarse (sigue en la lista).
    private func tildar(_ e: String, _ v: Vinculo, _ estado: Casilla.Estado) {
        ajustes.cambiar(v.id) { v in
            v.omitidas.removeAll { $0 == e || $0.hasPrefix(e + "/") }
            if estado != .si { v.omitidas.append(e) }
        }
    }

    private func tildarHija(_ ruta: String, _ v: Vinculo) {
        ajustes.cambiar(v.id) { v in
            if v.omitidas.contains(ruta) { v.omitidas.removeAll { $0 == ruta } } else { v.omitidas.append(ruta) }
        }
    }

    private func quitarDeLaLista(_ e: String, _ v: Vinculo) {
        ajustes.cambiar(v.id) { v in
            v.elegidasNunca.removeAll { $0 == e }
            v.omitidas.removeAll { $0 == e || $0.hasPrefix(e + "/") }
        }
    }

    /// Un nombre: tildado = está en la lista de "nunca"; destildado = queda guardado para volver a tildarlo.
    private func tildarNombre(_ n: String, _ activo: Bool, regenerable: Bool = false) {
        if activo {
            ajustes.datos.excluidas.removeAll { $0 == n }
            if !regenerable, !ajustes.datos.excluidasPausadas.contains(n) { ajustes.datos.excluidasPausadas.append(n) }
        } else {
            if !ajustes.datos.excluidas.contains(n) { ajustes.datos.excluidas.append(n) }
            ajustes.datos.excluidasPausadas.removeAll { $0 == n }
        }
    }

    /// Abre el Finder en el disco de casa. Valen carpetas y archivos de adentro de lo que se sincroniza.
    private func elegir(_ c: Coordinador, _ v: Vinculo) {
        guard let raiz = c.raizHub else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: raiz)
        panel.prompt = T("No sincronizar")
        panel.message = T("Elegí las carpetas o archivos que no querés sincronizar.")
        guard panel.runModal() == .OK else { return }
        let bases = v.carpetas.filter { !$0.hasSuffix("/.") }.map(Coordinador.base)
        var afuera: [String] = [], enteras: [String] = []
        for u in panel.urls {
            let ruta = u.standardizedFileURL.path
            guard ruta.hasPrefix(raiz + "/") else { afuera.append(u.lastPathComponent); continue }
            let rel = String(ruta.dropFirst(raiz.count + 1))
            if bases.contains(rel) { enteras.append(rel); continue }
            guard bases.contains(where: { rel.hasPrefix($0 + "/") }) else { afuera.append(rel); continue }
            ajustes.cambiar(v.id) { v in
                if !v.elegidasNunca.contains(rel) { v.elegidasNunca.append(rel) }
                v.omitidas.removeAll { $0.hasPrefix(rel + "/") }
                if !v.omitidas.contains(rel) { v.omitidas.append(rel) }
            }
            tamanos.pedir([raiz + "/" + rel])
        }
        if !enteras.isEmpty {
            avisoElegir = T("%@ se sincroniza entera: destildala en “Carpetas que se sincronizan”.", enteras.joined(separator: ", "))
        } else if !afuera.isEmpty {
            avisoElegir = T("%@ no se sincroniza: está afuera de lo que tildaste.", afuera.joined(separator: ", "))
        } else {
            avisoElegir = nil
        }
    }

    private func medida(_ ruta: String) -> String {
        guard let m = tamanos.medidas[ruta] else { return "…" }
        return Formato.bytes(m.bytes) + " · " + T("%@ arch.", Formato.numero(m.archivos))
    }

    static func explicacion(_ n: String) -> String? {
        switch n {
        case "node_modules", ".pnpm-store": T("Dependencias de JavaScript")
        case ".venv", "venv": T("Entorno de Python")
        case "__pycache__": T("Caché de Python")
        case ".next", ".nuxt", ".turbo", ".svelte-kit", ".parcel-cache", ".expo": T("Compilados y cachés de sitios web")
        case ".build", "DerivedData": T("Compilados de Swift y Xcode")
        case "Pods": T("Dependencias de iOS")
        case ".gradle": T("Caché de Android")
        default: nil
        }
    }
}

/// Una fila del árbol de carpetas, con la misma forma en las dos pestañas de "Qué se sincroniza": flecha para abrir
/// (si tiene adentro), tilde, ícono, nombre con su detalle y, a la derecha, el tamaño y lo que haga falta.
struct FilaArbol<Extra: View>: View {
    let abierta: Bool
    let alternar: (() -> Void)?
    let casilla: Casilla.Estado
    let tildar: () -> Void
    let icono: AnyView
    let titulo: String
    let detalle: String
    let derecha: String
    @ViewBuilder var extra: Extra

    var body: some View {
        HStack(spacing: 10) {
            if let alternar {
                Button(action: alternar) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        .rotationEffect(.degrees(abierta ? 90 : 0))
                        .frame(width: 16, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(Tema.apagado)
            } else {
                Color.clear.frame(width: 16, height: 24)
            }
            Casilla(estado: casilla, accion: tildar)
            icono
            VStack(alignment: .leading, spacing: 2) {
                Text(titulo).font(.titulo(14, .regular)).foregroundStyle(Tema.titulo)
                Text(detalle).font(.system(size: 11)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if !derecha.isEmpty {
                Text(derecha).font(.system(size: 12).monospacedDigit()).foregroundStyle(Tema.apagado).fixedSize()
            }
            extra
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { alternar?() }
    }
}
