import Foundation
import Network

/// A loopback USB bridge adapter, not a controller IP/network connection.
/// The external adapter owns AOA/iAP2; Parrot Lab owns all libmux channels.
final class SC3MuxTCPLink: SC2MuxByteLink {
    var onBytes: ((Data) -> Void)?
    var onClosed: ((Error?) -> Void)?
    private let queue = DispatchQueue(label: "parrotlab.sc3.bridge-link")
    private let port: UInt16
    private var connection: NWConnection?
    private var pending: [Data] = []
    private var queuedBytes = 0
    private var ready = false, writing = false, closing = false
    init(port: UInt16) { self.port = port }
    func start() {
        queue.async { [weak self] in
            guard let self, self.connection == nil, !self.closing,
                  let port = NWEndpoint.Port(rawValue: self.port) else { return }
            let connection = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
            self.connection = connection
            connection.stateUpdateHandler = { [weak self, weak connection] state in
                guard let self, let connection, self.connection === connection else { return }
                switch state {
                case .ready: self.ready = true; self.flush(); self.receive(connection)
                case .failed(let error): self.finish(error)
                default: break
                }
            }
            connection.start(queue: self.queue)
        }
    }
    func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self, !self.closing else { return }
            guard self.queuedBytes + data.count <= 1_048_576 else {
                self.finish(NSError(domain: "SC3Mux", code: 1, userInfo: [NSLocalizedDescriptionKey: "SC3 bridge write queue exceeded its limit"])); return
            }
            self.pending.append(data); self.queuedBytes += data.count; self.flush()
        }
    }
    private func flush() {
        guard let connection, ready, !writing else { return }
        guard !pending.isEmpty else { if closing { finish(nil, notify: false) }; return }
        let bytes = pending.removeFirst(); writing = true
        connection.send(content: bytes, completion: .contentProcessed { [weak self, weak connection] error in
            guard let self, let connection, self.connection === connection else { return }
            self.queuedBytes -= bytes.count; self.writing = false
            if let error { self.finish(error) } else { self.flush() }
        })
    }
    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection, !self.closing else { return }
            if let data, !data.isEmpty { self.onBytes?(data) }
            if complete || error != nil { self.finish(error) } else { self.receive(connection) }
        }
    }
    func stop() {
        queue.async {
            guard !self.closing else { return }; self.closing = true
            self.flush()
            // Keep the adapter alive long enough to drain neutral/ownership
            // return writes; bound shutdown when a USB bridge is stalled.
            self.queue.asyncAfter(deadline: .now() + 1) { self.finish(nil, notify: false) }
        }
    }
    private func finish(_ error: Error?, notify: Bool = true) {
        let active = connection != nil
        connection?.cancel(); connection = nil; pending.removeAll(); queuedBytes = 0
        ready = false; writing = false; closing = true
        if active, notify { onClosed?(error) }
    }
    deinit { connection?.cancel() }
}

/// One libmux session and one loopback-only RTSP TCP proxy. State and callback
/// generation live on this queue; aircraft commands never pass through NET.
final class SC3MuxBridge {
    var onConnected: (() -> Void)?
    var onTransport: ((Data) -> Void)?
    private var onVideo: ((Result<URL, Error>) -> Void)?
    var onClosed: ((String) -> Void)?
    private let queue = DispatchQueue(label: "parrotlab.sc3.mux")
    private var wire = SC3MuxProtocol()
    private var link: SC2MuxByteLink?
    private var generation: UInt64 = 0
    private var videoGeneration: UInt64 = 0
    private var listener: NWListener?
    private var peer: NWConnection?
    private var peerReading = false
    private var toDrone: [Data] = []
    private var toDroneBytes = 0
    private var toMacBytes = 0
    private var active = false
    private var packets: UInt64 = 0

