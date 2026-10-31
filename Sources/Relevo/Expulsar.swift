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
    /// Cómo se muestra un disco en la lista: si es el hub o el portátil de un vínculo, se aclara (pueden llamarse igual).
    func etiqueta(_ v: Volumen) -> String {
        if coordinadores.contains(where: { $0.portatil?.uuid == v.uuid }) { return v.nombre + " · " + T("portátil") }
        if coordinadores.contains(where: { $0.hub?.uuid == v.uuid }) { return v.nombre + " · " + T("hub") }
        return v.nombre
    }

    /// Expulsa los discos elegidos. Antes copia lo pendiente de los portátiles; si alguno no se puede, dice qué lo usa.
    func expulsar(_ discos: [Volumen]) {
        guard !discos.isEmpty else { return }
        let afectados = coordinadores.filter { c in c.portatil.map { p in discos.contains { $0.uuid == p.uuid } } ?? false }
        // Los portátiles que afuera llevan el nombre del hub (se lo pone `Discos.expulsar` antes de expulsarlos).
        var nombresAfuera: [String: String] = [:]
        for c in afectados {
            if let p = c.portatil, let v = c.vinculo, Vinculo.discosEnteros(v.hub, v.portatil), let n = v.nombreAfuera { nombresAfuera[p.uuid] = n }
        }
        aviso = T("Copiando lo pendiente y expulsando…")
        let grupo = DispatchGroup()
        for c in afectados { grupo.enter(); c.copiarPendiente { grupo.leave() } }
        grupo.notify(queue: .main) { [weak self] in
            guard let self else { return }
            for c in afectados { if let p = c.portatil { c.vaASerExpulsado(p) } }
            DispatchQueue.global(qos: .userInitiated).async {
                var bien: [String] = [], mal: [String] = []
                for elegido in discos {
                    // Se busca de nuevo por su UUID: la lista pudo quedar vieja (si un disco cambió de nombre, su ruta
                    // ahora puede ser la de otro). Si ya no está (salió junto con otra parte del mismo disco), cuenta.
                    guard let v = Discos.buscar(elegido.uuid) else { bien.append(elegido.nombre); continue }
                    switch Discos.expulsar(v, nombreAfuera: nombresAfuera[v.uuid]) {
                    case .success: bien.append(v.nombre)
                    case .failure(let e):
                        mal.append(e.uso.vacio ? "\(v.nombre) (\(e.detalle))" : "\(v.nombre): " + T("lo está usando %@", e.uso.texto))
                        DispatchQueue.main.async { self.noSePudoExpulsar(e) }
                    }
                }
                DispatchQueue.main.async {
                    if mal.isEmpty {
                        self.aviso = T("Listo: expulsé %@. Ya podés desenchufarlos.", bien.joined(separator: ", "))
                        Notificar.enviar(T("Discos expulsados"), T("Ya podés desenchufar %@.", bien.joined(separator: ", ")))
                    } else {
                        self.aviso = (bien.isEmpty ? "" : T("Expulsé %@. ", bien.joined(separator: ", ")))
                            + T("No pude expulsar: %@. Cerrá eso y probá de nuevo.", mal.joined(separator: "; "))
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
