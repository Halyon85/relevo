import Darwin
import Foundation

/// Foto de una carpeta: cada ruta (relativa) con su tamaño, fecha y permisos. No lee el contenido, solo los datos
/// del sistema de archivos, así que 300 mil archivos se recorren en segundos.
public struct Foto: Sendable {
    public var entradas: [String: Entrada] = [:]
    /// Carpetas que no se pudieron leer: lo de adentro no se toca (si no, parecería borrado).
    public var noLeidas: [String] = []
    /// Restos de copias cortadas (el disco se sacó en el medio). Se limpian antes de copiar.
    public var temporales: [String] = []
    public var archivos = 0
    public var bytes: Int64 = 0

    func noLeida(_ ruta: String) -> Bool { noLeidas.contains { ruta.estaDentro(de: $0) } }

    /// Lo mismo, contra un conjunto armado una vez (ver `Planificador`): con muchas carpetas que no se pueden leer
    /// (un disco puede traer miles), mirar la lista entera por cada ruta tardaría horas.
    static func noLeida(_ ruta: String, en conjunto: Set<String>) -> Bool {
        guard !conjunto.isEmpty else { return false }
        var r = Substring(ruta)
        while true {
            if conjunto.contains(String(r)) { return true }
            guard let i = r.lastIndex(of: "/") else { return conjunto.contains("") }
            r = r[..<i]
        }
    }
}

public enum ErrorEscaneo: Error, Equatable {
    case noExiste(String)
    case noSePuedeLeer(String, Int32)
}

enum Escaner {
    /// Recorre `raiz` sin seguir enlaces y sin pasar a otros discos.
    /// `soloArchivos`: solo los archivos sueltos de la raíz, sin entrar a ninguna carpeta.
    static func fotografiar(_ raiz: String, reglas: Reglas, soloArchivos: Bool = false) throws -> Foto {
        var st = stat()
        guard lstat(raiz, &st) == 0 else { throw ErrorEscaneo.noExiste(raiz) }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { throw ErrorEscaneo.noExiste(raiz) }

        var foto = Foto()
        try recorrer(raiz, desde: raiz, reglas: reglas, soloArchivos: soloArchivos, en: &foto)
        guard access(raiz, F_OK) == 0 else { throw ErrorEscaneo.noExiste(raiz) }
        return foto
    }

