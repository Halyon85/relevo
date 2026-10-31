import AppKit
import SwiftUI

struct PaginaDiscos: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var ajustes: Ajustes
    @ObservedObject var navegacion: Navegacion

    var body: some View {
        TituloPagina(titulo: T("Discos"))
        QueEsUnVinculo()
        ForEach(Array(gestor.coordinadores.enumerated()), id: \.element.id) { i, c in
            TarjetaDiscos(coordinador: c, ajustes: ajustes, navegacion: navegacion,
                          numero: gestor.coordinadores.count > 1 ? i + 1 : nil)
        }
        BotonSecundario(texto: gestor.coordinadores.isEmpty ? T("Elegir los discos") : T("Agregar otro vínculo"), icono: "plus") {
            navegacion.asistente = true
        }
        ExpulsarDiscos(gestor: gestor)
    }
}

/// Explicación corta, arriba de todo: qué es un vínculo y que se pueden tener varios.
struct QueEsUnVinculo: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.left.arrow.right.circle.fill").font(.system(size: 20)).foregroundStyle(Tema.acento)
            VStack(alignment: .leading, spacing: 4) {
                Text(T("¿Qué es un vínculo?")).font(.titulo(14)).foregroundStyle(Tema.titulo)
                Text(T("Un par de discos que Relevo mantiene iguales: el disco de casa (o la carpeta de la Mac donde trabajás) y el portátil (el disco que te llevás). Podés tener más de uno: por ejemplo, proyectos en un disco y fotos en otro. Qué carpetas pasan de uno al otro se elige en “Qué se sincroniza”."))
                    .font(.system(size: 12)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
    }
}

/// Un vínculo: arriba los dos discos lado a lado; abajo cómo se cuidan.
struct TarjetaDiscos: View {
    @ObservedObject var coordinador: Coordinador
    @ObservedObject var ajustes: Ajustes
    @ObservedObject var navegacion: Navegacion
    var numero: Int?
    @Estado private var confirmarQuitar = false

    var body: some View {
        if let v = coordinador.vinculo {
            VStack(alignment: .leading, spacing: 12) {
                Tarjeta(titulo: numero.map { T("Vínculo %ld", $0) }) {
                    HStack(alignment: .top, spacing: 0) {
                        LadoDisco(rol: T("Disco de casa"), ayuda: nil, lugar: v.hub, volumen: coordinador.hub,
                                  conectado: coordinador.raizHub != nil) {
                            if let r = coordinador.raizHub { NSWorkspace.shared.open(URL(fileURLWithPath: r)) }
                        }
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(coordinador.conectados ? Tema.exito : Tema.apagado.opacity(0.5))
                            .frame(width: 36).padding(.top, 22)
                        LadoDisco(rol: T("Portátil"), ayuda: nil, lugar: v.portatil, volumen: coordinador.portatil,
                                  conectado: coordinador.portatil != nil) { coordinador.mostrarPortatil() }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 14)
                    Rectangle().fill(Tema.bordeSuave).frame(height: 1).padding(.leading, 16)
                    if let afuera = v.nombreAfuera, Vinculo.discosEnteros(v.hub, v.portatil) {
                        Fila(titulo: T("Nombres del portátil"),
                             detalle: T("Afuera se llama “%@”, como el disco de casa: así tus apps encuentran los proyectos en la misma ubicación. En casa se llama “%@”; si se lo cambiás en el Finder, lo respeto.", afuera, v.nombreEnCasa ?? Discos.nombreEnCasa(afuera))) {
                            EmptyView()
                        }
                    }
                    if !v.portatil.esEstaMac {
                        Fila(titulo: T("En casa, ocultar el portátil del Finder"),
                             detalle: T("Con el disco de casa conectado, el portátil no aparece en la barra lateral del Finder. Ojo: oculto, macOS no anota sus cambios, así que al volver de afuera reviso todos los proyectos y tarda más.")) {
                            Toggle("", isOn: Binding(get: { v.ocultarEnCasa }, set: { n in ajustes.cambiar(v.id) { $0.ocultarEnCasa = n } }))
                                .toggleStyle(.switch).labelsHidden()
                        }
                        FilaCifrado(coordinador: coordinador)
                    }
                    Fila(titulo: T("Revisión a fondo"), detalle: revisionDetalle) {
                        if coordinador.revisionAFondo == nil {
                            BotonSecundario(texto: T("Revisar"), icono: "checkmark.shield") { coordinador.revisarAFondo() }
                                .disabled(!coordinador.conectados).opacity(coordinador.conectados ? 1 : 0.45)
                        }
                    }
                    if confirmarQuitar {
                        Fila(titulo: T("¿Quitar este vínculo?"), detalle: T("Relevo deja de sincronizar este par y olvida su configuración (las carpetas elegidas y qué se oculta). No borra nada de ningún disco, ni la papelera de Relevo."), divisor: false) {
                            BotonSecundario(texto: T("Cancelar")) { confirmarQuitar = false }
                            BotonSecundario(texto: T("Quitar"), peligro: true) { ajustes.datos.vinculos.removeAll { $0.id == v.id } }
                        }
                    } else {
                        Fila(titulo: T("Quitar vínculo"), detalle: T("Deja de sincronizar este par. No borra nada de ningún disco."), divisor: false) {
                            BotonSecundario(texto: T("Quitar"), icono: "minus.circle", peligro: true) { confirmarQuitar = true }
                        }
                    }
                }
                if let r = coordinador.revisionAFondo { VistaRevision(revision: r, coordinador: coordinador) }
                avisos(v)
            }
        }
    }

