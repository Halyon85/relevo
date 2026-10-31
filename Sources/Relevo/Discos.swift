import AppKit
import DiskArbitration
import Foundation
import RelevoNucleo

/// Un disco montado. Se reconoce por su UUID, no por el nombre: así el hub y el portátil pueden llamarse igual
/// (por ejemplo, "Mi disco") y las rutas de tus proyectos son las mismas estés donde estés.
struct Volumen: Identifiable, Equatable {
    let url: URL
    let nombre: String
    let uuid: String
    let externo: Bool
    let capacidad: Int64
    let libre: Int64
    let formato: String
    /// Aparece en el Finder (los montados "ocultos" no).
    let visible: Bool
    /// "apfs", "hfs", "exfat", "msdos"…
    let sistema: String

    var id: String { uuid }
    var ruta: String { url.path }

    /// Para sincronizar bien hace falta el formato de Mac: guarda permisos, enlaces y fechas exactas.
    var formatoDeMac: Bool { sistema == "apfs" || sistema == "hfs" }
    var esEstaMac: Bool { uuid == Lugar.estaMac }
}

enum Discos {
    static func montados() -> [Volumen] {
        let claves: [URLResourceKey] = [.volumeNameKey, .volumeUUIDStringKey, .volumeIsInternalKey, .volumeIsRootFileSystemKey,
                                        .volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeLocalizedFormatDescriptionKey,
                                        .volumeIsBrowsableKey, .volumeTypeNameKey]
        // Sin `.skipHiddenVolumes`: en casa el portátil se monta oculto y igual hay que encontrarlo.
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: claves, options: []) ?? []
        return urls.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(claves)), let uuid = v.volumeUUIDString,
                  v.volumeIsRootFileSystem != true, u.path.hasPrefix("/Volumes/") else { return nil }
            return Volumen(url: u, nombre: v.volumeName ?? u.lastPathComponent, uuid: uuid,
                           externo: v.volumeIsInternal != true,
                           capacidad: Int64(v.volumeTotalCapacity ?? 0), libre: Int64(v.volumeAvailableCapacity ?? 0),
                           formato: v.volumeLocalizedFormatDescription ?? "", visible: v.volumeIsBrowsable != false,
                           sistema: (v.volumeTypeName ?? "").lowercased())
        }
    }

    /// El disco de la Mac, para usar una carpeta propia como hub.
    static func estaMac() -> Volumen {
        let u = URL(fileURLWithPath: "/")
        let v = try? u.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeNameKey])
        return Volumen(url: u, nombre: v?.volumeName ?? T("Esta Mac"), uuid: Lugar.estaMac, externo: false,
                       capacidad: Int64(v?.volumeTotalCapacity ?? 0), libre: v?.volumeAvailableCapacityForImportantUsage ?? 0,
                       formato: "APFS", visible: true, sistema: "apfs")
    }

    /// Le cambia el nombre a un disco (por ejemplo, para que el portátil se llame igual que el hub).
    /// Cambia el nombre de un disco montado sin desmontarlo (anda aunque esté en uso): su ruta pasa a ser
    /// /Volumes/<nombre nuevo> en el momento. Por UUID, porque la ruta cambia.
    static func renombrar(uuid: String, a nombre: String) -> Bool {
        diskutil(["rename", uuid, nombre])
    }

    /// El nombre del portátil en casa, con los dos discos conectados: "<nombre> (portátil)".
    static func nombreEnCasa(_ nombre: String) -> String { nombre + " " + T("(portátil)") }

    /// Si un disco quedó en "/Volumes/<nombre> 1" (otro tenía su ruta cuando se montó) y la ruta sin número está
    /// libre, se la devuelve. Ponerle el mismo nombre no mueve la ruta: hay que pasar por uno intermedio.
    static func recuperarRuta(_ v: Volumen) -> Bool {
        guard renombrar(uuid: v.uuid, a: v.nombre + " ·"), renombrar(uuid: v.uuid, a: v.nombre) else { return false }
        // Si algo que no es un disco (una carpeta suelta en /Volumes, un recurso de red) ocupa la ruta, no se movió:
        // se cuenta como falla y no se reintenta en bucle (ver `nombresTrabados`).
        return buscar(v.uuid)?.ruta == "/Volumes/" + v.nombre
    }

    /// Alguien (que no sea `salvo`) ya está montado en /Volumes/<nombre>.
    static func rutaOcupada(_ nombre: String, salvo uuid: String) -> Bool {
        montados().contains { $0.ruta == "/Volumes/" + nombre && $0.uuid != uuid }
    }

    static func buscar(_ uuid: String?) -> Volumen? {
        guard let uuid else { return nil }
        return montados().first { $0.uuid == uuid }
    }

    /// Expulsa el aparato entero (todas sus particiones) para poder desenchufarlo.
    /// Si algo lo está usando, devuelve qué apps son.
    static func expulsar(_ v: Volumen, nombreAfuera: String? = nil) -> Result<Void, ErrorExpulsar> {
        // Siempre el disco de ese UUID, con su ruta de ahora (nunca una ruta vieja que hoy puede ser la de otro).
        guard var v = buscar(v.uuid) else { return .success(()) }
        // El portátil se va con el nombre del hub: afuera las rutas quedan iguales aunque Relevo no esté abierto.
        if let n = nombreAfuera, v.nombre != n, renombrar(uuid: v.uuid, a: n), let nuevo = buscar(v.uuid) { v = nuevo }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
            return .success(())
        } catch {
            var uso = Procesos.usando(v.ruta)
            // Lo que corre de fondo (sin ninguna app con ventana detrás: scripts, servidores, terminales sueltas) se
            // cierra solo y se prueba otra vez. Lo que depende de una app con ventana se muestra para que decidas.
            if !uso.deFondo.isEmpty {
                Procesos.cerrar(uso.deFondo)
                if (try? NSWorkspace.shared.unmountAndEjectDevice(at: v.url)) != nil { return .success(()) }
                uso = Procesos.usando(v.ruta)
            }
            return .failure(ErrorExpulsar(volumen: v, uso: uso, detalle: error.localizedDescription))
        }
    }

    struct ErrorExpulsar: Error {
        var volumen: Volumen
        var uso: UsoDeDisco
        var detalle: String
    }

    /// Lo vuelve a montar oculto (sin aparecer en la barra lateral del Finder) o visible. No toca nada adentro.
    /// Lo llama `Coordinador.acomodarVisibilidad`. Devuelve false si no se pudo (y entonces puede haber quedado sin montar).
    /// A propósito, con un disco cifrado: al desmontarlo macOS lo vuelve a cerrar, así que antes de montarlo se abre con
    /// `clave`. Sin clave no se toca: mejor verlo en el Finder que dejarlo enchufado y cerrado (25/10/2026: el portátil
    /// recién cifrado quedaba cerrado cada vez que Relevo lo ocultaba).
    @discardableResult
    static func remontar(_ v: Volumen, oculto: Bool, clave: String?) -> Bool {
        guard let dispositivo = dispositivo(v.ruta) else { return false }
        let cifrado = Cifrado.tieneCifrado(dispositivo)
        if cifrado, clave == nil { return false }
        guard diskutil(["unmount", dispositivo]) else { return false }
        if cifrado, let clave, !Cifrado.abrirSinMontar(dispositivo, clave: clave) { return false }
        if diskutil(oculto ? ["mount", "nobrowse", dispositivo] : ["mount", dispositivo]) { return true }
        return diskutil(["mount", dispositivo])   // si falló el oculto, que al menos quede montado
    }

    static func dispositivo(_ ruta: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["info", "-plist", ruta]
        let tubo = Pipe()
        p.standardOutput = tubo
        guard (try? p.run()) != nil else { return nil }
        let datos = tubo.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let info = (try? PropertyListSerialization.propertyList(from: datos, format: nil)) as? [String: Any]
        return info?["DeviceIdentifier"] as? String
    }

    static func diskutil(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// Abre una carpeta en el Finder.
    /// Muestra una carpeta (la crea si falta), desde `raiz`. Lo usa "Papeleras de Relevo" en Historial.
    static func mostrar(_ ruta: String, desde raiz: String) {
        guard Rutas.sinEnlaces(ruta, desde: raiz) else { return }
        try? FileManager.default.createDirectory(atPath: ruta, withIntermediateDirectories: true)
        mostrarEnFinder(ruta)
    }

    /// Muestra en el Finder sin abrir nada. Con NSWorkspace.open, una "carpeta" que en realidad es una app (o un enlace
    /// a una), armada en el portátil, se ejecutaría (auditoría del 23/10): una carpeta de verdad se abre como ventana del
    /// Finder y cualquier otra cosa solo se señala. Lo usan Discos, Repos y el disco del portátil.
    static func mostrarEnFinder(_ ruta: String) {
        var st = stat()
        if lstat(ruta, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, !NSWorkspace.shared.isFilePackage(atPath: ruta) {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: ruta)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: ruta)])
        }
    }
}