    /// La foto de solo algunas partes de `raiz` (la revisión por zonas, ver `Sincronizador.analizar(_:zonas:)`):
    /// - de cada carpeta de `planas`, lo que tiene adentro directo (archivos, enlaces y subcarpetas, sin entrar);
    /// - cada carpeta de `enteras` con todo lo de adentro (y su propia entrada).
    /// Lo que no existe de este lado simplemente no aparece. Una zona que no se puede leer va a `noLeidas` (lo de
    /// adentro no se toca). Las zonas que caen en algo excluido por las reglas se saltean, igual que en la foto entera.
    static func fotografiar(_ raiz: String, planas: Set<String>, enteras: Set<String>, reglas: Reglas) throws -> Foto {
        var st = stat()
        guard lstat(raiz, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR else { throw ErrorEscaneo.noExiste(raiz) }
        var foto = Foto()
        for e in enteras.sorted() where !excluida(e, reglas) {
            if let prendida = prendida(raiz, arribaDe: e) { foto.noLeidas.append(prendida); continue }
            let completa = raiz + "/" + e
            guard lstat(completa, &st) == 0 else { continue }
            if e.nombreFinal.hasSuffix(Reglas.sufijoTemporal) { foto.temporales.append(e) }
            guard (st.st_mode & S_IFMT) == S_IFDIR else {
                if let entrada = entrada(st, completa) { anotar(entrada, e, en: &foto) }
                continue
            }
            anotar(entrada(st, completa)!, e, en: &foto)
            do {
                try recorrer(completa, desde: raiz, reglas: reglas, soloArchivos: false, en: &foto)
            } catch ErrorEscaneo.noSePuedeLeer {
                // No se pudo leer entera (permisos, o se cortó a mitad): mejor no opinar sobre lo que hay adentro. Si
                // fue porque se fue el disco, lo frena la revisión de abajo.
                foto.noLeidas.append(e)
            }
        }
        for p in planas.sorted() where !excluida(p, reglas) {
            if let prendida = prendida(raiz, arribaDe: p) { foto.noLeidas.append(prendida); continue }
            try listar(raiz, p, reglas: reglas, en: &foto)
        }
        guard access(raiz, F_OK) == 0 else { throw ErrorEscaneo.noExiste(raiz) }
        return foto
    }

    /// ¿Alguna parte de la ruta queda afuera por las reglas? (La foto entera ni siquiera entra a esas carpetas.)
    static func excluida(_ ruta: String, _ reglas: Reglas) -> Bool {
        var hasta = ""
        for parte in ruta.split(separator: "/") {
            hasta = hasta.isEmpty ? String(parte) : hasta + "/" + parte
            if reglas.excluye(nombre: String(parte), ruta: hasta) { return true }
        }
        return false
    }

    /// Recorre todo lo de adentro de `carpeta` (no su propia entrada) y lo anota con rutas relativas a `raiz`.
    private static func recorrer(_ carpeta: String, desde raiz: String, reglas: Reglas, soloArchivos: Bool,
                                 en foto: inout Foto) throws {
        let largoRaiz = raiz.utf8.count
        guard let c = strdup(carpeta) else { throw ErrorEscaneo.noSePuedeLeer(carpeta, ENOMEM) }
        defer { free(c) }
        var argumentos: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
            throw ErrorEscaneo.noSePuedeLeer(carpeta, errno)
        }
        defer { fts_close(fts) }

        while true {
            errno = 0
            guard let e = fts_read(fts) else {
                // Termina con errno en 0; si no, se cortó (por ejemplo, el disco se fue) y la foto no es confiable.
                if errno != 0 { throw ErrorEscaneo.noSePuedeLeer(carpeta, errno) }
                break
            }
            let info = Int32(e.pointee.fts_info)
            if e.pointee.fts_level == 0 {
                if info == FTS_DNR || info == FTS_ERR { throw ErrorEscaneo.noSePuedeLeer(carpeta, e.pointee.fts_errno) }
                continue
            }
            if info == FTS_DP { continue }
            let completa = String(cString: e.pointee.fts_path)
            let ruta = String(completa.utf8.dropFirst(largoRaiz + 1)) ?? ""
            let nombre = ruta.nombreFinal

            if nombre.hasSuffix(Reglas.sufijoTemporal) { foto.temporales.append(ruta) }
            if soloArchivos && info == FTS_D {
                fts_set(fts, e, FTS_SKIP)
                continue
            }
            if reglas.excluye(nombre: nombre, ruta: ruta) {
                if info == FTS_D { fts_set(fts, e, FTS_SKIP) }
                continue
            }
            if info == FTS_D, prendida(completa) {
                // Una base de datos o una máquina virtual funcionando: se deja como está de los dos lados hasta que se apague.
                foto.noLeidas.append(ruta)
                fts_set(fts, e, FTS_SKIP)
                continue
            }
            switch info {
            case FTS_D, FTS_F, FTS_SL, FTS_SLNONE:
                if let entrada = entrada(e.pointee.fts_statp.pointee, completa) { anotar(entrada, ruta, en: &foto) }
            case FTS_DNR, FTS_ERR, FTS_NS:
                // No se pudo leer: mejor no opinar sobre lo que hay adentro.
                foto.noLeidas.append(ruta)
            default:
                continue   // sockets, tuberías y otros especiales no viajan
            }
        }
    }

    /// Lo que hay adentro directo de `raiz/carpeta` (sin entrar a las subcarpetas). Si la carpeta no existe de este
    /// lado (o ya no es una carpeta), no anota nada: quien llama lo resuelve mirando esa carpeta entera.
    private static func listar(_ raiz: String, _ carpeta: String, reglas: Reglas, en foto: inout Foto) throws {
        let completaCarpeta = carpeta.isEmpty ? raiz : raiz + "/" + carpeta
        guard let dir = opendir(completaCarpeta) else {
            if errno == ENOENT || errno == ENOTDIR { return }
            guard access(raiz, F_OK) == 0 else { throw ErrorEscaneo.noExiste(raiz) }
            foto.noLeidas.append(carpeta)
            return
        }
        defer { closedir(dir) }
        var st = stat()
        while true {
            errno = 0
            guard let d = readdir(dir) else {
                if errno != 0 { throw ErrorEscaneo.noSePuedeLeer(completaCarpeta, errno) }
                break
            }
            let nombre = withUnsafeBytes(of: d.pointee.d_name) { p in
                String(decoding: p.prefix(Int(d.pointee.d_namlen)), as: UTF8.self)
            }
            if nombre == "." || nombre == ".." { continue }
            let ruta = carpeta.isEmpty ? nombre : carpeta + "/" + nombre
            if nombre.hasSuffix(Reglas.sufijoTemporal) { foto.temporales.append(ruta) }
            if reglas.excluye(nombre: nombre, ruta: ruta) { continue }
            let completa = completaCarpeta + "/" + nombre
            guard lstat(completa, &st) == 0 else {
                // Se fue entre que se listó y se miró (alguien lo borró recién): como si no estuviera.
                if errno == ENOENT { continue }
                foto.noLeidas.append(ruta)
                continue
            }
            if let entrada = entrada(st, completa) { anotar(entrada, ruta, en: &foto) }
        }
    }