    private var revisionDetalle: String {
        let base = T("Compara el contenido de cada archivo (no solo fecha y tamaño) para encontrar copias dañadas. Lento: lee todo.")
        if let f = coordinador.ultimaRevisionAFondo { return base + " " + T("Última: %@.", Formato.haceCuanto(f)) }
        return base
    }

    /// Avisos sobre el portátil: formato que no sirve o nombre distinto al del hub.
    @ViewBuilder private func avisos(_ v: Vinculo) -> some View {
        if let p = coordinador.portatil, !p.esEstaMac, !p.formatoDeMac {
            Aviso(icono: "exclamationmark.triangle.fill", color: Tema.error,
                  texto: T("El portátil está en formato %@, que es para Windows: no guarda permisos ni enlaces, y si lo sacás de golpe se puede dañar. Para usarlo con Relevo, pasalo a APFS en la Utilidad de Discos (eso lo borra: primero copiá lo que tenga).", p.formato)) {
                BotonSecundario(texto: T("Abrir Utilidad de Discos"), icono: "externaldrive") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
                }
            }
        }
        if let h = coordinador.hub, coordinador.portatil != nil, Vinculo.discosEnteros(v.hub, v.portatil), v.nombreAfuera == nil {
            Aviso(icono: "lightbulb.fill", color: Tema.acento,
                  texto: T("Si afuera el portátil se llama como el disco de casa (“%@”), tus proyectos quedan en la misma ubicación (/Volumes/%@/…) y tus apps los encuentran sin cambiar nada. En casa se llama “%@”, para no confundirse con el disco de casa.", h.nombre, h.nombre, Discos.nombreEnCasa(h.nombre))) {
                BotonSecundario(texto: T("Usar “%@” afuera", h.nombre), icono: "pencil") {
                    ajustes.cambiar(v.id) { $0.nombreAfuera = h.nombre; $0.portatil.nombre = h.nombre }
                    coordinador.discosCambiaron()
                }
            }
        }
    }
}

/// Un lado del vínculo: qué disco es, si está conectado, formato, tamaño y lugar libre, y "Abrir".
struct LadoDisco: View {
    let rol: String
    let ayuda: String?
    let lugar: Lugar
    let volumen: Volumen?
    let conectado: Bool
    let abrir: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Image(systemName: lugar.esEstaMac ? "laptopcomputer" : "externaldrive.fill")
                        .font(.system(size: 20)).foregroundStyle(conectado ? Tema.titulo : Tema.apagado.opacity(0.5))
                        .frame(width: 30, height: 24)
                    Circle().fill(conectado ? Tema.exito : Tema.apagado.opacity(0.5)).frame(width: 7, height: 7)
                        .overlay(Circle().stroke(Tema.tarjeta, lineWidth: 1.5))
                }
                Text(rol).font(.titulo(14, .semibold)).foregroundStyle(Tema.titulo)
            }
            // El nombre que tiene ahora (el portátil cambia de nombre entre casa y afuera).
            Text(volumen.flatMap { lugar.subcarpeta.isEmpty && !lugar.esEstaMac ? $0.nombre : nil } ?? lugar.descripcion)
                .font(.system(size: 13)).foregroundStyle(Tema.titulo).lineLimit(2)
            Text(datos).font(.system(size: 11)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
            if let ayuda { Text(ayuda).font(.system(size: 11)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true) }
            if conectado {
                BotonSecundario(texto: T("Abrir"), icono: "folder", accion: abrir).padding(.top, 4)
                    .help(T("Abrir en el Finder"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var datos: String {
        guard conectado, let v = volumen else { return T("no conectado") }
        if v.esEstaMac { return T("%@ libres", Formato.bytes(v.libre)) }
        return "\(v.formato) · \(Formato.bytes(v.capacidad)) · " + T("%@ libres", Formato.bytes(v.libre))
    }
}

struct Aviso<B: View>: View {
    let icono: String
    let color: Color
    let texto: String
    @ViewBuilder var boton: B

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icono).foregroundStyle(color)
                Text(texto).font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            }
            boton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
        .overlay(RoundedRectangle(cornerRadius: Tema.radioTarjeta).strokeBorder(color.opacity(0.35)))
    }
}

