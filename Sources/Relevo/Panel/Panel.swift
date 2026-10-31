import AppKit
import Combine
import SwiftUI

enum Pagina: String, CaseIterable, Identifiable {
    case inicio, carpetas, discos, historial, repos, general
    var id: String { rawValue }
    var titulo: String {
        switch self {
        case .inicio: T("Inicio")
        case .carpetas: T("Qué se sincroniza")
        case .discos: T("Discos")
        case .historial: T("Historial")
        case .repos: T("Repositorios")
        case .general: T("General")
        }
    }
    var icono: String {
        switch self {
        case .inicio: "arrow.triangle.2.circlepath"
        case .carpetas: "folder"
        case .discos: "externaldrive"
        case .historial: "clock.arrow.circlepath"
        case .repos: "arrow.triangle.branch"
        case .general: "gearshape"
        }
    }
}

final class Navegacion: ObservableObject {
    @Published var pagina: Pagina = .inicio
    /// Vínculo elegido en "Qué se sincroniza" y "Discos" (si hay más de uno).
    @Published var vinculo: String?
    /// Asistente para armar un vínculo nuevo.
    @Published var asistente = false
    /// Pestaña de "Qué se sincroniza": las carpetas que se sincronizan o lo que no se sincroniza nunca.
    @Published var pestanaReleva: PestanaReleva = .carpetas
}

enum PestanaReleva: String, CaseIterable, Identifiable {
    case carpetas, nunca
    var id: String { rawValue }
    var nombre: String { self == .carpetas ? T("Carpetas que se sincronizan") : T("Lo que nunca se sincroniza") }
}

struct VistaPanel: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var ajustes: Ajustes
    @ObservedObject var navegacion: Navegacion
    @ObservedObject var historial = Historial.shared
    @Estado private var sobre: Pagina?

    var body: some View {
        HStack(spacing: 0) {
            barraLateral
                .padding(8)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    pagina
                }
                .frame(maxWidth: Tema.anchoPagina, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(.top, 8)
            .id(navegacion.pagina)
            .transition(.opacity)
        }
        .background(Tema.fondo)
        .foregroundStyle(Tema.texto)
        .focusEffectDisabled()
        .sheet(isPresented: $navegacion.asistente) {
            Asistente(gestor: gestor, navegacion: navegacion)
        }
        // Al cambiar el idioma se rearma todo el panel (los textos se leen al dibujar cada vista).
        .id(ajustes.datos.idioma)
    }

    @ViewBuilder private var pagina: some View {
        switch navegacion.pagina {
        case .inicio: PaginaInicio(gestor: gestor, navegacion: navegacion)
        case .carpetas: PaginaCarpetas(gestor: gestor, ajustes: ajustes, navegacion: navegacion)
        case .discos: PaginaDiscos(gestor: gestor, ajustes: ajustes, navegacion: navegacion)
        case .historial: PaginaHistorial(historial: historial, gestor: gestor)
        case .repos: PaginaRepos(gestor: gestor, navegacion: navegacion)
        case .general: PaginaGeneral(gestor: gestor, ajustes: ajustes)
        }
    }

    private func atencion(_ p: Pagina) -> Bool {
        switch p {
        case .inicio: return gestor.coordinadores.contains { $0.estado == .necesitaOK || $0.estado == .alReves }
        case .carpetas: return gestor.coordinadores.contains { $0.estado == .sinCarpetas }
        case .discos: return ajustes.datos.vinculos.isEmpty
        case .historial: return !historial.conflictosAbiertos.isEmpty
        default: return false
        }
    }

    private var barraLateral: some View {
        VStack(alignment: .leading, spacing: 24) {
            HStack(spacing: 8) {
                Logo(tam: 24)
                Text("Relevo").font(.titulo(15, .semibold)).foregroundStyle(Tema.titulo)
            }
            .padding(12)
            .frame(height: 44)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(Pagina.allCases) { p in
                    Button { withAnimation(.easeOut(duration: 0.15)) { navegacion.pagina = p } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: p.icono)
                                .font(.system(size: 13, weight: .medium))
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Tema.rellenoSuave))
                                .foregroundStyle(Tema.titulo)
                            Text(p.titulo).font(.titulo(14))
                                .foregroundStyle(navegacion.pagina == p ? Tema.titulo : Tema.subtitulo)
                            Spacer()
                            if atencion(p) {
                                Circle().fill(Tema.error).frame(width: 6, height: 6).padding(.trailing, 10)
                            }
                        }
                        .padding(4)
                        .background(RoundedRectangle(cornerRadius: 12)
                            .fill(navegacion.pagina == p ? Tema.relleno : (sobre == p ? Tema.rellenoSuave : .clear)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .onHover { dentro in sobre = dentro ? p : (sobre == p ? nil : sobre) }
                }
            }
            Spacer()
            PieHalyon()
        }
        .padding(.top, 8)
        .padding([.horizontal, .bottom], 12)
        .frame(width: Tema.anchoBarra)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(Tema.tarjeta.opacity(0.8)))
        .shadow(color: .black.opacity(0.06), radius: 1.5, y: 1)
    }
}

/// Elegir un vínculo cuando hay más de uno (en "Qué se sincroniza").
struct SelectorVinculo: View {
    @ObservedObject var gestor: Gestor
    @ObservedObject var navegacion: Navegacion

    var body: some View {
        if gestor.coordinadores.count > 1 {
            Fluir(espacio: 6) {
                ForEach(gestor.coordinadores) { c in
                    let elegido = (navegacion.vinculo ?? gestor.coordinadores.first?.id) == c.id
                    Button { navegacion.vinculo = c.id } label: {
                        Text(c.vinculo?.portatil.descripcion ?? T("Vínculo")).font(.system(size: 12, weight: elegido ? .semibold : .regular))
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(elegido ? Tema.tarjeta : Tema.relleno))
                            .foregroundStyle(elegido ? Tema.titulo : Tema.subtitulo)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func elegido(_ gestor: Gestor, _ navegacion: Navegacion) -> Coordinador? {
        navegacion.vinculo.flatMap { gestor.coordinador($0) } ?? gestor.coordinadores.first
    }
}
