import AppKit
import Foundation

extension Discos {
    /// Discos que se pueden expulsar (todos menos el de la Mac), incluidos los que Relevo ocultó del Finder.
    static func expulsables() -> [Volumen] {
        montados().filter { $0.externo && $0.ruta.hasPrefix("/Volumes/") }
            .sorted { $0.nombre.localizedStandardCompare($1.nombre) == .orderedAscending }
    }
}

extension Gestor {
    /// Cómo se muestra un disco en las listas (menú "Expulsar discos", "¿Me voy?", Discos): su nombre. Solo si otro disco
    /// conectado se llama igual se aclara cuál es el hub y cuál el portátil (si no, quedaba "Trabajo (portátil) ·
    /// portátil", con el dato repetido: 31/10/2026).
    func etiqueta(_ v: Volumen) -> String {
        guard Discos.montados().contains(where: { $0.uuid != v.uuid && $0.nombre == v.nombre }) else { return v.nombre }
        if coordinadores.contains(where: { $0.portatil?.uuid == v.uuid }) { return v.nombre + " · " + T("portátil") }
        if coordinadores.contains(where: { $0.hub?.uuid == v.uuid }) { return v.nombre + " · " + T("disco de casa") }
        return v.nombre
    }

    /// Los discos que expulsa "Me voy": todos los externos (el portátil, el hub, Time Machine…). En las pruebas, solo los
    /// de ensayo (empiezan con "SG"): una prueba nunca expulsa discos reales.
    static func paraIrse() -> [Volumen] {
        let todos = Discos.expulsables()
        return Notificar.prueba ? todos.filter { $0.nombre.hasPrefix("SG") } : todos
    }