    func start(link: SC2MuxByteLink) {
        queue.async { [weak self] in
            guard let self else { return }
            self.close(); self.generation &+= 1; self.active = true; self.link = link
            self.wire = SC3MuxProtocol(); let token = self.generation
            link.onBytes = { [weak self] bytes in
                self?.queue.async {
                    guard let self, self.active, self.generation == token else { return }
                    self.packets &+= 1; self.process(self.wire.receive(bytes))
                }
            }
            link.onClosed = { [weak self] error in
                self?.queue.async {
                    guard let self, self.active, self.generation == token else { return }
                    self.fail(error?.localizedDescription ?? "SC3 USB bridge disconnected")
                }
            }
            link.start(); self.process(self.wire.start())
        }
    }
    func sendTransport(_ packet: Data) {
        queue.async { [weak self] in
            guard let self, self.active, self.wire.connected else { return }
            self.link?.write(self.wire.sendTransport(packet))
        }
    }
    func startVideo(completion: @escaping (Result<URL, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, self.active, self.wire.connected else { return }
            self.closeVideo(); self.onVideo = completion; self.process(self.wire.requestVideo())
            let token = self.videoGeneration
            self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self, self.active, self.videoGeneration == token, !self.wire.videoConnected else { return }
                self.videoFailure("SC3 video proxy timed out")
            }
        }
    }
    func stopVideo() { queue.async { [weak self] in self?.closeVideo() } }
    func stop() { queue.async { self.close() } }
    private func process(_ events: [SC3MuxEvent]) {
        for event in events {
            guard active else { return }
            switch event {
            case .write(let data): link?.write(data)
            case .connected: onConnected?()
            case .transport(let data): onTransport?(data)
            case .videoResolved: openListener()
            case .videoConnected, .videoWritable:
                flushToDrone()
                if let peer, !wire.videoWaitingACK { receivePeer(peer, token: videoGeneration) }
            case .videoData(let data): forwardToMac(data)
            case .videoClosed(let message): videoFailure(message)
            case .failed(let message): fail(message)
            }
        }
    }
    private func openListener() {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        do {
            let listener = try NWListener(using: params); self.listener = listener
            let token = videoGeneration
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, self.listener === listener, self.videoGeneration == token else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue, let url = URL(string: "rtsp://127.0.0.1:\(port)/live") else { return }
                    self.onVideo?(.success(url))
                case .failed(let error): self.videoFailure(error.localizedDescription)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] peer in
                guard let self, self.active, self.videoGeneration == token, self.peer == nil else { peer.cancel(); return }
                self.peer = peer; peer.start(queue: self.queue)
                self.process(self.wire.connectVideo()); self.receivePeer(peer, token: token)
            }
            listener.start(queue: queue)
        } catch { videoFailure(error.localizedDescription) }
    }
    private func receivePeer(_ peer: NWConnection, token: UInt64) {
        guard !peerReading else { return }; peerReading = true
        peer.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak peer] data, _, complete, error in
            guard let self, let peer, self.peer === peer, self.videoGeneration == token else { return }
            self.peerReading = false
            if let data, !data.isEmpty {
                self.toDroneBytes += data.count
                guard self.toDroneBytes <= 262_144 else { self.videoFailure("SC3 video request queue exceeded its limit"); return }
                self.toDrone.append(data); self.flushToDrone()
            }
            if complete || error != nil { self.closeVideo(); return }
            if !self.wire.videoWaitingACK { self.receivePeer(peer, token: token) }
        }
    }
    private func flushToDrone() {
        guard wire.videoConnected else { return }
        while !toDrone.isEmpty, !wire.videoWaitingACK {
            let bytes = toDrone.removeFirst(); toDroneBytes -= bytes.count
            process(wire.sendVideo(bytes))
        }
    }
    private func forwardToMac(_ data: Data) {
        guard let peer else { return }
        toMacBytes += data.count
        guard toMacBytes <= 4_194_304 else { videoFailure("Mac video consumer fell behind; restart video"); return }
        let token = videoGeneration
        peer.send(content: data, completion: .contentProcessed { [weak self, weak peer] error in
            guard let self, let peer, self.peer === peer, self.videoGeneration == token else { return }
            self.toMacBytes -= data.count
            if let error { self.videoFailure(error.localizedDescription) }
        })
    }
    private func closeVideo() {
        videoGeneration &+= 1
        listener?.cancel(); listener = nil; peer?.cancel(); peer = nil; peerReading = false
        toDrone.removeAll(); toDroneBytes = 0; toMacBytes = 0
        process(wire.closeVideo())
    }
    private func videoFailure(_ message: String) {
        closeVideo()
        onVideo?(.failure(NSError(domain: "SC3Mux", code: 2, userInfo: [NSLocalizedDescriptionKey: message])))
    }
    private func close() {
        closeVideo(); process(wire.disconnect())
        active = false; generation &+= 1
        link?.stop(); link = nil
    }
    private func fail(_ message: String) { close(); onClosed?(message) }
    var diagnosticSummary: String {
        queue.sync { "SC3 mux gen=\(generation) active=\(active) ready=\(wire.connected) reads=\(packets) " +
            "video-gen=\(videoGeneration) channel=\(wire.videoChannel?.description ?? "none") tcp=\(wire.videoConnected) " +
            "ack=\(wire.videoWaitingACK) pending-up=\(toDroneBytes) pending-down=\(toMacBytes)" }
    }
    deinit { listener?.cancel(); peer?.cancel(); link?.stop() }
}
