import AppKit
import Foundation

/// Quién está usando un disco (lo que traba "Expulsar" o "Me voy"), dicho claro: agrupado por la app responsable
/// ("Claude", "Terminal", "Visual Studio Code"…) y no por el nombre del proceso suelto (`caffeinate`, `zsh`, `node`…).
/// Regla al expulsar (`Discos.expulsar`): lo que corre de fondo, sin ninguna app con ventana arriba (scripts, servidores,
/// terminales sueltas), se cierra solo; lo que depende de una app con ventana se muestra y se ofrece cerrar
/// (`Gestor.cerrarYExpulsar`), porque puede ser trabajo tuyo.
struct UsoDeDisco: Equatable {
    struct Grupo: Identifiable, Equatable {
        /// La app responsable (la que abrió esos procesos) o, si no hay, el nombre del proceso.
        let app: String
        var pids: [pid_t] = []
        /// Carpetas del disco donde están parados o tienen algo abierto (para decir "Tienda, Blog…").
        var carpetas: Set<String> = []
        /// Se puede cerrar desde Relevo (no es el Finder ni algo del sistema).
        var cerrable = true
        /// Corre de fondo: ninguna app con ventana lo abrió. Se cierra solo al expulsar.
        var deFondo = false
        var id: String { app }
    }

    var grupos: [Grupo] = []
    var vacio: Bool { grupos.isEmpty }
    var cerrables: [Grupo] { grupos.filter(\.cerrable) }
    var deFondo: [Grupo] { grupos.filter { $0.cerrable && $0.deFondo } }
    var conVentana: [Grupo] { grupos.filter { !$0.deFondo } }

    /// "Claude (en Tienda, Blog), Terminal".
    var texto: String {
        grupos.map { g in
            let c = g.carpetas.sorted().prefix(3)
            return c.isEmpty ? g.app : g.app + " (" + T("en %@", c.joined(separator: ", ")) + ")"
        }.joined(separator: ", ")
    }
}

enum Procesos {
    /// Nunca se cierran desde Relevo (son de macOS o se cierran de otra forma).
    private static let intocables: Set<String> = ["Finder", "launchd", "kernel_task", "loginwindow", "WindowServer", "Dock",
                                                  "mds", "mds_stores", "mdworker", "mdworker_shared", "fseventsd", "Relevo"]

    /// Quién usa el disco montado en `ruta`, agrupado por app. Puede tardar un par de segundos (lsof).
    static func usando(_ ruta: String) -> UsoDeDisco {
        let tabla = tablaDeProcesos()
        var grupos: [String: UsoDeDisco.Grupo] = [:]
        var orden: [String] = []
        for (pid, nombreArchivo) in abiertos(ruta) where pid != getpid() {
            let (app, deFondo) = appResponsable(pid, tabla)
            let clave = app + (deFondo ? "·fondo" : "")
            if grupos[clave] == nil {
                // Nunca algo de macOS (aunque corra a tu nombre, como la vista rápida o los íconos).
                let ejecutable = tabla[pid]?.ejecutable ?? ""
                let delSistema = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"].contains { ejecutable.hasPrefix($0) }
                let tocable = !delSistema && !intocables.contains(app) && !intocables.contains(tabla[pid]?.nombre ?? "")
                grupos[clave] = UsoDeDisco.Grupo(app: deFondo ? T("%@ (en segundo plano)", app) : app, cerrable: tocable, deFondo: deFondo)
                orden.append(clave)
            }
            if !grupos[clave]!.pids.contains(pid) { grupos[clave]!.pids.append(pid) }
            if let c = carpetaDeProyecto(nombreArchivo, en: ruta) { grupos[clave]!.carpetas.insert(c) }
        }
        return UsoDeDisco(grupos: orden.compactMap { grupos[$0] })
    }

