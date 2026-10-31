import SwiftUI

/// Cifrar el portátil (opcional): si lo perdés, nadie puede leerlo. En esta Mac se abre solo con la clave del llavero.
/// Es una fila de la tarjeta del vínculo, en Discos.
struct FilaCifrado: View {
    @ObservedObject var coordinador: Coordinador
    @Estado private var estado: EstadoCifrado = .desconocido
    @Estado private var hoja = false

    var body: some View {
        if let p = coordinador.portatil, !p.esEstaMac {
            Fila(titulo: titulo, detalle: detalle(p)) {
                switch estado {
                case .sinCifrar:
                    BotonSecundario(texto: T("Cifrar…"), icono: "lock") { hoja = true }
                        .disabled(!p.formatoDeMac).opacity(p.formatoDeMac ? 1 : 0.45)
                case .cifrado, .cifrando:
                    BotonSecundario(texto: T("Ver la clave"), icono: "key") { hoja = true }
                default:
                    EmptyView()
                }
            }
            .onAppear { actualizar(p) }
            .task(id: p.uuid) {
                // Mientras cifra, el avance se actualiza cada 2 segundos.
                while !Task.isCancelled {
                    actualizar(p)
                    guard case .cifrando = estado else { break }
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            }
            .sheet(isPresented: $hoja, onDismiss: { actualizar(p) }) {
                HojaCifrar(volumen: p) { hoja = false }
            }
        } else {
            Fila(titulo: T("Cifrado del portátil"), detalle: T("Conectá el portátil para ver si está cifrado o para cifrarlo.")) { EmptyView() }
        }
    }

    private var titulo: String {
        switch estado {
        case .sinCifrar: T("El portátil no está cifrado")
        case .cifrando(let f): T("Cifrando el portátil… %ld %%", Int(f * 100))
        case .cifrado: T("El portátil está cifrado")
        case .bloqueado: T("El portátil está cifrado y cerrado")
        case .desconocido: T("Revisando si está cifrado…")
        }
    }

    private func detalle(_ p: Volumen) -> String {
        switch estado {
        case .sinCifrar:
            return p.formatoDeMac
                ? T("Si perdés el disco, cualquiera puede leer lo que tiene (incluidas claves de tus proyectos). Cifrarlo es opcional: en esta Mac se abre solo; en otra te pide la clave.")
                : T("Para cifrarlo, el disco tiene que estar en formato APFS.")
        case .cifrando: return T("Podés seguir usándolo mientras tanto. Si lo desenchufás, sigue la próxima vez.")
        case .cifrado:
            let donde = Llavero.donde(p.uuid) == nil ? T("No está en el llavero de esta Mac: guardala.") : T("La clave está en el llavero de esta Mac.")
            return T("Si lo perdés, nadie puede leerlo. %@ En otra Mac te la pide al enchufarlo.", donde)
        case .bloqueado: return T("Está cifrado y cerrado. Relevo lo abre solo si la clave está en el llavero.")
        case .desconocido: return ""
        }
    }

    private func actualizar(_ p: Volumen) {
        let uuid = p.uuid
        DispatchQueue.global(qos: .utility).async {
            let e = Cifrado.estado(uuid: uuid)
            DispatchQueue.main.async { estado = e }
        }
    }
}