    /// ¿Es la carpeta de datos de una base Postgres funcionando? (Tiene su `postmaster.pid` y ese proceso está vivo.)
    /// Mientras funciona cambia sin parar y una copia de esos archivos no sirve (queda a medias): llegó a ser dos tercios
    /// de todo lo que Relevo copiaba (30/10/2026). Se anota como no leída, así no se copia ni se borra nada de adentro
    /// de ningún lado; cuando la base se apaga, se copia entera. Un `postmaster.pid` viejo (copiado de otro lado, con
    /// un proceso que ya no existe) no cuenta. Lo usa `prendida`.
    static func baseDeDatosPrendida(_ carpeta: String) -> Bool {
        let fd = open(carpeta + "/postmaster.pid", O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 24)
        let n = read(fd, &buf, buf.count)
        guard n > 0, let linea = String(decoding: buf[0..<n], as: UTF8.self).split(separator: "\n").first,
              let pid = Int32(linea.trimmingCharacters(in: .whitespaces)), pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    /// Carpetas donde viven los emuladores y las máquinas virtuales: las de Android (`.avd`), UTM, VMware y Parallels.
    static let carpetasDeMaquinas = [".avd", ".utm", ".vmwarevm", ".pvm"]
    /// Pedazos del nombre de los programas que las prenden: QEMU (el emulador de Android y UTM), el de Apple
    /// (Virtualization), VMware, VirtualBox y Parallels. Las pruebas suman el suyo.
    static var programasDeMaquinas = ["qemu", "QEMU", "Virtualization", "vmware-vmx", "VBox", "prl_"]

    /// ¿Es un emulador o una máquina virtual funcionando? (Una carpeta de `carpetasDeMaquinas` con algo adentro abierto
    /// por uno de `programasDeMaquinas`.) Igual que la base de datos: su disco virtual (de 1 a 40 GB) cambia sin parar
    /// mientras está prendida y una copia de ese momento queda a medias. La copia en vivo lo llevaba cada vez que se
    /// quedaba quieto un rato: un emulador pasó 92 veces por la papelera en una semana (113 GB, 30/10/2026). Se anota
    /// como no leída y, cuando se apaga, viaja una sola vez. Lo usa `prendida`.
    static func maquinaVirtualPrendida(_ carpeta: String) -> Bool {
        let nombre = carpeta.nombreFinal
        guard carpetasDeMaquinas.contains(where: { nombre.hasSuffix($0) }) else { return false }
        let abiertos = archivosDeMaquinasPrendidas()
        guard !abiertos.isEmpty else { return false }
        // El sistema da las rutas reales (sin atajos como /tmp): se compara contra la real de la carpeta.
        guard let real = realpath(carpeta, nil) else { return false }
        defer { free(real) }
        let prefijo = String(cString: real) + "/"
        return abiertos.contains { $0.hasPrefix(prefijo) }
    }

    /// Los archivos que tienen abiertos ahora los programas de `programasDeMaquinas`. Mirar los nombres de todos los
    /// programas cuesta un par de milisegundos; los archivos, solo de los que coinciden (casi nunca hay ninguno).
    static func archivosDeMaquinasPrendidas() -> [String] {
        let cuantos = proc_listallpids(nil, 0)
        guard cuantos > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(cuantos) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var nombre = [CChar](repeating: 0, count: 256)
        var archivos: [String] = []
        for pid in pids.prefix(Int(max(n, 0))) where pid > 0 {
            guard proc_name(pid, &nombre, UInt32(nombre.count)) > 0 else { continue }
            let programa = String(cString: nombre)
            guard programasDeMaquinas.contains(where: { programa.contains($0) }) else { continue }
            archivos += archivosAbiertos(pid)
        }
        return archivos
    }

    private static func archivosAbiertos(_ pid: pid_t) -> [String] {
        let paso = MemoryLayout<proc_fdinfo>.stride
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / paso + 16)
        let usados = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, Int32(fds.count * paso))
        guard usados > 0 else { return [] }
        let tamano = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
        var rutas: [String] = []
        for fd in fds.prefix(Int(usados) / paso) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, tamano) == tamano else { continue }
            rutas.append(withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) })
        }
        return rutas
    }

    /// ¿Algo que hay que dejar quieto de los dos lados hasta que se apague? (Una base de datos o una máquina virtual
    /// funcionando.) Lo usan las dos fotos (`recorrer` y la de zonas).
    static func prendida(_ carpeta: String) -> Bool { baseDeDatosPrendida(carpeta) || maquinaVirtualPrendida(carpeta) }

    /// La zona (o la carpeta de arriba más cercana) que está prendida (ver `prendida`), relativa a `raiz`; nil si no
    /// hay ninguna. Para la foto de zonas, que entra directo a una carpeta sin pasar por las de arriba.
    static func prendida(_ raiz: String, arribaDe zona: String) -> String? {
        var r = zona
        while !r.isEmpty {
            if prendida(raiz + "/" + r) { return r }
            r = r.padre
        }
        return nil
    }

    private static func anotar(_ e: Entrada, _ ruta: String, en foto: inout Foto) {
        if e.tipo == .archivo, foto.entradas[ruta]?.tipo != .archivo {
            foto.archivos += 1
            foto.bytes = Rutas.sumar(foto.bytes, e.tamano)
        }
        foto.entradas[ruta] = e
    }

    /// La entrada de una carpeta, archivo o enlace a partir de sus datos (nil para sockets y otros especiales).
    static func entrada(_ s: stat, _ completa: String) -> Entrada? {
        switch s.st_mode & S_IFMT {
        case S_IFDIR: return Entrada(tipo: .carpeta, mtime: Int64(bitPattern: UInt64(s.st_ino)), modo: UInt16(s.st_mode & 0o777))
        case S_IFLNK: return Entrada(tipo: .enlace, destino: leerEnlace(completa))
        case S_IFREG:
            let m = Int64(s.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(s.st_mtimespec.tv_nsec)
            return Entrada(tipo: .archivo, tamano: max(0, Int64(s.st_size)), mtime: m, modo: UInt16(s.st_mode & 0o777))
        default: return nil
        }
    }

    static func leerEnlace(_ ruta: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(ruta, &buf, Int(PATH_MAX))
        guard n >= 0 else { return "" }
        return String(decoding: buf[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Datos de una sola ruta (para revisar justo antes y después de copiar).
    static func entrada(_ completa: String) -> Entrada? {
        var s = stat()
        guard lstat(completa, &s) == 0 else { return nil }
        return entrada(s, completa)
    }
}

/// Medir una carpeta (cuántos archivos y cuánto ocupan) sin guardar nada: para mostrar tamaños en la interfaz.
public enum Medidor {
    public static func medir(_ raiz: String, reglas: Reglas = .porDefecto, cancelado: () -> Bool = { false }) -> (archivos: Int, bytes: Int64) {
        guard let c = strdup(raiz) else { return (0, 0) }
        defer { free(c) }
        var argumentos: [UnsafeMutablePointer<CChar>?] = [c, nil]
        guard let fts = fts_open(&argumentos, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return (0, 0) }
        defer { fts_close(fts) }
        var archivos = 0, bytes: Int64 = 0
        let largo = raiz.utf8.count
        while let e = fts_read(fts) {
            if archivos & 1023 == 0 && cancelado() { break }
            let info = Int32(e.pointee.fts_info)
            guard e.pointee.fts_level > 0, info != FTS_DP else { continue }
            let completa = String(cString: e.pointee.fts_path)
            let ruta = String(completa.utf8.dropFirst(largo + 1)) ?? ""
            if reglas.excluye(nombre: ruta.nombreFinal, ruta: ruta) {
                if info == FTS_D { fts_set(fts, e, FTS_SKIP) }
                continue
            }
            if info == FTS_F { archivos += 1; bytes = Rutas.sumar(bytes, max(0, Int64(e.pointee.fts_statp.pointee.st_size))) }
        }
        return (archivos, bytes)
    }
}