    /// "Me voy": pregunta (salvo `preguntar` = false, solo en las pruebas), copia lo último de cada vínculo y, si todo
    /// quedó bien, expulsa todos los discos. Si algo necesita tu OK o quedó sin copiar, no expulsa nada y lo dice. Si un
    /// disco no sale porque una app lo usa, Inicio muestra cuál y ofrece cerrarla (pregunta antes). Lo llaman el menú,
    /// el botón de Inicio, el atajo ⌃⌥⌘L y el enlace relevo://mevoy (`desdeEnlace`: puede venir de una página web).
    func meVoy(preguntar: Bool = true, desdeEnlace: Bool = false) {
        guard !yendose else { return }
        let discos = Self.paraIrse()
        guard !discos.isEmpty else { aviso = T("No hay discos para expulsar."); return }
        if preguntar {
            NSApp.activate(ignoringOtherApps: true)
            let a = NSAlert()
            a.messageText = T("¿Me voy?")
            a.informativeText = T("Vamos a copiar lo último y expulsar todos los discos: %@.", discos.map(etiqueta).joined(separator: ", "))
                + (desdeEnlace ? "\n\n" + T("Lo pidió un enlace relevo:// (desde Atajos, Raycast o una página web). Si no fuiste vos, tocá Cancelar.") : "")
            a.addButton(withTitle: T("Sí, me voy"))
            a.addButton(withTitle: T("Cancelar"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        yendose = true
        bloqueos = []
        aviso = T("Copiando lo último antes de irte…")
        Bitacora.anotar("Me voy: copio lo último y expulso \(discos.map(\.nombre).joined(separator: ", "))")
        var todoBien = true
        var notas: [String] = []
        let grupo = DispatchGroup()
        for c in coordinadores {
            grupo.enter()
            c.prepararseParaIrse { bien, nota in
                if !bien { todoBien = false }
                if let nota { notas.append(nota) }
                grupo.leave()
            }
        }
        grupo.notify(queue: .main) { [weak self] in
            guard let self else { return }
            self.yendose = false
            guard todoBien else {
                // El vínculo que frenó ya dice por qué (lo que necesita tu OK, lo que quedó sin copiar).
                self.aviso = T("No expulsé ningún disco: antes de irte fijate el aviso de abajo.")
                Bitacora.anotar("Me voy: frenado antes de expulsar")
                return
            }
            // Se buscan de nuevo: mientras copiaba pudo enchufarse o salir alguno.
            self.expulsar(Self.paraIrse(), irse: true, notas: notas)
        }
    }

    /// Expulsa los discos elegidos. Antes copia lo pendiente de los portátiles; si alguno no se puede, dice qué lo usa.
    /// `irse`: lo pidió "Me voy" (lo copió todo antes); `notas`: lo que hay que decir al final (git sin subir).
    func expulsar(_ discos: [Volumen], irse: Bool = false, notas: [String] = []) {
        guard !discos.isEmpty else { return }
        let afectados = coordinadores.filter { c in c.portatil.map { p in discos.contains { $0.uuid == p.uuid } } ?? false }
        // Los portátiles que afuera llevan el nombre del hub (se lo pone `Discos.expulsar` antes de expulsarlos).
        var nombresAfuera: [String: String] = [:]
        for c in afectados {
            if let p = c.portatil, let v = c.vinculo, Vinculo.discosEnteros(v.hub, v.portatil), let n = v.nombreAfuera { nombresAfuera[p.uuid] = n }
        }
        aviso = irse ? T("Expulsando los discos…") : T("Copiando lo pendiente y expulsando…")
        let grupo = DispatchGroup()
        for c in afectados { grupo.enter(); c.copiarPendiente { grupo.leave() } }
        grupo.notify(queue: .main) { [weak self] in
            guard let self else { return }
            for c in afectados { if let p = c.portatil { c.vaASerExpulsado(p) } }
            DispatchQueue.global(qos: .userInitiated).async {
                var bien: [String] = [], mal: [String] = [], salieron = Set<String>()
                for elegido in discos {
                    // Se busca de nuevo por su UUID: la lista pudo quedar vieja (si un disco cambió de nombre, su ruta
                    // ahora puede ser la de otro). Si ya no está (salió junto con otra parte del mismo disco), cuenta.
                    guard let v = Discos.buscar(elegido.uuid) else { bien.append(elegido.nombre); salieron.insert(elegido.uuid); continue }
                    switch Discos.expulsar(v, nombreAfuera: nombresAfuera[v.uuid]) {
                    case .success: bien.append(v.nombre); salieron.insert(v.uuid)
                    case .failure(let e):
                        mal.append(e.uso.vacio ? "\(v.nombre) (\(e.detalle))" : "\(v.nombre): " + T("lo está usando %@", e.uso.texto))
                        DispatchQueue.main.async { self.noSePudoExpulsar(e) }
                    }
                }
                DispatchQueue.main.async {
                    let nota = notas.isEmpty ? "" : "\n" + notas.joined(separator: "\n")
                    if irse {
                        for c in afectados where c.vinculo.map({ salieron.contains($0.portatil.uuid) }) ?? false { c.quedoListoParaIrse() }
                    }
                    Bitacora.anotar("Expulsados: \(bien.joined(separator: ", "))" + (mal.isEmpty ? "" : "; no salieron: " + mal.joined(separator: "; ")))
                    if mal.isEmpty {
                        if irse {
                            self.aviso = T("Listo: todo copiado y los discos expulsados (%@). Ya podés desenchufarlos.", bien.joined(separator: ", ")) + nota
                            Notificar.enviar(T("Listo para irte"), T("Todo copiado. Ya podés desenchufar %@.", bien.joined(separator: ", ")))
                        } else {
                            self.aviso = T("Listo: expulsé %@. Ya podés desenchufarlos.", bien.joined(separator: ", "))
                            Notificar.enviar(T("Discos expulsados"), T("Ya podés desenchufar %@.", bien.joined(separator: ", ")))
                        }
                    } else {
                        self.aviso = (irse ? T("Está todo copiado. ") : "") + (bien.isEmpty ? "" : T("Expulsé %@. ", bien.joined(separator: ", ")))
                            + T("No pude expulsar: %@. Cerrá eso y probá de nuevo.", mal.joined(separator: "; ")) + nota
                        Notificar.enviar(T("No se pudo expulsar todo"), mal.joined(separator: "; "))
                    }
                    afectados.forEach { $0.terminoExpulsion() }
                    self.coordinadores.forEach { $0.discosCambiaron() }
                }
            }
        }
    }

    /// Antes de dormir: copia lo pendiente de todos los vínculos.
    func antesDeDormir(_ listo: @escaping () -> Void) {
        let grupo = DispatchGroup()
        for c in coordinadores { grupo.enter(); c.copiarPendiente { grupo.leave() } }
        grupo.notify(queue: .main, execute: listo)
    }

    // MARK: - Cuando algo traba la expulsión

    /// Lo llaman "Expulsar discos" y "Me voy" cuando un disco no salió: queda en `bloqueos` para que Inicio diga
    /// quién lo usa y ofrezca cerrarlo.
    func noSePudoExpulsar(_ e: Discos.ErrorExpulsar) {
        let nombreAfuera = coordinadores.first { $0.portatil?.uuid == e.volumen.uuid }?.vinculo?.nombreAfuera
        bloqueos.removeAll { $0.uuid == e.volumen.uuid }
        bloqueos.append(Bloqueo(uuid: e.volumen.uuid, nombre: etiqueta(e.volumen), uso: e.uso, nombreAfuera: nombreAfuera))
    }

    /// "Cerrar y expulsar" (después de que confirmaste): cierra lo que lo usa y vuelve a expulsar.
    func cerrarYExpulsar(_ b: Bloqueo) {
        bloqueos.removeAll { $0.uuid == b.uuid }
        aviso = T("Cerrando lo que usa %@ y expulsando…", b.nombre)
        let coordinador = coordinadores.first { $0.portatil?.uuid == b.uuid }
        DispatchQueue.global(qos: .userInitiated).async {
            Procesos.cerrar(b.uso.cerrables)
            guard Discos.buscar(b.uuid) != nil else {
                DispatchQueue.main.async { self.aviso = T("Listo: %@ ya no está montado. Ya podés desenchufarlo.", b.nombre) }
                return
            }
            // Lo que esas apps guardaron al cerrarse se copia antes de expulsar.
            let copiado = DispatchSemaphore(value: 0)
            DispatchQueue.main.async {
                if let coordinador { coordinador.copiarPendiente { copiado.signal() } } else { copiado.signal() }
            }
            _ = copiado.wait(timeout: .now() + 600)
            guard let v = Discos.buscar(b.uuid) else {
                DispatchQueue.main.async { self.aviso = T("Listo: %@ ya no está montado. Ya podés desenchufarlo.", b.nombre) }
                return
            }
            DispatchQueue.main.sync { coordinador?.vaASerExpulsado(v) }
            let r = Discos.expulsar(v, nombreAfuera: b.nombreAfuera)
            DispatchQueue.main.async {
                coordinador?.terminoExpulsion()
                switch r {
                case .success:
                    self.aviso = T("Listo: expulsé %@. Ya podés desenchufarlo.", b.nombre)
                    Notificar.enviar(T("Discos expulsados"), T("Ya podés desenchufar %@.", b.nombre))
                case .failure(let e):
                    self.aviso = T("Todavía no pude expulsar %@.", b.nombre)
                    self.noSePudoExpulsar(e)
                }
                self.coordinadores.forEach { $0.discosCambiaron() }
            }
        }
    }
}

/// Un disco que no se pudo expulsar y quién lo estaba usando.
struct Bloqueo: Identifiable {
    let uuid: String
    let nombre: String
    let uso: UsoDeDisco
    let nombreAfuera: String?
    var id: String { uuid }
}
