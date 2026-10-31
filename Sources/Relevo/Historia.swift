import CoreServices
import Foundation

/// El registro de cambios que macOS guarda adentro de cada disco (FSEvents, el mismo que usa Time Machine). Sirve para
/// saber qué carpetas cambiaron desde la última copia aunque Relevo haya estado cerrado o el disco se haya usado en
/// otra Mac, y así revisar solo esas en vez de todo.
///
/// Uso (`Coordinador.sincronizarInteligente`): al arrancar una copia se toma una `Marca` de cada disco; si terminó
/// bien, se guarda. La próxima vez, `cambios(desde:)` dice qué carpetas tocaron. Si macOS no puede decirlo con
/// seguridad (registro borrado, eventos perdidos, otro registro), devuelve nil y se revisa todo.
enum Historia {
    /// Hasta dónde llegaba el registro de un disco en un momento dado.
    struct Marca: Codable, Equatable {
        /// Identifica el registro de ese disco: si cambia (se borró o se rehízo), las marcas viejas no sirven.
        var registro: String
        var evento: UInt64
    }

    /// La marca de ahora del disco donde está `ruta` (nil si ese disco no lleva registro). Es el número de evento
    /// actual de esta Mac: lo que pase en el disco después tiene un número mayor. (Si el disco se usa en otra Mac, que
    /// numera distinto, puede no verse: para eso está la revisión completa de fondo, ver `Coordinador`.)
    static func marca(_ ruta: String) -> Marca? {
        var st = stat()
        guard stat(ruta, &st) == 0, let registro = registroDe(st.st_dev) else { return nil }
        return Marca(registro: registro, evento: FSEventsGetCurrentEventId())
    }

    /// Lo que cambió adentro de una carpeta: las carpetas tocadas y las que macOS pide revisar enteras (con todo lo de
    /// adentro, porque perdió el detalle). Rutas completas que empiezan con la ruta pedida.
    struct Cambios { var carpetas = Set<String>(); var enteras = Set<String>() }

    /// Lo que cambió adentro de `ruta` desde `m`. nil = no se puede saber con seguridad: hay que revisar todo. Tarda
    /// poco (lee el registro, no los archivos); como mucho espera 30 segundos.
    static func cambios(desde m: Marca, en ruta: String) -> Cambios? {
        var st = stat(), fs = statfs()
        guard stat(ruta, &st) == 0, statfs(ruta, &fs) == 0, registroDe(st.st_dev) == m.registro else { return nil }
        let montaje = withUnsafeBytes(of: fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        // El registro anota rutas relativas al disco: "/Volumes/X/Proyectos/A" se pide como "Proyectos/A".
        var relativa = ruta.hasPrefix(montaje) ? String(ruta.dropFirst(montaje.count)) : ruta
        while relativa.hasPrefix("/") { relativa.removeFirst() }

        let caja = Caja(raiz: ruta, relativa: relativa)
        var contexto = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(caja).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        let llamada: FSEventStreamCallback = { _, info, cantidad, rutasCrudas, banderas, _ in
            guard let info else { return }
            let caja = Unmanaged<Caja>.fromOpaque(info).takeUnretainedValue()
            let rutas = Unmanaged<CFArray>.fromOpaque(rutasCrudas).takeUnretainedValue() as? [String] ?? []
            for i in 0..<min(cantidad, rutas.count) { caja.anotar(rutas[i], banderas[i]) }
        }
        guard let flujo = FSEventStreamCreateRelativeToDevice(nil, llamada, &contexto, st.st_dev, [relativa] as CFArray,
                                                              m.evento, 0, FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        else { return nil }
        let cola = DispatchQueue(label: "team.halyon.relevo.historia")
        FSEventStreamSetDispatchQueue(flujo, cola)
        guard FSEventStreamStart(flujo) else { FSEventStreamInvalidate(flujo); FSEventStreamRelease(flujo); return nil }
        let termino = caja.listo.wait(timeout: .now() + 30) == .success
        FSEventStreamStop(flujo)
        FSEventStreamInvalidate(flujo)
        FSEventStreamRelease(flujo)
        return cola.sync { termino && !caja.todo ? caja.cambios : nil }
    }

    // MARK: Por dentro

    private static func registroDe(_ dispositivo: dev_t) -> String? {
        guard let u = FSEventsCopyUUIDForDevice(dispositivo) else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }

    /// Junta lo que va llegando del registro (en su propia cola).
    private final class Caja {
        /// La carpeta pedida tal como la pidió quien llama, y relativa al disco (como las anota el registro). Pueden
        /// no coincidir con el punto de montaje: una carpeta de la Mac está en "/System/Volumes/Data" aunque se pida
        /// como una carpeta de tu usuario.
        let raiz: String, relativa: String
        var cambios = Cambios()
        /// Algo que obliga a revisar todo: eventos perdidos, ids que se reiniciaron, la raíz que se movió.
        var todo = false
        let listo = DispatchSemaphore(value: 0)
        private var avisado = false

        init(raiz: String, relativa: String) { self.raiz = raiz; self.relativa = relativa }

        func anotar(_ ruta: String, _ b: FSEventStreamEventFlags) {
            if b & FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone) != 0 {
                if !avisado { avisado = true; listo.signal() }
                return
            }
            let graves = kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagEventIdsWrapped
                | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped
            if b & FSEventStreamEventFlags(graves) != 0 { todo = true; return }
            if b & FSEventStreamEventFlags(kFSEventStreamEventFlagMount | kFSEventStreamEventFlagUnmount) != 0 { return }
            var rel = Substring(ruta)
            while rel.hasPrefix("/") { rel = rel.dropFirst() }
            while rel.hasSuffix("/") { rel = rel.dropLast() }
            let enteras = b & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0
            // Más arriba de la carpeta pedida: si hay que revisar todo lo de abajo, es revisar todo.
            if !relativa.isEmpty, rel.count < relativa.count, rel.isEmpty || relativa.hasPrefix(rel + "/") {
                if enteras { todo = true }
                return
            }
            // Afuera de la carpeta pedida: no importa.
            guard relativa.isEmpty || rel == relativa || rel.hasPrefix(relativa + "/") else { return }
            let resto = rel.dropFirst(relativa.count).drop { $0 == "/" }
            let completa = resto.isEmpty ? raiz : raiz + "/" + resto
            if enteras {
                if completa == raiz { todo = true; return }
                cambios.enteras.insert(completa)
            }
            cambios.carpetas.insert(completa)
        }
    }
}
