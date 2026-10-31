import AppKit
import SwiftUI

/// Pestaña "Repositorios": tus repos de GitHub (u otro proveedor), bajarlos al hub o al portátil, ver cuáles están
/// atrasados, hacer commit, subir y unir ramas. Todo lo que escribe en git pide confirmación antes.
/// Los del hub salen de buscar carpetas con `.git` un nivel adentro de cada carpeta que se sincroniza; la lista de GitHub,
/// de `gh repo list` con la sesión de `gh` de esta Mac.
struct PaginaRepos: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var navegacion: Navegacion
    @ObservedObject private var repos = Repos.compartido
    @ObservedObject private var ajustes = Ajustes.shared
    @Estado private var busqueda = ""
    @Estado private var busquedaGitHub = ""
    @Estado private var filtro: FiltroRepos = .todos
    @Estado private var direccion = ""
    @Estado private var lado: LadoClon = .hub
    @Estado private var todosLosRemotos = false
    @Estado private var abierto: String?
    @Estado private var porActualizar: RepoLocal?
    /// Grupos que el usuario abrió o cerró (al revés de como arrancan).
    @Estado private var gruposTocados = Set<String>()
    @Estado private var verOcultos = false
    @Estado private var verGitHub = false

    private let topeVisibles = 40

    var body: some View {
        TituloPagina(titulo: T("Repositorios"),
                     subtitulo: T("Bajá tus repositorios al disco de casa o directo al portátil con un clic, y fijate cuáles tienen algo pendiente."))
            .onAppear { repos.cargar(gestor) }

        if let n = repos.novedad { novedad(n) }

        if !repos.herramientasRevisadas || repos.herramientas.git == nil {
            faltaGit
        } else {
            clonar
            locales
            avisoGitHub
            remotos
        }
    }

    // MARK: Novedad (lo último que pasó)

    private func novedad(_ n: Repos.Novedad) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: n.esError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(n.esError ? Tema.error : Tema.exito)
                .font(.system(size: 14))
            Text(n.texto).font(.system(size: 13)).foregroundStyle(Tema.subtitulo)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button { repos.novedad = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Tema.apagado)
            }
            .buttonStyle(.plain)
            .help(T("Cerrar"))
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
    }

    // MARK: git y gh

    @ViewBuilder private var faltaGit: some View {
        if !repos.herramientasRevisadas {
            Tarjeta {
                Fila(titulo: T("Buscando git…"), divisor: false) { ProgressView().controlSize(.small) }
            }
        } else {
            Tarjeta(titulo: T("Falta git")) {
                Fila(titulo: T("git no está instalado"),
                     detalle: T("Lo traen las herramientas de línea de comandos de Apple (o “brew install git”). Después tocá “Revisar de nuevo”.")) {
                    BotonPrimario(texto: T("Instalar")) { Repos.instalarHerramientasApple() }
                }
                Fila(titulo: T("¿Ya lo instalaste?"), divisor: false) {
                    BotonSecundario(texto: T("Revisar de nuevo"), icono: "arrow.clockwise") { repos.cargar(gestor) }
                }
            }
        }
    }

    @ViewBuilder private var avisoGitHub: some View {
        let h = repos.herramientas
        if h.gh == nil || h.ghConSesion != true {
            Tarjeta(titulo: T("Para ver tu lista de GitHub")) {
                if h.gh == nil {
                    filaComando(T("1. Instalá la herramienta de GitHub"), "brew install gh")
                    filaComando(T("2. Iniciá sesión"), "gh auth login")
                } else {
                    filaComando(T("Iniciá sesión en GitHub desde la terminal"), "gh auth login")
                }
                Fila(titulo: T("Sin GitHub también podés clonar pegando el link, arriba."), divisor: false) {
                    BotonSecundario(texto: T("Revisar de nuevo"), icono: "arrow.clockwise") { repos.cargar(gestor) }
                }
            }
        }
    }

    private func filaComando(_ titulo: String, _ comando: String) -> some View {
        Fila(titulo: titulo, detalle: comando) {
            BotonSecundario(texto: T("Copiar"), icono: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(comando, forType: .string)
            }
        }
    }

    // MARK: Clonar con un link (arriba de todo, compacto)

    @ViewBuilder private var clonar: some View {
        let destinos = Repos.destinos(gestor)
        let elegido = repos.destino(gestor)
        let clave = direccion.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    campoLink(clave).frame(minWidth: 200)
                    controlesClon(clave, destinos, elegido)
                }
                VStack(alignment: .leading, spacing: 8) {
                    campoLink(clave)
                    HStack(spacing: 8) { controlesClon(clave, destinos, elegido) }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6).frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
            if !clave.isEmpty || elegido == nil {
                Text(textoAyudaClon(elegido))
                    .font(.system(size: 12)).foregroundStyle(Tema.apagado)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }

    private func campoLink(_ clave: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(Tema.apagado)
            TextField(T("Clonar con un link…"), text: $direccion)
                .textFieldStyle(.plain).font(.system(size: 13, design: direccion.isEmpty ? .default : .monospaced))
                .help(T("Pegá el link del repositorio: https://… o git@… (GitHub, GitLab, Bitbucket…)"))
                .onSubmit(clonarLink)
        }
        .frame(height: 32)
    }

    @ViewBuilder private func controlesClon(_ clave: String, _ destinos: [DestinoClon], _ elegido: DestinoClon?) -> some View {
        if let t = repos.trabajando[clave], !clave.isEmpty {
            ProgressView().controlSize(.small)
            Text(t).font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize()
        } else {
            Segmentos(valor: $lado, opciones: LadoClon.allCases) { $0.nombre }
                .fixedSize()
                .help(T("Dónde queda la copia: en el disco de casa o directo en el portátil."))
            if let elegido {
                menuDestino(destinos, elegido)
            } else {
                BotonSecundario(texto: T("Elegir qué se sincroniza")) { navegacion.pagina = .carpetas }
            }
            BotonPrimario(texto: T("Clonar"), accion: clonarLink)
                .disabled(clave.isEmpty || elegido == nil)
                .opacity(clave.isEmpty || elegido == nil ? 0.5 : 1)
        }
    }

    private func textoAyudaClon(_ d: DestinoClon?) -> String {
        guard d != nil else { return T("Elegí primero qué se sincroniza (por ejemplo, Proyectos) y los repos se clonan ahí.") }
        var t = lado == .portatil ? T("Queda en la misma carpeta del portátil y después Relevo lo copia al disco de casa.")
                                  : T("Queda en el disco de casa y Relevo lo copia al portátil.")
        t += " " + T("Si la carpeta ya existe, no se pisa. Usa tus credenciales de siempre (gh o el llavero de git); Relevo no guarda ninguna clave.")
        return t
    }

    private func clonarLink() {
        guard let d = repos.destino(gestor), !direccion.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        repos.clonar(direccion: direccion, en: d, lado: lado, gestor: gestor)
    }

    private func menuDestino(_ destinos: [DestinoClon], _ elegido: DestinoClon) -> some View {
        Menu {
            ForEach(destinos) { d in
                Button(d.descripcion) { repos.destinoElegido = d.id }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "folder").font(.system(size: 12, weight: .medium))
                Text(elegido.descripcion).font(.titulo(13)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Tema.relleno))
            .foregroundStyle(Tema.titulo)
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(elegido.deAUna ? T("Cada repositorio queda en su propia carpeta y Relevo la copia sola.")
                             : T("Queda adentro de una carpeta que ya se sincroniza entera."))
    }

    // MARK: Buscador

    private func buscador(_ texto: Binding<String>, _ ayuda: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Tema.apagado)
            TextField(ayuda, text: texto)
                .textFieldStyle(.plain).font(.system(size: 13))
            if !texto.wrappedValue.isEmpty {
                Button { texto.wrappedValue = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(Tema.apagado)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 10).fill(Tema.tarjeta))
    }

    private func coincide(_ textos: [String?], con busqueda: String) -> Bool {
        let b = busqueda.trimmingCharacters(in: .whitespaces)
        guard !b.isEmpty else { return true }
        return textos.compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(b) }
    }

    // MARK: En el hub (agrupados por carpeta, con filtros y ocultos)

    private struct Grupo: Identifiable {
        let id: String
        let titulo: String
        var repos: [RepoLocal]
        var pendientes: Int { repos.filter { !$0.alDia }.count }
    }

    private func estaOculto(_ r: RepoLocal) -> Bool { ajustes.datos.reposOcultos.contains(r.claveOculto) }

    private func ocultar(_ r: RepoLocal, _ si: Bool) {
        var lista = ajustes.datos.reposOcultos.filter { $0 != r.claveOculto }
        if si { lista.append(r.claveOculto) }
        ajustes.datos.reposOcultos = lista
        if si, abierto == r.id { abierto = nil }
    }

    /// Los visibles agrupados por carpeta de origen (Proyectos, Clientes…); adentro, primero los que tienen algo pendiente.
    private func grupos(_ lista: [RepoLocal]) -> [Grupo] {
        let hubs = Set(lista.compactMap { gestor.coordinador($0.vinculoID)?.vinculo?.hub.descripcion })
        var porClave: [String: Grupo] = [:]
        for r in lista {
            let clave = r.vinculoID + "|" + r.carpetaPadre
            if porClave[clave] == nil {
                var titulo = r.carpetaPadre.isEmpty ? T("Carpeta principal") : r.carpetaPadre
                if hubs.count > 1, let h = gestor.coordinador(r.vinculoID)?.vinculo?.hub.descripcion { titulo += " · " + h }
                porClave[clave] = Grupo(id: clave, titulo: titulo, repos: [])
            }
            porClave[clave]?.repos.append(r)
        }
        return porClave.values
            .map { g in
                var g = g
                g.repos.sort { a, b in a.alDia != b.alDia ? !a.alDia : a.nombre.localizedStandardCompare(b.nombre) == .orderedAscending }
                return g
            }
            .sorted { $0.titulo.localizedStandardCompare($1.titulo) == .orderedAscending }
    }

    @ViewBuilder private var locales: some View {
        let visibles = repos.locales.filter { !estaOculto($0) }
        let ocultos = repos.locales.filter { estaOculto($0) }
        let lista = visibles.filter { filtro.incluye($0) && coincide([$0.nombre, $0.carpetaPadre, $0.rama], con: busqueda) }
        let gs = grupos(lista)
        let filtrando = filtro != .todos || !busqueda.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(T("En el disco de casa")).font(.titulo(13)).foregroundStyle(Tema.apagado).padding(.leading, 4)
                if repos.revisandoLocales { ProgressView().controlSize(.mini) }
                Spacer()
                if let u = repos.ultimaBusqueda {
                    Text(T("Revisado %@", Formato.haceCuanto(u))).font(.system(size: 11)).foregroundStyle(Tema.apagado)
                }
                if repos.buscandoNovedades {
                    ProgressView().controlSize(.small)
                } else {
                    BotonSecundario(texto: T("Buscar novedades"), icono: "arrow.down.circle") { repos.buscarNovedades(gestor) }
                        .help(T("Pregunta a cada remoto si hay commits nuevos (git fetch). No cambia tus archivos."))
                }
            }
            Text(T("Relevo busca carpetas con git un nivel adentro de cada carpeta que se sincroniza en el disco de casa (por ejemplo, Proyectos/…)."))
                .font(.system(size: 12)).foregroundStyle(Tema.apagado).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
            let filtros = Segmentos(valor: $filtro, opciones: FiltroRepos.allCases) { f in
                T("%@ (%ld)", f.nombre, visibles.filter { f.incluye($0) }.count)
            }
            .fixedSize()
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { filtros; buscador($busqueda, T("Buscar en el disco de casa")).frame(minWidth: 160) }
                VStack(alignment: .leading, spacing: 8) { filtros; buscador($busqueda, T("Buscar en el disco de casa")) }
            }
            Tarjeta {
                if gs.isEmpty {
                    Fila(titulo: visibles.isEmpty ? T("No hay repositorios en el disco de casa") : (filtro == .todos ? T("Ninguno coincide") : T("Nada pendiente acá")),
                         detalle: nil,
                         divisor: false) { EmptyView() }
                }
                ForEach(Array(gs.enumerated()), id: \.element.id) { i, g in
                    // Arrancan abiertos si hay un solo grupo o si se está filtrando o buscando; si no, cerrados.
                    let abiertoDeEntrada = gs.count == 1 || filtrando
                    let grupoAbierto = abiertoDeEntrada != gruposTocados.contains(g.id)
                    cabeceraGrupo(g, abierto: grupoAbierto, divisor: grupoAbierto || i < gs.count - 1) {
                        withAnimation(Tema.expo) {
                            if gruposTocados.contains(g.id) { gruposTocados.remove(g.id) } else { gruposTocados.insert(g.id) }
                        }
                    }
                    if grupoAbierto {
                        ForEach(Array(g.repos.enumerated()), id: \.element.id) { j, r in
                            let ultima = i == gs.count - 1 && j == g.repos.count - 1
                            filaLocal(r, divisor: !ultima || abierto == r.id)
                            if abierto == r.id {
                                DetalleRepo(repo: r, repos: repos, gestor: gestor) { withAnimation(Tema.expo) { ocultar(r, true) } }
                                if !ultima { Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 16) }
                            }
                        }
                    }
                }
            }
            if !ocultos.isEmpty { seccionOcultos(ocultos) }
        }
        .alert(item: $porActualizar) { r in
            Alert(title: Text(T("¿Actualizar %@?", r.nombre)),
                  message: Text(T("Trae %ld commits nuevos del remoto a la rama %@ (git pull --ff-only). Si hay que mezclar, no se toca nada.",
                                  r.atrasados, r.rama ?? "?")),
                  primaryButton: .default(Text(T("Actualizar"))) { repos.actualizar(r, gestor: gestor) },
                  secondaryButton: .cancel(Text(T("Cancelar"))))
        }
    }

    private func cabeceraGrupo(_ g: Grupo, abierto: Bool, divisor: Bool, _ alternar: @escaping () -> Void) -> some View {
        Button(action: alternar) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.apagado)
                        .rotationEffect(.degrees(abierto ? 90 : 0))
                    Image(systemName: "folder").font(.system(size: 13)).foregroundStyle(Tema.subtitulo)
                    Text(g.titulo).font(.titulo(14)).foregroundStyle(Tema.titulo)
                    Text("\(g.repos.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.subtitulo)
                        .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Tema.relleno))
                    Spacer(minLength: 8)
                    if g.pendientes > 0 {
                        Text(T("%ld con algo pendiente", g.pendientes)).font(.system(size: 12)).foregroundStyle(Tema.acento)
                    } else {
                        Text(T("todos al día")).font(.system(size: 12)).foregroundStyle(Tema.exito)
                    }
                }
                .padding(.horizontal, 16).frame(height: 42)
                if divisor { Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 16) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func seccionOcultos(_ ocultos: [RepoLocal]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { withAnimation(Tema.expo) { verOcultos.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(verOcultos ? 90 : 0))
                    Text(T("Ocultos (%ld)", ocultos.count)).font(.titulo(13))
                }
                .foregroundStyle(Tema.apagado).padding(.leading, 4).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Text(T("Repositorios que sacaste de la lista. Siguen en su carpeta y Relevo los sigue copiando; con “Mostrar” vuelven arriba."))
                .font(.system(size: 12)).foregroundStyle(Tema.apagado).padding(.horizontal, 4)
                .fixedSize(horizontal: false, vertical: true)
            if verOcultos {
                Tarjeta {
                    ForEach(Array(ocultos.enumerated()), id: \.element.id) { i, r in
                        Fila(titulo: r.nombre, detalle: r.carpetaPadre.isEmpty ? nil : r.carpetaPadre, divisor: i < ocultos.count - 1) {
                            BotonSecundario(texto: T("Mostrar"), icono: "eye") { ocultar(r, false) }
                        }
                    }
                }
            }
        }
    }

    private func filaLocal(_ r: RepoLocal, divisor: Bool) -> some View {
        Fila(titulo: r.nombre, detalle: detalleLocal(r), divisor: divisor, minimoTexto: 120) {
            if let t = repos.trabajando[r.id] {
                ProgressView().controlSize(.small)
                Text(t).font(.system(size: 12)).foregroundStyle(Tema.apagado)
            } else {
                chip(r)
                if r.atrasados > 0 {
                    BotonPrimario(texto: T("Actualizar")) { porActualizar = r }
                        .help(T("Trae los commits nuevos (git pull --ff-only). Si hay que mezclar, no toca nada."))
                }
            }
            BotonSecundario(texto: abierto == r.id ? T("Cerrar") : T("Detalles"), icono: abierto == r.id ? "chevron.up" : "chevron.down") {
                withAnimation(Tema.expo) { abierto = abierto == r.id ? nil : r.id }
            }
            .help(T("Abrir en el Finder o la Terminal, ver los cambios, hacer commit, unir ramas u ocultarlo."))
        }
    }

    private func detalleLocal(_ r: RepoLocal) -> String {
        var partes = [r.rama ?? T("sin rama")]
        if r.remoto == nil { partes.append(T("sin remoto")) }
        else if !r.tieneSeguimiento { partes.append(T("la rama no sigue a ninguna del remoto")) }
        if let e = r.error { partes.append(e.split(separator: "\n").first.map(String.init) ?? e) }
        return partes.joined(separator: " · ")
    }

    /// Estado corto: al día / cambios sin commit / N sin subir / N atrasados.
    private func chip(_ r: RepoLocal) -> some View {
        let color = r.error != nil ? Tema.error : (r.atrasados > 0 ? Tema.acento : (r.alDia ? Tema.exito : Tema.subtitulo))
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(Self.estadoLocal(r).joined(separator: " · ")).font(.system(size: 12)).foregroundStyle(Tema.subtitulo).lineLimit(1)
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(Capsule().fill(Tema.rellenoSuave))
        .fixedSize()
    }

    static func estadoLocal(_ r: RepoLocal) -> [String] {
        if r.error != nil { return [T("con error")] }
        var p: [String] = []
        if r.cambios > 0 { p.append(T("cambios sin commit")) }
        if r.sinSubir > 0 { p.append(T("%ld sin subir", r.sinSubir)) }
        if r.atrasados > 0 { p.append(r.atrasados == 1 ? T("1 atrasado") : T("%ld atrasados", r.atrasados)) }
        return p.isEmpty ? [T("al día")] : p
    }

    // MARK: En GitHub (plegable, cerrado de entrada, con su buscador)

    @ViewBuilder private var remotos: some View {
        let h = repos.herramientas
        if h.gh != nil, h.ghConSesion == true {
            let lista = repos.remotos.filter { coincide([$0.name, $0.nameWithOwner, $0.description], con: busquedaGitHub) }
            let visibles = todosLosRemotos || !busquedaGitHub.isEmpty ? lista : Array(lista.prefix(topeVisibles))
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button { withAnimation(Tema.expo) { verGitHub.toggle() } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(verGitHub ? 90 : 0))
                            Text(h.cuentaGH.map { T("En GitHub (%@)", $0) } ?? T("En GitHub")).font(.titulo(13))
                            if repos.remotosCargados {
                                Text("\(repos.remotos.count)").font(.system(size: 11, weight: .semibold))
                                    .padding(.horizontal, 7).frame(height: 18).background(Capsule().fill(Tema.relleno))
                            }
                        }
                        .foregroundStyle(Tema.apagado).padding(.leading, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if repos.cargandoRemotos { ProgressView().controlSize(.mini) }
                    Spacer()
                    if verGitHub {
                        BotonSecundario(texto: T("Actualizar lista"), icono: "arrow.clockwise") { repos.cargarRemotos() }
                    }
                }
                Text(T("La lista viene de tu cuenta de GitHub en esta Mac (gh repo list): tus repositorios y los de tus organizaciones."))
                    .font(.system(size: 12)).foregroundStyle(Tema.apagado).padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
                if verGitHub {
                    buscador($busquedaGitHub, T("Buscar en GitHub"))
                    Tarjeta {
                        if let e = repos.errorRemotos {
                            Fila(titulo: T("No pude leer la lista de GitHub"), detalle: e, divisor: false) { EmptyView() }
                        } else if lista.isEmpty {
                            Fila(titulo: repos.cargandoRemotos ? T("Cargando…") : T("Ninguno coincide"), divisor: false) { EmptyView() }
                        }
                        ForEach(Array(visibles.enumerated()), id: \.element.id) { i, r in
                            filaRemoto(r, divisor: i < visibles.count - 1 || visibles.count < lista.count)
                        }
                        if visibles.count < lista.count {
                            Fila(titulo: T("Y %ld más", lista.count - visibles.count), divisor: false) {
                                BotonSecundario(texto: T("Mostrar todos")) { todosLosRemotos = true }
                            }
                        }
                    }
                }
            }
        }
    }

    private func filaRemoto(_ r: RepoRemoto, divisor: Bool) -> some View {
        let enHub = repos.local(de: r)
        var partes: [String] = []
        if r.dueno.lowercased() != (repos.herramientas.cuentaGH ?? "").lowercased() { partes.append(r.dueno) }
        if r.isPrivate { partes.append(T("privado")) }
        if let f = r.actualizado { partes.append(T("actualizado %@", Formato.haceCuanto(f))) }
        if let d = r.description, !d.isEmpty { partes.append(d) }
        return Fila(titulo: r.name, detalle: partes.isEmpty ? nil : partes.joined(separator: " · "), divisor: divisor) {
            if let l = enHub {
                Text(T("Ya está en el disco de casa")).font(.system(size: 12)).foregroundStyle(Tema.exito).fixedSize()
                BotonSecundario(texto: T("Abrir"), icono: "folder") { Repos.abrirEnFinder(l.ruta) }
                    .help(T("Abrir en el Finder"))
            } else if let t = repos.trabajando[r.id] {
                ProgressView().controlSize(.small)
                Text(t).font(.system(size: 12)).foregroundStyle(Tema.apagado)
            } else {
                menuClonar { lado in
                    if let d = repos.destino(gestor) { repos.clonar(r, en: d, lado: lado, gestor: gestor) }
                }
            }
        }
    }

    // MARK: Piezas

    /// "Clonar" con dos opciones: en el hub o en el portátil (en la carpeta elegida arriba).
    private func menuClonar(_ accion: @escaping (LadoClon) -> Void) -> some View {
        let d = repos.destino(gestor)
        let c = d.flatMap { gestor.coordinador($0.vinculoID) }
        return Menu {
            Button(T("Clonar en el disco de casa")) { accion(.hub) }
                .disabled(c?.raizHub == nil)
            Button(T("Clonar en el portátil (después Relevo lo copia al disco de casa)")) { accion(.portatil) }
                .disabled(c?.raizPortatil == nil)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.to.line").font(.system(size: 12, weight: .medium))
                Text(T("Clonar")).font(.titulo(13))
            }
            .padding(.horizontal, 12).frame(height: 32)
            .background(Capsule().fill(Tema.relleno))
            .foregroundStyle(Tema.titulo)
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .disabled(d == nil)
        .help(d.map { T("Se clona en %@", $0.descripcion) } ?? T("Elegí primero qué se sincroniza"))
    }
}