/// Ícono propio para cada disco, así no se confunden en el Finder aunque los dos se llamen igual:
/// el ícono de disco externo de macOS con una etiqueta abajo ("HUB · CASA" gris, "PORTÁTIL" coral).
enum MarcaDisco {
    static func dibujar(hub: Bool) -> NSImage {
        let base = NSImage(contentsOfFile: "/System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/External.icns")
            ?? NSWorkspace.shared.icon(for: .volume)
        let lado: CGFloat = 1024
        return NSImage(size: NSSize(width: lado, height: lado), flipped: false) { r in
            base.draw(in: r.insetBy(dx: 40, dy: 80).offsetBy(dx: 0, dy: 60))
            let texto = hub ? T("HUB · CASA") : T("PORTÁTIL")
            let color = hub ? NSColor(hex: 0x2B2A29) : NSColor(hex: 0xF56138)
            let fuente = NSFont.systemFont(ofSize: 132, weight: .heavy)
            let atributos: [NSAttributedString.Key: Any] = [.font: fuente, .foregroundColor: NSColor.white, .kern: 2]
            let medida = (texto as NSString).size(withAttributes: atributos)
            let pastilla = NSRect(x: (lado - medida.width) / 2 - 56, y: 70, width: medida.width + 112, height: medida.height + 40)
            color.setFill()
            NSBezierPath(roundedRect: pastilla, xRadius: pastilla.height / 2, yRadius: pastilla.height / 2).fill()
            (texto as NSString).draw(at: NSPoint(x: pastilla.minX + 56, y: pastilla.minY + 20), withAttributes: atributos)
            return true
        }
    }

    /// Pone el ícono en la raíz del disco (crea `.VolumeIcon.icns`, lo mismo que hace el Finder al pegar un ícono).
    @discardableResult
    static func poner(_ volumen: String, hub: Bool) -> Bool {
        NSWorkspace.shared.setIcon(dibujar(hub: hub), forFile: volumen, options: [])
    }
}

/// Avisa cuando se conecta un disco, aunque no se monte (por ejemplo, uno cifrado que espera su clave).
final class MonitorDiscos {
    static let shared = MonitorDiscos()
    var alAparecer: (() -> Void)?
    private var sesion: DASession?

    func arrancar() {
        guard sesion == nil, let s = DASessionCreate(kCFAllocatorDefault) else { return }
        sesion = s
        let contexto = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(s, nil, { _, contexto in
            guard let contexto else { return }
            let m = Unmanaged<MonitorDiscos>.fromOpaque(contexto).takeUnretainedValue()
            // Un respiro: el disco recién aparece y macOS todavía lo está mirando.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { m.alAparecer?() }
        }, contexto)
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }
}
