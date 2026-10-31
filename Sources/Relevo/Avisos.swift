import AppKit
import CoreGraphics
import Foundation
import IOKit.ps

/// git sin depender de nada: lo busca donde suele estar y nunca usa `/usr/bin/git` si no están las herramientas
/// (ese "git" de macOS abre un cartel para instalarlas).
enum Git {
    /// Sin ejecutar nada (se consulta mientras se dibuja la pantalla: esperar a un proceso ahí traba la app).
    /// La carpeta de Xcode elegida se lee del enlace donde la guarda `xcode-select`.
    static let ruta: String? = {
        var candidatos = ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git"]
        if let xcode = try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link") {
            candidatos.append(xcode + "/usr/bin/git")
        }
        return candidatos.first { FileManager.default.isExecutableFile(atPath: $0) }
    }()

    static func esRepo(_ carpeta: String) -> Bool { FileManager.default.fileExists(atPath: carpeta + "/.git") }

    /// Relevo corre git solo (al irse, con el .gitignore, en Repos) sobre proyectos que vienen del portátil: su
    /// .git/config puede traer comandos (core.fsmonitor, filtros, hooks) que git ejecutaría como vos al hacer
    /// `git status` (auditoría del 23/10). Estas consultas los apagan.
    static func git(_ carpeta: String, _ args: [String]) -> String? {
        guard let ruta else { return nil }
        // Sin candados opcionales: un `git status` de Relevo no reescribe el índice (si no, Relevo mismo lo cambiaba y
        // después lo veía como un cambio del repo para copiar).
        return correr(ruta, opcionesSeguras(carpeta, git: ruta) + ["-C", carpeta] + args, entorno: ["GIT_OPTIONAL_LOCKS": "0"])
    }

    /// Las opciones que apagan todo lo que la configuración del repo podría ejecutar en una consulta (status, ls-files,
    /// rev-list, branch): el monitor de archivos, los hooks y cada filtro definido. El filtro de Git LFS se deja solo si
    /// es exactamente el estándar (si no, LFS mostraría todo como cambiado). Leer la configuración no ejecuta nada.
    static func opcionesSeguras(_ carpeta: String?, git: String) -> [String] {
        var o = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.untrackedCache=false"]
        guard let carpeta else { return o }
        let lfs = ["filter.lfs.clean": "git-lfs clean -- %f", "filter.lfs.smudge": "git-lfs smudge -- %f",
                   "filter.lfs.process": "git-lfs filter-process"]
        let lista = correr(git, ["-C", carpeta, "config", "--get-regexp", #"^filter\..*\.(clean|smudge|process)$"#]) ?? ""
        var nombres = Set<String>()
        for linea in lista.split(separator: "\n") {
            let partes = linea.split(separator: " ", maxSplits: 1).map(String.init)
            guard let clave = partes.first, clave.hasPrefix("filter.") else { continue }
            if lfs[clave] != nil, partes.count == 2, partes[1] == lfs[clave] { continue }
            nombres.insert(String(clave.dropFirst(7).split(separator: ".").dropLast().joined(separator: ".")))
        }
        for n in nombres.sorted() {
            o += ["-c", "filter.\(n).clean=", "-c", "filter.\(n).smudge=", "-c", "filter.\(n).process=", "-c", "filter.\(n).required=false"]
        }
        return o
    }

    /// Cambios sin commit y commits sin subir (sin consultar la red).
    static func pendientes(_ carpeta: String) -> (sinCommit: Int, sinSubir: Int)? {
        guard esRepo(carpeta), let estado = git(carpeta, ["status", "--porcelain"]) else { return nil }
        let sinCommit = estado.split(separator: "\n").count
        let sinSubir = Int(git(carpeta, ["rev-list", "--count", "@{u}..HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        return (sinCommit, sinSubir)
    }

    /// Lo que el `.gitignore` deja afuera, en rutas relativas a la carpeta del repo.
    static func ignoradas(_ carpeta: String) -> Set<String> {
        guard esRepo(carpeta),
              let salida = git(carpeta, ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "--no-empty-directory"])
        else { return [] }
        return Set(salida.split(separator: "\n").map { l in
            var r = String(l)
            if r.hasSuffix("/") { r.removeLast() }
            return r
        })
    }

    @discardableResult
    static func correr(_ programa: String, _ args: [String], tope: TimeInterval = 20, entorno: [String: String] = [:]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: programa)
        p.arguments = args
        if !entorno.isEmpty { p.environment = ProcessInfo.processInfo.environment.merging(entorno) { $1 } }
        let salida = Pipe()
        p.standardOutput = salida
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let reloj = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + tope, execute: reloj)
        let datos = salida.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        reloj.cancel()
        return p.terminationStatus == 0 ? String(decoding: datos, as: UTF8.self) : nil
    }
}

/// Revisiones rápidas sobre las carpetas que se sincronizan.
enum Revisar {
    /// Una ruta lista para pegar en la terminal: entre comillas simples, sin que `$( )`, comillas o comillas
    /// invertidas del nombre de una carpeta (que viene del disco) se ejecuten.
    static func comillas(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Proyectos sin sus dependencias (por ejemplo, si se eligió no llevarlas) y el comando para instalarlas.
    static func dependenciasFaltantes(raiz: String, pares: [String]) -> [(proyecto: String, comando: String)] {
        let fm = FileManager.default
        var salida: [(String, String)] = []
        for par in pares where !par.hasSuffix("/.") {
            let d = raiz + "/" + par
            if fm.fileExists(atPath: d + "/package.json"), !fm.fileExists(atPath: d + "/node_modules") {
                let gestor = fm.fileExists(atPath: d + "/pnpm-lock.yaml") ? "pnpm install"
                    : fm.fileExists(atPath: d + "/yarn.lock") ? "yarn install"
                    : fm.fileExists(atPath: d + "/bun.lockb") || fm.fileExists(atPath: d + "/bun.lock") ? "bun install" : "npm install"
                salida.append((par, "cd \(comillas(d)) && \(gestor)"))
            } else if fm.fileExists(atPath: d + "/Podfile"), !fm.fileExists(atPath: d + "/Pods") {
                salida.append((par, "cd \(comillas(d)) && pod install"))
            }
        }
        return salida
    }

    /// Cuántos proyectos tienen archivos de claves (.env…) en su carpeta principal.
    static func proyectosConClaves(raiz: String, pares: [String]) -> Int {
        pares.filter { par in
            let nombres = (try? FileManager.default.contentsOfDirectory(atPath: raiz + "/" + Coordinador.base(par))) ?? []
            return nombres.contains { $0.hasPrefix(".env") && !$0.hasSuffix(".example") && !$0.hasSuffix(".sample") }
        }.count
    }
}

enum Energia {
    /// Enchufada a la corriente (o una Mac de escritorio).
    static var enchufada: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let tipo = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return tipo == kIOPMACPowerKey
    }

    /// Segundos desde la última vez que se tocó el teclado o el mouse.
    static var inactiva: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}
