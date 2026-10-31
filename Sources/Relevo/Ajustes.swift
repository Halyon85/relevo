import AppKit
import Combine
import Foundation
import RelevoNucleo

enum Apariencia: String, Codable, CaseIterable, Identifiable {
    case sistema, claro, oscuro
    var id: String { rawValue }
    var nombre: String {
        switch self {
        case .sistema: T("Sistema")
        case .claro: T("Claro")
        case .oscuro: T("Oscuro")
        }
    }
}

/// Un lado de un vínculo: un disco (por su UUID, no por el nombre) y, si querés, una carpeta adentro.
/// `uuid == Lugar.estaMac` es una carpeta de la propia Mac (`subcarpeta` es entonces su ruta completa).
struct Lugar: Codable, Equatable, Hashable {
    static let estaMac = "esta-mac"

    var uuid: String
    var nombre: String
    var subcarpeta: String = ""

    var esEstaMac: Bool { uuid == Lugar.estaMac }

    /// El disco donde está, si está conectado.
    func volumen() -> Volumen? {
        esEstaMac ? Discos.estaMac() : Discos.buscar(uuid)
    }

    /// La carpeta raíz que se sincroniza (nil si no está conectado o no existe).
    func raiz() -> String? {
        if esEstaMac { return FileManager.default.fileExists(atPath: subcarpeta) ? subcarpeta : nil }
        guard let v = Discos.buscar(uuid) else { return nil }
        if subcarpeta.isEmpty { return v.ruta }
        let r = v.ruta + "/" + subcarpeta
        // Tiene que ser una carpeta de verdad en ese disco: si en el portátil la cambiaron por un enlace (atajo) a otro
        // lugar de la Mac, Relevo sincronizaría ese lugar como si fuera el portátil (auditoría del 23/10).
        var st = stat()
        return lstat(r, &st) == 0 && Rutas.sinEnlaces(r, desde: v.ruta) ? r : nil
    }

    /// Cómo se muestra: "Mi disco", "Mi disco › Fotos", "Esta Mac › Proyectos".
    var descripcion: String {
        if esEstaMac { return T("Esta Mac") + " › " + (subcarpeta as NSString).lastPathComponent }
        return subcarpeta.isEmpty ? nombre : "\(nombre) › \(subcarpeta)"
    }
}

/// Un par de lugares que se mantienen iguales: el hub (queda en casa) y el portátil (va con vos).
struct Vinculo: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var hub: Lugar
    var portatil: Lugar
    /// Carpetas que se sincronizan, relativas a la raíz del hub. "Proyectos/*" = cada carpeta de adentro por separado
    /// (incluidas las nuevas, de cualquiera de los dos lados) y "Proyectos/." = los archivos sueltos de ese nivel.
    var carpetas: [String] = []
    /// Subcarpetas (o archivos) que no se sincronizan aunque su carpeta madre sí: los proyectos destildados en
    /// "Carpetas que se sincronizan" y lo tildado en "Lo que nunca se sincroniza". Rutas desde la raíz del hub.
    var omitidas: [String] = []
    /// Lo elegido con el Finder en "Lo que nunca se sincroniza", tildado o no (la lista que se muestra ahí). Que esté
    /// tildado es que esté en `omitidas`.
    var elegidasNunca: [String] = []
    /// En casa (con el hub conectado), montar el portátil oculto: en el Finder se ve uno solo si se llaman igual.
    var ocultarEnCasa = true
    /// Sin copias automáticas hasta esta fecha.
    var pausadoHasta: Date?
    /// El nombre que lleva el portátil cuando está solo (afuera): el mismo del hub, así las rutas son iguales.
    /// En casa, con los dos conectados, se llama "<nombre> (portátil)": nunca hay dos discos con el mismo nombre y
    /// da igual cuál monte primero macOS al prender (si no, el primero se queda con /Volumes/<nombre>).
    /// nil = el portátil conserva su nombre. Lo aplica `Coordinador.acomodarNombres`.
    var nombreAfuera: String?
    /// El nombre del portátil en casa ("<nombre> (portátil)"), fijado la primera vez: si después cambiás el idioma de
    /// la app, el disco no se renombra.
    var nombreEnCasa: String?

    var nombre: String { "\(hub.descripcion) ⇄ \(portatil.descripcion)" }
    var pausado: Bool { (pausadoHasta ?? .distantPast) > Date() }

    init(hub: Lugar, portatil: Lugar) {
        self.hub = hub
        self.portatil = portatil
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        hub = try c.decode(Lugar.self, forKey: .hub)
        portatil = try c.decode(Lugar.self, forKey: .portatil)
        carpetas = try c.decodeIfPresent([String].self, forKey: .carpetas) ?? []
        omitidas = try c.decodeIfPresent([String].self, forKey: .omitidas) ?? []
        // Versiones anteriores: lo elegido en "Lo que nunca" eran las omitidas más adentro que un proyecto.
        elegidasNunca = try c.decodeIfPresent([String].self, forKey: .elegidasNunca) ?? omitidas.filter { o in
            !carpetas.contains { $0.hasSuffix("/*") && o.padreDeRuta == String($0.dropLast(2)) }
        }
        ocultarEnCasa = try c.decodeIfPresent(Bool.self, forKey: .ocultarEnCasa) ?? true
        pausadoHasta = try c.decodeIfPresent(Date.self, forKey: .pausadoHasta)
        // Vínculos de antes: si los dos discos enteros se llamaban igual, es que se quería el mismo nombre afuera.
        nombreEnCasa = try c.decodeIfPresent(String.self, forKey: .nombreEnCasa)
        nombreAfuera = try c.decodeIfPresent(String.self, forKey: .nombreAfuera)
            ?? (Vinculo.discosEnteros(hub, portatil) && portatil.nombre == hub.nombre ? hub.nombre : nil)
    }

    /// Hub y portátil son discos enteros (no carpetas): solo así tiene sentido que el portátil lleve el nombre del hub.
    static func discosEnteros(_ hub: Lugar, _ portatil: Lugar) -> Bool {
        !hub.esEstaMac && !portatil.esEstaMac && hub.subcarpeta.isEmpty && portatil.subcarpeta.isEmpty
    }
}