    /// Cierra esos procesos de forma prolija: a las apps con ventana se les pide que se cierren (pueden preguntar si
    /// guardar); al resto se le manda la señal de terminar. Espera hasta 6 segundos. Devuelve true si se cerraron todos.
    @discardableResult
    static func cerrar(_ grupos: [UsoDeDisco.Grupo]) -> Bool {
        let pids = grupos.filter(\.cerrable).flatMap(\.pids)
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                app.terminate()
            } else {
                kill(pid, SIGTERM)
            }
        }
        for i in 0..<40 {
            if pids.allSatisfy({ kill($0, 0) != 0 }) { return true }
            // Las terminales (zsh, bash…) ignoran la señal de terminar: a los 2 segundos, la de "se cortó la terminal".
            if i == 10 { for pid in pids where kill(pid, 0) == 0 { kill(pid, SIGHUP) } }
            usleep(200_000)
        }
        return pids.allSatisfy { kill($0, 0) != 0 }
    }

    // MARK: Por dentro

    private struct Proceso { let padre: pid_t; let nombre: String; let ejecutable: String; let argumentos: String }

    /// Todos los procesos: padre, nombre corto, ejecutable y argumentos (de `ps`, en dos pasadas: la ruta del
    /// ejecutable puede tener espacios y así no se mezcla con los argumentos).
    private static func tablaDeProcesos() -> [pid_t: Proceso] {
        func filas(_ campos: String) -> [(pid_t, String, String)] {
            correr("/bin/ps", ["-axww", "-o", campos]).split(separator: "\n").compactMap { linea in
                let partes = linea.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard partes.count >= 2, let pid = pid_t(partes[0]) else { return nil }
                return (pid, String(partes[1]), partes.count > 2 ? String(partes[2]) : "")
            }
        }
        var argumentos: [pid_t: String] = [:]
        for (pid, primero, resto) in filas("pid=,args=") { argumentos[pid] = resto.isEmpty ? primero : primero + " " + resto }
        var tabla: [pid_t: Proceso] = [:]
        for (pid, padre, ejecutable) in filas("pid=,ppid=,comm=") {
            tabla[pid] = Proceso(padre: pid_t(padre) ?? 0, nombre: (ejecutable as NSString).lastPathComponent,
                                 ejecutable: ejecutable, argumentos: argumentos[pid] ?? ejecutable)
        }
        return tabla
    }

    /// La app que abrió ese proceso y si corre de fondo. Se sube por los padres: la primera app con ventana (en el
    /// Dock) es la responsable. Si no hay ninguna (lo arrancó launchd, un script o una terminal que ya se cerró), es de
    /// fondo; se nombra por la app de su ejecutable o por el proceso ("Claude" si corre `claude`).
    private static func appResponsable(_ pid: pid_t, _ tabla: [pid_t: Proceso]) -> (String, Bool) {
        var actual: pid_t? = pid
        var vistos = Set<pid_t>()
        var primero: String?, deEjecutable: String?
        var esClaude = false
        while let p = actual, p > 1, vistos.insert(p).inserted, let info = tabla[p] {
            if primero == nil { primero = info.nombre }
            // Apps con ventana o en la barra de menú: son tuyas y se ofrece cerrarlas (no se cierran solas).
            if let app = NSRunningApplication(processIdentifier: p), app.activationPolicy != .prohibited {
                return (app.localizedName ?? nombreDeApp(info.ejecutable) ?? info.nombre, false)
            }
            if deEjecutable == nil { deEjecutable = nombreDeApp(info.ejecutable) }
            if info.argumentos.contains("/claude") || info.argumentos.contains("claude ") || info.argumentos.contains(".claude/") { esClaude = true }
            actual = info.padre
        }
        return (esClaude ? "Claude" : (deEjecutable ?? primero ?? T("Un programa")), true)
    }

    /// "Visual Studio Code" de ".../Visual Studio Code.app/Contents/MacOS/Electron …".
    private static func nombreDeApp(_ ruta: String) -> String? {
        guard let r = ruta.range(of: ".app/Contents/") else { return nil }
        return (String(ruta[..<r.lowerBound]) as NSString).lastPathComponent
    }

    /// (pid, archivo) de lo que hay abierto o donde hay alguien parado adentro del disco.
    private static func abiertos(_ ruta: String) -> [(pid_t, String)] {
        let salida = correr("/usr/sbin/lsof", ["-F", "pn", "+f", "--", ruta])
        var lista: [(pid_t, String)] = []
        var pid: pid_t?
        for linea in salida.split(separator: "\n") {
            if linea.hasPrefix("p") { pid = pid_t(linea.dropFirst()) }
            else if linea.hasPrefix("n"), let pid { lista.append((pid, desescapar(String(linea.dropFirst())))) }
        }
        return lista
    }

    /// lsof escribe lo que no es ASCII como texto ("porta\\xcc\\x81til"): se vuelve a armar el texto de verdad.
    private static func desescapar(_ s: String) -> String {
        guard s.contains("\\x") else { return s }
        var bytes: [UInt8] = []
        var u = Array(s.utf8)[...]
        while let c = u.first {
            if c == UInt8(ascii: "\\"), u.count >= 4, u[u.startIndex + 1] == UInt8(ascii: "x"),
               let b = UInt8(String(decoding: u[(u.startIndex + 2)...(u.startIndex + 3)], as: UTF8.self), radix: 16) {
                bytes.append(b); u = u.dropFirst(4)
            } else {
                bytes.append(c); u = u.dropFirst()
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// "/Volumes/X/Proyectos/Tienda/src" → "Tienda" (la carpeta de proyecto o la primera carpeta del disco).
    private static func carpetaDeProyecto(_ archivo: String, en raiz: String) -> String? {
        guard archivo.hasPrefix(raiz + "/") else { return nil }
        let partes = archivo.dropFirst(raiz.count + 1).split(separator: "/").map(String.init)
        guard let primera = partes.first else { return nil }
        if partes.count >= 2, ["Proyectos", "Projects"].contains(primera) { return partes[1] }
        return primera
    }

    private static func correr(_ programa: String, _ argumentos: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: programa)
        p.arguments = argumentos
        let tubo = Pipe()
        p.standardOutput = tubo
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let datos = tubo.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: datos, as: UTF8.self)
    }
}