struct VistaRevision: View {
    @ObservedObject var revision: RevisionAFondo
    @ObservedObject var coordinador: Coordinador

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !revision.terminada {
                Text(T("Revisando a fondo: %@", revision.carpeta)).font(.system(size: 13)).foregroundStyle(Tema.subtitulo)
                ProgressView(value: revision.fraccionCarpetas).tint(Tema.acento)
                BotonSecundario(texto: T("Frenar"), icono: "stop.fill") { revision.cancelador.cancelar() }
            } else if revision.distintos.isEmpty {
                Label(T("Revisión terminada: todo coincide byte a byte."), systemImage: "checkmark.seal.fill")
                    .font(.system(size: 13)).foregroundStyle(Tema.exito)
                BotonSecundario(texto: T("Listo")) { coordinador.cerrarRevision() }
            } else {
                Label(T("%ld archivo(s) no coinciden aunque figuran iguales:", revision.distintos.count), systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13)).foregroundStyle(Tema.acento)
                ForEach(revision.distintos.prefix(20)) { d in
                    Text("\(d.carpeta)/\(d.ruta)").font(.system(size: 12, design: .monospaced)).foregroundStyle(Tema.subtitulo)
                }
                HStack {
                    BotonPrimario(texto: T("Copiarlos de nuevo desde el disco de casa")) { coordinador.repararDesdeHub() }
                    BotonSecundario(texto: T("Ahora no")) { coordinador.cerrarRevision() }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Tema.radioTarjeta).fill(Tema.tarjeta))
    }
}

/// Expulsar varios discos a la vez (todos o los que elijas). Antes copia lo pendiente; si alguno no se puede, dice qué lo usa.
struct ExpulsarDiscos: View {
    @ObservedObject var gestor: Gestor
    @Estado private var discos: [Volumen] = Discos.expulsables()
    @Estado private var elegidos = Set<String>()

    var body: some View {
        Tarjeta(titulo: T("Expulsar discos")) {
            Text(T("Todos los discos externos conectados, de cualquier vínculo. Antes de expulsar un portátil, Relevo copia lo que tenga pendiente. El disco de la Mac no aparece porque no se puede expulsar."))
                .font(.system(size: 12)).foregroundStyle(Tema.apagado).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
            if discos.isEmpty {
                Fila(titulo: T("No hay discos para expulsar"), divisor: false) { EmptyView() }
            }
            ForEach(discos) { v in
                Fila(titulo: gestor.etiqueta(v), detalle: "\(v.formato) · \(Formato.bytes(v.capacidad))") {
                    Casilla(estado: elegidos.contains(v.uuid) ? .si : .no) {
                        if elegidos.contains(v.uuid) { elegidos.remove(v.uuid) } else { elegidos.insert(v.uuid) }
                    }
                }
            }
            Fluir(espacio: 10) {
                BotonPrimario(texto: T("Expulsar todos")) { gestor.expulsar(discos) }
                    .disabled(discos.isEmpty).opacity(discos.isEmpty ? 0.45 : 1)
                BotonSecundario(texto: T("Expulsar elegidos"), icono: "eject") { gestor.expulsar(discos.filter { elegidos.contains($0.uuid) }) }
                    .disabled(elegidos.isEmpty).opacity(elegidos.isEmpty ? 0.45 : 1)
                BotonSecundario(texto: T("Actualizar lista"), icono: "arrow.clockwise") { discos = Discos.expulsables(); elegidos = elegidos.filter { u in discos.contains { $0.uuid == u } } }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
    }
}