struct DatosAjustes: Codable, Equatable {
    var vinculos: [Vinculo] = []
    var excluidas: [String] = Reglas.regenerables + [DatosAjustes.cosasMias]
    /// Al enchufar el portátil, sincronizar sola.
    var automatico = true
    /// Mientras los dos están conectados, copiar cada cambio al toque.
    var enVivo = true
    var diasPapelera = 30
    var apariencia: Apariencia = .sistema
    /// Llevar también las dependencias (node_modules, .venv, Pods): afuera funcionan sin volver a bajarlas.
    var llevarDependencias = true
    /// No sincronizar lo que el `.gitignore` de cada proyecto deja afuera (salvo los .env).
    var respetarGitignore = false
    /// Una vez por mes, con la Mac enchufada y sin usar, comparar el contenido de los dos discos.
    var revisionMensual = true
    /// Una vez por día (de madrugada o con la Mac sin usar), revisar todo además de lo que cambió.
    var revisionDiaria = true
    /// Nombres de "Lo que nunca se sincroniza" destildados (como "Cosas mías"): siguen en la lista para volver a tildarlos.
    var excluidasPausadas: [String] = []
    /// Atajos de teclado globales (⌃⌥⌘S sincronizar, ⌃⌥⌘L me voy, ⌃⌥⌘E expulsar discos).
    var atajos = false
    /// Idioma de la interfaz (automático = el de la Mac).
    var idioma: Idioma = .automatico
    /// Repos del hub que no se muestran en la pestaña Repositorios (`RepoLocal.claveOculto`).
    var reposOcultos: [String] = []

    /// Carpeta que nunca se sincroniza, esté donde esté: para guardar lo tuyo en un disco sin que pase al otro.
    static let cosasMias = "Cosas mías"

    init() {}

    private enum Viejas: String, CodingKey {
        case hubUUID, hubNombre, portatilUUID, portatilNombre, carpetas, omitidas, ocultarEnCasa
    }

