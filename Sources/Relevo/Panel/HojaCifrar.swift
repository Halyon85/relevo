import AppKit
import LocalAuthentication
import SwiftUI

/// Hoja para cifrar el portátil, en 4 pasos: qué es → la clave (y dónde guardarla) → demostrar que la guardaste →
/// cifrar (con el avance). Si el disco ya está cifrado, muestra "Ver la clave" (pide Touch ID o la contraseña de la Mac).
struct HojaCifrar: View {
    let volumen: Volumen
    let cerrar: () -> Void

    private enum Paso: Int { case cargando, explicar, clave, confirmar, cifrando, verClave }

    @Estado private var paso: Paso = .cargando
    @Estado private var clave = Cifrado.generarClave()
    @Estado private var confirmacion = ""
    @Estado private var estado: EstadoCifrado = .desconocido
    @Estado private var esAPFS = true
    @Estado private var donde: Llavero.Donde?
    @Estado private var error: String?
    @Estado private var copiado = false
    @Estado private var claveVista: String?

    private static let contrasenas = "/System/Applications/Passwords.app"
    private var hayContrasenas: Bool { FileManager.default.fileExists(atPath: Self.contrasenas) }

    private var partes: [String] { (claveVista ?? clave).split(separator: "-").map(String.init) }
    /// La última palabra (la sexta, antes del número): la que se pide para confirmar.
    private var ultimaPalabra: String { partes.count >= 2 ? partes[partes.count - 2] : "" }
    private var confirmada: Bool {
        confirmacion.trimmingCharacters(in: .whitespaces).lowercased() == ultimaPalabra
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            encabezado
            Group {
                switch paso {
                case .cargando: ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 120)
                case .explicar: pasoExplicar
                case .clave: pasoClave
                case .confirmar: pasoConfirmar
                case .cifrando: pasoCifrando
                case .verClave: pasoVerClave
                }
            }
            .transition(.opacity)
            if let e = error {
                Text(e).font(.system(size: 12)).foregroundStyle(Tema.error).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            botones
        }
        .padding(24)
        .frame(width: 520)
        .frame(minHeight: 440)
        .background(Tema.fondo)
        .animation(Tema.expo, value: paso)
        .task { await revisar() }
        .task(id: paso) { await seguirAvance() }
    }

    // MARK: Partes

    private var encabezado: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: paso == .verClave ? "key.fill" : "lock.fill")
                .font(.system(size: 18, weight: .semibold)).foregroundStyle(Tema.acento)
                .frame(width: 36, height: 36)
                .background(Circle().fill(Tema.relleno))
            TituloPagina(titulo: paso == .verClave ? T("La clave del portátil") : T("Cifrar el portátil"),
                         subtitulo: "“\(volumen.nombre)”" + (numeroDePaso.map { " · " + T("paso %ld de 4", $0) } ?? ""))
        }
    }

    private var numeroDePaso: Int? {
        switch paso {
        case .explicar: 1
        case .clave: 2
        case .confirmar: 3
        case .cifrando: 4
        default: nil
        }
    }

    private var pasoExplicar: some View {
        VStack(alignment: .leading, spacing: 10) {
            punto("lock.shield", T("Cifrar es guardar todo el disco bajo llave. Si lo perdés o te lo roban, nadie puede leer lo que tiene."))
            punto("desktopcomputer", T("En esta Mac no cambia nada: Relevo guarda la clave en el llavero y abre el disco sola cada vez que lo enchufás."))
            punto("key", T("En otra Mac te va a pedir la clave. Por eso, en el paso siguiente te la muestro y la guardás en un lugar seguro."))
            punto("clock", T("Cifra en segundo plano: podés seguir usando el disco y cerrar esta ventana. Si lo desenchufás a la mitad, sigue la próxima vez."))
            if !esAPFS {
                Text(ErrorCifrado.noEsAPFS(volumen.formato).mensaje)
                    .font(.system(size: 12)).foregroundStyle(Tema.error).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pasoClave: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(T("Esta es la clave del disco. Son palabras simples, sin tildes, para que la puedas tipear en cualquier teclado."))
                .font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            vistaClave
            HStack(spacing: 8) {
                BotonSecundario(texto: copiado ? T("Copiada") : T("Copiar"), icono: copiado ? "checkmark" : "doc.on.doc") { copiar() }
                BotonSecundario(texto: T("Otra clave"), icono: "arrow.clockwise") {
                    clave = Cifrado.generarClave(); copiado = false; confirmacion = ""
                }
                if hayContrasenas {
                    BotonSecundario(texto: T("Abrir Contraseñas"), icono: "key") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: Self.contrasenas))
                    }
                }
            }
            Tarjeta {
                VStack(alignment: .leading, spacing: 8) {
                    Text(T("Dónde guardarla")).font(.titulo(13)).foregroundStyle(Tema.titulo)
                    Text(T("• Queda sola en el llavero de esta Mac (por eso acá se abre sin pedirla).\n• Guardala también en la app Contraseñas (botón “+”, nombre: “Disco %@”) o anotala en un papel que no viaje con el disco.\n• Si se pierde la clave y no está en ningún lado, lo del disco no se puede recuperar. Pero tranqui: el hub tiene todo, así que se borra el portátil y Relevo lo vuelve a llenar.", volumen.nombre))
                        .font(.system(size: 12)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var pasoConfirmar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(markdown: T("Para estar seguros de que la guardaste: escribí la **última palabra** de la clave (la sexta, antes del número)."))
                .font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                ForEach(Array(partes.enumerated()), id: \.offset) { i, p in
                    Text(i == partes.count - 2 ? "?" : (i == partes.count - 1 ? p : "•••"))
                        .font(.system(size: 13, design: .monospaced)).foregroundStyle(Tema.apagado)
                }
            }
            TextField(T("última palabra"), text: $confirmacion)
                .textFieldStyle(.plain)
                .font(.system(size: 18, design: .monospaced))
                .autocorrectionDisabled()
                .padding(.horizontal, 12).frame(height: 40)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tema.tarjeta))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(confirmada ? Tema.exito : Tema.borde, lineWidth: 1))
                .onSubmit { if confirmada { cifrarAhora() } }
            if !confirmacion.isEmpty && !confirmada {
                Text(T("No coincide. Si no la anotaste, volvé un paso.")).font(.system(size: 12)).foregroundStyle(Tema.apagado)
            }
        }
    }

    private var pasoCifrando: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch estado {
            case .cifrado:
                Label(T("Listo: el disco está cifrado."), systemImage: "checkmark.circle.fill")
                    .font(.titulo(15)).foregroundStyle(Tema.exito)
            case .cifrando(let avance):
                Text(T("Cifrando… %ld %%", Int(avance * 100))).font(.titulo(15)).foregroundStyle(Tema.titulo)
                ProgressView(value: avance).tint(Tema.acento)
            default:
                Text(T("Empezando…")).font(.titulo(15)).foregroundStyle(Tema.titulo)
                ProgressView().progressViewStyle(.linear).tint(Tema.acento)
            }
            Text(T("Podés cerrar esta ventana y seguir usando el disco: macOS sigue cifrando solo."))
                .font(.system(size: 12)).foregroundStyle(Tema.apagado)
            if let donde {
                Text(donde == .icloud
                     ? T("La clave quedó en el llavero de iCloud: la ves también en el iPhone, en Contraseñas.")
                     : T("La clave quedó en el llavero de esta Mac. Si no la pasaste a Contraseñas o a un papel, hacelo ahora."))
                    .font(.system(size: 12)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var pasoVerClave: some View {
        VStack(alignment: .leading, spacing: 12) {
            if claveVista != nil {
                vistaClave
                HStack(spacing: 8) {
                    BotonSecundario(texto: copiado ? T("Copiada") : T("Copiar"), icono: copiado ? "checkmark" : "doc.on.doc") { copiar() }
                    if hayContrasenas {
                        BotonSecundario(texto: T("Abrir Contraseñas"), icono: "key") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: Self.contrasenas))
                        }
                    }
                }
            } else {
                Text(estado == .bloqueado
                     ? T("Este disco está cifrado y cerrado. Para verla, Relevo te pide Touch ID o la contraseña de la Mac.")
                     : T("Este disco está cifrado. Para ver la clave, Relevo te pide Touch ID o la contraseña de la Mac."))
                    .font(.system(size: 13)).foregroundStyle(Tema.subtitulo).fixedSize(horizontal: false, vertical: true)
                if case .cifrando(let avance) = estado {
                    Text(T("Todavía cifrando: %ld %%", Int(avance * 100))).font(.system(size: 12)).foregroundStyle(Tema.apagado)
                    ProgressView(value: avance).tint(Tema.acento)
                }
            }
        }
    }

    /// La clave en grande, palabra por palabra.
    private var vistaClave: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), alignment: .leading, spacing: 8) {
            ForEach(Array(partes.enumerated()), id: \.offset) { i, p in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(i + 1)").font(.system(size: 10, weight: .medium)).foregroundStyle(Tema.apagado)
                    Text(p).font(.system(size: 18, weight: .semibold, design: .monospaced)).foregroundStyle(Tema.titulo)
                        .textSelection(.enabled)
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Tema.tarjeta))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Tema.bordeSuave, lineWidth: 1))
            }
        }
    }

    private func punto(_ icono: String, _ texto: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icono).font(.system(size: 13)).foregroundStyle(Tema.acento).frame(width: 18)
            Text(texto).font(.system(size: 13)).foregroundStyle(Tema.texto).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var botones: some View {
        HStack(spacing: 8) {
            switch paso {
            case .explicar:
                BotonSecundario(texto: T("Cancelar")) { cerrar() }
                Spacer()
                BotonPrimario(texto: T("Siguiente")) { paso = .clave }.disabled(!esAPFS).opacity(esAPFS ? 1 : 0.4)
            case .clave:
                BotonSecundario(texto: T("Atrás")) { paso = .explicar }
                Spacer()
                BotonPrimario(texto: T("Ya la guardé")) { paso = .confirmar }
            case .confirmar:
                BotonSecundario(texto: T("Atrás")) { paso = .clave; confirmacion = "" }
                Spacer()
                BotonPrimario(texto: T("Cifrar")) { cifrarAhora() }.disabled(!confirmada).opacity(confirmada ? 1 : 0.4)
            case .cifrando:
                Spacer()
                BotonPrimario(texto: estado == .cifrado ? T("Listo") : T("Cerrar (sigue solo)")) { cerrar() }
            case .verClave:
                Spacer()
                if claveVista == nil {
                    BotonSecundario(texto: T("Cancelar")) { cerrar() }
                    BotonPrimario(texto: T("Ver la clave")) { pedirPermisoYMostrar() }
                } else {
                    BotonPrimario(texto: T("Listo")) { cerrar() }
                }
            case .cargando:
                Spacer()
                BotonSecundario(texto: T("Cancelar")) { cerrar() }
            }
        }
    }

    // MARK: Acciones

    /// Al abrir: si ya está cifrado (o cifrándose), va directo a "Ver la clave".
    private func revisar() async {
        let v = volumen
        let (e, apfs) = await Task.detached { (Cifrado.estado(uuid: v.uuid), Cifrado.esAPFS(v)) }.value
        estado = e
        esAPFS = apfs
        switch e {
        case .sinCifrar: paso = .explicar
        case .desconocido:
            paso = .explicar
            error = T("No pude leer el estado del disco. ¿Sigue enchufado?")
        default:
            paso = .verClave
            donde = Llavero.donde(v.uuid)
            if donde == nil { error = T("La clave de este disco no está en el llavero de esta Mac (¿se cifró en otra?).") }
        }
    }

    /// Mientras cifra (o si se mira la clave de uno que se está cifrando), mira el avance cada 2 s.
    private func seguirAvance() async {
        guard paso == .cifrando || paso == .verClave else { return }
        let uuid = volumen.uuid
        while !Task.isCancelled {
            let e = await Task.detached { Cifrado.estado(uuid: uuid) }.value
            if Task.isCancelled { return }
            // Recién empezado, diskutil puede tardar un instante en marcarlo: no pisar el "Empezando…" con "sin cifrar".
            if !(paso == .cifrando && e == .sinCifrar) { estado = e }
            if e == .cifrado || e == .bloqueado { return }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func cifrarAhora() {
        guard confirmada else { return }
        error = nil
        // Si ya hay una clave guardada para este UUID, este disco "sin cifrar" no es el que se cifró: podría ser otro con
        // el mismo UUID. No se toca la clave del otro (se perdería la forma de abrirlo).
        if Llavero.donde(volumen.uuid) != nil {
            error = T("Ya hay una clave guardada para un disco con este mismo identificador, y este aparece sin cifrar. No cifré nada para no perder esa clave. Si descifraste el disco a propósito, borrá su clave en la app Llaves y volvé a intentarlo.")
            return
        }
        // Primero la clave al llavero: si no se puede guardar, no se cifra nada.
        guard let d = Llavero.guardar(clave, uuid: volumen.uuid, nombre: volumen.nombre) else {
            error = T("No se pudo guardar la clave en el llavero (error %d). No cifré nada.", Llavero.ultimoError)
            return
        }
        donde = d
        estado = .cifrando(0)
        paso = .cifrando
        let v = volumen, c = clave
        Task {
            let r = await Task.detached { Cifrado.cifrar(v, clave: c) }.value
            if case .failure(let e) = r {
                error = e.mensaje
                // Si no llegó a cifrarse, la clave no sirve: se saca del llavero para no confundir (es la que se acaba
                // de guardar: antes no había ninguna, ver arriba).
                let ahora = await Task.detached { Cifrado.estado(uuid: v.uuid) }.value
                if ahora == .sinCifrar { Llavero.borrar(v.uuid) }
                estado = ahora
                paso = ahora == .sinCifrar ? .confirmar : .cifrando
            }
        }
    }

    private func pedirPermisoYMostrar() {
        error = nil
        let contexto = LAContext()
        contexto.localizedCancelTitle = T("Cancelar")
        let uuid = volumen.uuid
        // macOS arma la frase: "Relevo quiere mostrar la clave del disco …".
        contexto.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: T("mostrar la clave del disco “%@”", volumen.nombre)) { ok, fallo in
            DispatchQueue.main.async {
                guard ok else {
                    if (fallo as? LAError)?.code != .userCancel { error = T("No se pudo comprobar que sos vos.") }
                    return
                }
                if let c = Llavero.leer(uuid) {
                    claveVista = c
                } else {
                    error = T("La clave no está en el llavero de esta Mac.")
                }
            }
        }
    }

    private func copiar() {
        let tablero = NSPasteboard.general
        tablero.clearContents()
        tablero.setString(claveVista ?? clave, forType: .string)
        // Marca de "dato oculto": los gestores de portapapeles no la guardan en su historial.
        tablero.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        copiado = true
    }
}