/// Filtros de la lista del hub.
enum FiltroRepos: String, CaseIterable, Identifiable, Hashable {
    case todos, conCambios, sinSubir, atrasados
    var id: String { rawValue }
    var nombre: String {
        switch self {
        case .todos: T("Todos")
        case .conCambios: T("Con cambios")
        case .sinSubir: T("Sin subir")
        case .atrasados: T("Atrasados")
        }
    }
    func incluye(_ r: RepoLocal) -> Bool {
        switch self {
        case .todos: true
        case .conCambios: r.cambios > 0
        case .sinSubir: r.sinSubir > 0
        case .atrasados: r.atrasados > 0
        }
    }
}

// MARK: - Detalle de un repo: cambios, commit, subir y unir ramas

struct DetalleRepo: View {
    let repo: RepoLocal
    @ObservedObject var repos: Repos
    @ObservedObject var gestor: Gestor
    var ocultar: () -> Void

    enum Confirmacion: String, Identifiable { case commit, subir, unir; var id: String { rawValue } }

    @Estado private var archivos: [ArchivoCambiado]?
    @Estado private var ramas: [String] = []
    @Estado private var mensaje = ""
    @Estado private var origen = ""
    @Estado private var destino = ""
    @Estado private var quedarse = true
    @Estado private var trae: Int?
    @Estado private var confirmar: Confirmacion?
    @Estado private var verTodos = false