    init(from decoder: Decoder) throws {
        let d = DatosAjustes()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vinculos = try c.decodeIfPresent([Vinculo].self, forKey: .vinculos) ?? []
        excluidas = try c.decodeIfPresent([String].self, forKey: .excluidas) ?? d.excluidas
        automatico = try c.decodeIfPresent(Bool.self, forKey: .automatico) ?? d.automatico
        enVivo = try c.decodeIfPresent(Bool.self, forKey: .enVivo) ?? d.enVivo
        diasPapelera = try c.decodeIfPresent(Int.self, forKey: .diasPapelera) ?? d.diasPapelera
        // Como el idioma: un valor desconocido (de otra versión) no puede hacer perder el resto de los ajustes.
        apariencia = (try? c.decodeIfPresent(Apariencia.self, forKey: .apariencia)).flatMap { $0 } ?? d.apariencia
        llevarDependencias = try c.decodeIfPresent(Bool.self, forKey: .llevarDependencias) ?? d.llevarDependencias
        respetarGitignore = try c.decodeIfPresent(Bool.self, forKey: .respetarGitignore) ?? d.respetarGitignore
        revisionMensual = try c.decodeIfPresent(Bool.self, forKey: .revisionMensual) ?? d.revisionMensual
        revisionDiaria = try c.decodeIfPresent(Bool.self, forKey: .revisionDiaria) ?? d.revisionDiaria
        excluidasPausadas = try c.decodeIfPresent([String].self, forKey: .excluidasPausadas) ?? []
        atajos = try c.decodeIfPresent(Bool.self, forKey: .atajos) ?? d.atajos
        reposOcultos = try c.decodeIfPresent([String].self, forKey: .reposOcultos) ?? d.reposOcultos
        // Un idioma desconocido (de una versión futura) no puede hacer perder el resto de los ajustes.
        idioma = (try? c.decodeIfPresent(Idioma.self, forKey: .idioma)).flatMap { $0 } ?? d.idioma

        // Ajustes de la primera versión (un solo par de discos): pasan a ser el primer vínculo, con el mismo id
        // que su carpeta de estado, así no se vuelve a copiar nada.
        let v = try decoder.container(keyedBy: Viejas.self)
        if vinculos.isEmpty, let h = try v.decodeIfPresent(String.self, forKey: .hubUUID),
           let p = try v.decodeIfPresent(String.self, forKey: .portatilUUID) {
            var nuevo = Vinculo(hub: Lugar(uuid: h, nombre: try v.decodeIfPresent(String.self, forKey: .hubNombre) ?? "Hub"),
                                portatil: Lugar(uuid: p, nombre: try v.decodeIfPresent(String.self, forKey: .portatilNombre) ?? "Portátil"))
            nuevo.id = "\(h)-\(p)"
            nuevo.carpetas = try v.decodeIfPresent([String].self, forKey: .carpetas) ?? []
            nuevo.omitidas = try v.decodeIfPresent([String].self, forKey: .omitidas) ?? []
            nuevo.ocultarEnCasa = try v.decodeIfPresent(Bool.self, forKey: .ocultarEnCasa) ?? true
            vinculos = [nuevo]
        }
    }
}

final class Ajustes: ObservableObject {
    static let shared = Ajustes()

    static let carpetaApp: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Relevo")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()
    private static let archivo = carpetaApp.appendingPathComponent("ajustes.json")

    /// Solo el idioma guardado, sin cargar ni volver a guardar los ajustes.
    static func idiomaGuardado() -> Idioma {
        struct SoloIdioma: Decodable { var idioma: Idioma? }
        guard let d = try? Data(contentsOf: archivo), let s = try? JSONDecoder().decode(SoloIdioma.self, from: d) else { return .automatico }
        return s.idioma ?? .automatico
    }

    @Published var datos: DatosAjustes {
        didSet {
            guard datos != oldValue else { return }
            if datos.idioma != oldValue.idioma { Idioma.usar(datos.idioma) }
            guardar()
            alCambiar?()
        }
    }
    var alCambiar: (() -> Void)?

    private init() {
        if let d = try? Data(contentsOf: Self.archivo), let v = try? JSONDecoder().decode(DatosAjustes.self, from: d) {
            datos = v
        } else {
            // Si existe pero no se puede leer, se guarda aparte antes de empezar de cero (para no perder tus vínculos).
            if FileManager.default.fileExists(atPath: Self.archivo.path) {
                let copia = Self.carpetaApp.appendingPathComponent("ajustes.roto.json")
                try? FileManager.default.removeItem(at: copia)
                try? FileManager.default.copyItem(at: Self.archivo, to: copia)
            }
            datos = DatosAjustes()
        }
        guardar()   // deja el archivo en el formato nuevo
    }

    private func guardar() {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? e.encode(datos).write(to: Self.archivo, options: .atomic)
    }

    /// Lo que de verdad no se sincroniza: la lista, menos las dependencias si se eligió llevarlas.
    var excluidasEfectivas: [String] {
        datos.llevarDependencias ? datos.excluidas.filter { !Reglas.dependencias.contains($0) } : datos.excluidas
    }
    var reglas: Reglas { Reglas(nombres: excluidasEfectivas) }

    func vinculo(_ id: String) -> Vinculo? { datos.vinculos.first { $0.id == id } }

    func cambiar(_ id: String, _ cambio: (inout Vinculo) -> Void) {
        guard let i = datos.vinculos.firstIndex(where: { $0.id == id }) else { return }
        cambio(&datos.vinculos[i])
    }

    /// Base y diario de un vínculo (en la Mac).
    static func carpetaEstado(_ id: String) -> URL { carpetaApp.appendingPathComponent("pares/\(id)") }
}