    private let topeArchivos = 30
    private var ocupado: Bool { repos.trabajando[repo.id] != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            acciones
            cambios
            if repo.remoto != nil && (repo.sinSubir > 0 || !repo.tieneSeguimiento) { subir }
            unir
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tema.rellenoSuave)
        .onAppear(perform: cargar)
        .onChange(of: repo) { _, _ in cargar() }
        .alert(item: $confirmar) { c in alerta(c) }
    }

    private func cargar() {
        repos.cargarDetalle(repo) { a, r in
            archivos = a
            ramas = r
            if !r.contains(destino) {
                destino = ["main", "master"].first { r.contains($0) } ?? repo.rama ?? r.first ?? ""
            }
            if !r.contains(origen) || origen == destino {
                origen = (repo.rama.flatMap { $0 != destino && r.contains($0) ? $0 : nil }) ?? r.first { $0 != destino } ?? ""
            }
            contar()
        }
    }

    private func contar() {
        trae = nil
        guard !origen.isEmpty, !destino.isEmpty, origen != destino else { return }
        repos.contarCommits(repo, origen: origen, destino: destino) { trae = $0 }
    }

    // MARK: Abrir y ocultar

    private var acciones: some View {
        VStack(alignment: .leading, spacing: 6) {
            Fluir(espacio: 8) {
                BotonSecundario(texto: T("Abrir en el Finder"), icono: "folder") { Repos.abrirEnFinder(repo.ruta) }
                BotonSecundario(texto: T("Abrir en la Terminal"), icono: "terminal") { Repos.abrirEnTerminal(repo.ruta) }
                BotonSecundario(texto: T("Ocultar de la lista"), icono: "eye.slash", accion: ocultar)
            }
            Text(T("Ocultar solo lo saca de esta lista y lo pasa a “Ocultos”, abajo de todo. No lo borra y Relevo lo sigue copiando."))
                .font(.system(size: 11)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Cambios sin commit

    @ViewBuilder private var cambios: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("Cambios sin commit")).font(.titulo(13)).foregroundStyle(Tema.apagado)
            if let archivos {
                if archivos.isEmpty {
                    Text(T("No hay cambios: todo está guardado en git.")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                } else {
                    let visibles = verTodos ? archivos : Array(archivos.prefix(topeArchivos))
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(visibles) { a in
                            HStack(spacing: 8) {
                                Text(a.nombreTipo).font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(color(a.tipo))
                                    .frame(width: 84, alignment: .leading)
                                Text(a.ruta).font(.system(size: 12, design: .monospaced)).foregroundStyle(Tema.texto)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        if visibles.count < archivos.count {
                            Button { verTodos = true } label: {
                                Text(T("Y %ld más…", archivos.count - visibles.count)).font(.system(size: 12)).foregroundStyle(Tema.subtitulo)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    HStack(spacing: 10) {
                        TextField(T("Mensaje del commit (qué cambiaste)"), text: $mensaje)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .padding(.horizontal, 10).frame(height: 32)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Tema.tarjeta))
                        let vacio = mensaje.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        BotonPrimario(texto: T("Commit de todo")) { confirmar = .commit }
                            .disabled(vacio || ocupado).opacity(vacio || ocupado ? 0.5 : 1)
                    }
                    Text(T("Bajo tu responsabilidad: guarda en git todos los archivos de la lista (git add -A y git commit)."))
                        .font(.system(size: 11)).foregroundStyle(Tema.apagado)
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func color(_ t: ArchivoCambiado.Tipo) -> Color {
        switch t {
        case .nuevo: Tema.exito
        case .borrado, .conflicto: Tema.error
        case .modificado, .renombrado: Tema.acento
        }
    }

    // MARK: Subir

    private var subir: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(T("Subir al remoto")).font(.titulo(13)).foregroundStyle(Tema.apagado)
                Text(repo.tieneSeguimiento ? T("%ld commits sin subir en %@.", repo.sinSubir, repo.rama ?? "?")
                                           : T("La rama %@ todavía no está en el remoto.", repo.rama ?? "?"))
                    .font(.system(size: 12)).foregroundStyle(Tema.subtitulo)
            }
            Spacer()
            BotonSecundario(texto: T("Subir"), icono: "arrow.up.circle") { confirmar = .subir }
                .disabled(ocupado || repo.rama == nil)
        }
    }

    // MARK: Unir ramas

    @ViewBuilder private var unir: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("Unir ramas")).font(.titulo(13)).foregroundStyle(Tema.apagado)
            if ramas.count < 2 {
                Text(T("Este repositorio tiene una sola rama.")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
            } else {
                Fluir(espacio: 8) {
                    Text(T("Traer")).font(.system(size: 13)).foregroundStyle(Tema.subtitulo)
                    menuRama(origen) { origen = $0; contar() }
                    Image(systemName: "arrow.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Tema.apagado)
                    menuRama(destino) { destino = $0; contar() }
                }
                HStack(spacing: 10) {
                    Text(textoTrae).font(.system(size: 12)).foregroundStyle(Tema.subtitulo)
                    Spacer()
                    BotonPrimario(texto: T("Unir")) { confirmar = .unir }
                        .disabled(!sePuedeUnir).opacity(sePuedeUnir ? 1 : 0.5)
                }
                if let actual = repo.rama, actual != destino {
                    HStack(spacing: 8) {
                        Casilla(estado: quedarse ? .si : .no) { quedarse.toggle() }
                        Text(T("Quedarme en %@ al terminar", actual)).font(.system(size: 12)).foregroundStyle(Tema.subtitulo)
                    }
                }
                if repo.cambios > 0 {
                    Text(T("Primero hacé commit de los cambios: con cambios sin commit no se puede unir."))
                        .font(.system(size: 12)).foregroundStyle(Tema.error)
                }
            }
        }
    }

    private var sePuedeUnir: Bool {
        !ocupado && repo.cambios == 0 && !origen.isEmpty && !destino.isEmpty && origen != destino && (trae ?? 0) > 0
    }

    private var textoTrae: String {
        if origen == destino { return T("Elegí dos ramas distintas.") }
        guard let trae else { return T("Contando commits…") }
        if trae == 0 { return T("%@ no trae nada nuevo para %@.", origen, destino) }
        return trae == 1 ? T("Trae 1 commit.") : T("Trae %ld commits.", trae)
    }

    private func menuRama(_ valor: String, _ elegir: @escaping (String) -> Void) -> some View {
        Menu {
            ForEach(ramas, id: \.self) { r in Button(r) { elegir(r) } }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11, weight: .medium))
                Text(valor.isEmpty ? "—" : valor).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(Capsule().fill(Tema.tarjeta))
            .foregroundStyle(Tema.titulo)
            .contentShape(Capsule())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    // MARK: Confirmaciones (antes de escribir en git)

    private func alerta(_ c: Confirmacion) -> Alert {
        switch c {
        case .commit:
            return Alert(title: Text(T("Vas a guardar en git todos estos cambios")),
                         message: Text(T("Se hace git add -A y un commit en %@ (rama %@) con el mensaje “%@”. %ld archivos. Es bajo tu responsabilidad.",
                                         repo.nombre, repo.rama ?? "?", mensaje, archivos?.count ?? 0)),
                         primaryButton: .default(Text(T("Commit de todo"))) {
                             repos.commitDeTodo(repo, mensaje: mensaje, gestor: gestor) { bien in if bien { mensaje = "" } }
                         },
                         secondaryButton: .cancel(Text(T("Cancelar"))))
        case .subir:
            return Alert(title: Text(T("¿Subir %@ al remoto?", repo.rama ?? "?")),
                         message: Text(T("Se hace git push de la rama %@ de %@. Nunca se fuerza: si el remoto tiene algo que vos no, no se sube nada.",
                                         repo.rama ?? "?", repo.nombre)),
                         primaryButton: .default(Text(T("Subir"))) { repos.subir(repo, gestor: gestor) },
                         secondaryButton: .cancel(Text(T("Cancelar"))))
        case .unir:
            let volver = quedarse && repo.rama != nil && repo.rama != destino
            return Alert(title: Text(T("¿Unir %@ en %@?", origen, destino)),
                         message: Text(T("Trae %ld commits de %@ a %@ (git merge). Si hay conflictos no se cambia nada.", trae ?? 0, origen, destino)
                                       + " " + (volver ? T("Al terminar quedás en %@.", repo.rama ?? "") : T("Al terminar quedás en %@.", destino))),
                         primaryButton: .default(Text(T("Unir"))) {
                             repos.unir(repo, origen: origen, destino: destino, quedarseEnOriginal: volver || repo.rama == destino, gestor: gestor)
                         },
                         secondaryButton: .cancel(Text(T("Cancelar"))))
        }
    }
}
