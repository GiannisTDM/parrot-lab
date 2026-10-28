import Foundation

protocol SC2MuxByteLink: AnyObject {
    var onBytes: ((Data) -> Void)? { get set }
    var onClosed: ((Error?) -> Void)? { get set }
    func start()
    func write(_ data: Data)
    func stop()
}

/// Duplex descriptor adapter for the AOA/iAP2 bridge. Keeping this boundary at
/// FileHandle avoids coupling libmux or ARSDK to a particular USB role driver.
final class SC2MuxFileHandleLink: SC2MuxByteLink {
    var onBytes: ((Data) -> Void)? {
        get { withStateSync { storedOnBytes } }
        set { withStateSync { storedOnBytes = newValue } }
    }
    var onClosed: ((Error?) -> Void)? {
        get { withStateSync { storedOnClosed } }
        set { withStateSync { storedOnClosed = newValue } }
    }

    private let readHandle: FileHandle
    private let writeHandle: FileHandle
    private let closesHandles: Bool
    private let stateQueue = DispatchQueue(label: "parrotlab.sc2-mux-file-state")
    private let stateQueueKey = DispatchSpecificKey<Void>()
    private let writeQueue = DispatchQueue(label: "parrotlab.sc2-mux-file-write")
    private var running = false
    private var closed = false
    private var generation: UInt64 = 0
    private var readHandlerEpoch: UInt64 = 0
    private var storedOnBytes: ((Data) -> Void)?
    private var storedOnClosed: ((Error?) -> Void)?
    private var staleReadCallbacks: UInt64 = 0
    private var droppedWriteRequests: UInt64 = 0
    private var writeErrors: UInt64 = 0
    private var bytesRead: UInt64 = 0
    private var writeHandleClosed = false // writeQueue only

    var diagnosticSummary: String {
        withStateSync {
            "link gen=\(generation) \(running ? "running" : closed ? "closed" : "stopped") " +
            "rx=\(bytesRead) stale-read=\(staleReadCallbacks) dropped-write=\(droppedWriteRequests) write-errors=\(writeErrors)"
        }
    }

    init(readHandle: FileHandle, writeHandle: FileHandle? = nil, closesHandles: Bool = false) {
        self.readHandle = readHandle
        self.writeHandle = writeHandle ?? readHandle
        self.closesHandles = closesHandles
        stateQueue.setSpecific(key: stateQueueKey, value: ())
    }

    func start() {
        withStateSync {
            guard !running, !closed else { return }
            generation &+= 1
            let generation = generation
            running = true
            installReadHandlerLocked(generation: generation)
        }
    }

    private func installReadHandlerLocked(generation: UInt64) {
        readHandlerEpoch &+= 1
        let epoch = readHandlerEpoch
        readHandle.readabilityHandler = { [weak self] handle in
            self?.stateQueue.async {
                guard let self else { return }
                guard self.running, self.generation == generation,
                      self.readHandlerEpoch == epoch else {
                    self.staleReadCallbacks &+= 1
                    return
                }
                // FileHandle may invoke this handler again before its queued read
                // runs. Retire the epoch before reading so those callbacks cannot
                // make a second, blocking read after the first drains the pipe.
                self.readHandlerEpoch &+= 1
                self.readHandle.readabilityHandler = nil
                let data = handle.availableData
                if data.isEmpty {
                    self.finishLocked(nil)
                } else {
                    self.bytesRead &+= UInt64(data.count)
                    self.storedOnBytes?(data)
                    if self.running, self.generation == generation {
                        self.installReadHandlerLocked(generation: generation)
                    }
                }
            }
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        stateQueue.async { [weak self] in
            guard let self else { return }
            guard self.running else {
                self.droppedWriteRequests &+= 1
                return
            }
            let generation = self.generation
            self.writeQueue.async { [weak self] in
                guard let self else { return }
                assert(!self.writeHandleClosed, "SC2 write attempted after descriptor close")
                guard !self.writeHandleClosed else { return }
                do { try self.writeHandle.write(contentsOf: data) }
                catch {
                    self.stateQueue.async {
                        guard self.running, self.generation == generation else { return }
                        self.writeErrors &+= 1
                        self.finishLocked(error)
                    }
                }
            }
        }
    }

    func stop() {
        withStateSync { finishLocked(nil, notify: false) }
    }

    private func withStateSync<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: stateQueueKey) != nil { return operation() }
        return stateQueue.sync(execute: operation)
    }

    private func finishLocked(_ error: Error?, notify: Bool = true) {
        let wasRunning = running
        guard wasRunning || (closesHandles && !closed) else { return }
        running = false
        generation &+= 1
        readHandlerEpoch &+= 1
        readHandle.readabilityHandler = nil
        if closesHandles, !closed {
            closed = true
            let readHandle = readHandle
            let writeHandle = writeHandle
            writeQueue.async {
                try? readHandle.close()
                if writeHandle !== readHandle { try? writeHandle.close() }
                self.writeHandleClosed = true
            }
        }
        if notify, wasRunning { storedOnClosed?(error) }
    }

    static func readLifecycleSelfTest() -> Bool {
        let pipe = Pipe()
        let link = SC2MuxFileHandleLink(readHandle: pipe.fileHandleForReading,
                                         writeHandle: pipe.fileHandleForWriting)
        let lock = NSLock()
        let received = DispatchSemaphore(value: 0)
        var bytes = Data()
        link.onBytes = { chunk in
            lock.lock()
            bytes.append(chunk)
            let complete = bytes.count >= 128
            lock.unlock()
            if complete { received.signal() }
        }
        link.start()
        do {
            for value in UInt8(0)..<UInt8(16) {
                try pipe.fileHandleForWriting.write(contentsOf: Data(repeating: value, count: 8))
            }
        } catch {
            link.stop()
            try? pipe.fileHandleForReading.close()
            try? pipe.fileHandleForWriting.close()
            return false
        }
        let delivered = received.wait(timeout: .now() + 2) == .success
        _ = link.diagnosticSummary // Wait until the accepted read has re-armed its handler.
        let staleHandler = pipe.fileHandleForReading.readabilityHandler
        link.stop()
        staleHandler?(pipe.fileHandleForReading)
        link.write(Data([42]))
        let diagnostics = link.diagnosticSummary
        try? pipe.fileHandleForReading.close()
        try? pipe.fileHandleForWriting.close()
        lock.lock()
        let result = delivered && bytes.count == 128 &&
            bytes == Data((UInt8(0)..<UInt8(16)).flatMap { repeatElement($0, count: 8) }) &&
            !diagnostics.contains("stale-read=0") && diagnostics.contains("dropped-write=1")
        lock.unlock()
        return result
    }
}

enum SC2ProductionTransportState: Equatable {
    case idle
    case opening
    case discovering
    case connecting(SC2MuxDevice)
    case connected(SC2MuxDevice)
    case failed(String)
}

/// Owns one mobile-link session and connects channel 1 to the app's existing
/// ARNetwork reliability/telemetry engine. Channels 4/5/6 remain available to
/// the video pipeline without affecting Direct mode.
final class SC2ProductionTransport {
    var onState: ((SC2ProductionTransportState) -> Void)?
    var onStreamData: ((Data) -> Void)?
    var onStreamControl: ((Data) -> Void)?
    var onRTP: ((UInt16, Data, Bool) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "parrotlab.sc2-production-transport", qos: .userInitiated)
    private let arsdkClient: ARSDKCommandClient
    private var link: SC2MuxByteLink?
    private var session: SC2MuxSession?
    private var generation: UInt64 = 0
    private var publishedState = SC2ProductionTransportState.idle
    private var staleTransportCallbacks: UInt64 = 0
    private var staleMainCallbacks: UInt64 = 0
    private var lastLinkDiagnostics = "link none"
    private let callbackGenerationLock = NSLock()
    private var callbackGeneration: UInt64 = 0

    var diagnosticSummary: String {
        queue.sync {
            let state: String
            switch publishedState {
            case .idle: state = "idle"
            case .opening: state = "opening"
            case .discovering: state = "discovering"
            case .connecting: state = "connecting"
            case .connected: state = "connected"
            case .failed: state = "failed"
            }
            let linkSummary = (link as? SC2MuxFileHandleLink)?.diagnosticSummary ?? lastLinkDiagnostics
            callbackGenerationLock.lock()
            let staleMain = staleMainCallbacks
            callbackGenerationLock.unlock()
            let selected = session?.selectedDevice.map { "\($0.identifier)" } ?? "none"
            return "SC2 gen=\(generation) state=\(state) selected=\(selected) " +
                "stale-transport=\(staleTransportCallbacks) stale-main=\(staleMain) \(linkSummary)"
        }
    }

    init(arsdkClient: ARSDKCommandClient) {
        self.arsdkClient = arsdkClient
    }

    func start(link: SC2MuxByteLink, preferredProduct: ParrotProductModel? = nil) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked(notify: false)
            self.generation &+= 1
            self.updateCallbackGenerationLocked()
            let generation = self.generation
            let session = SC2MuxSession(preferredProduct: preferredProduct)
            self.link = link
            self.session = session
            link.onBytes = { [weak self] bytes in
                self?.queue.async { self?.receiveLocked(bytes, generation: generation) }
            }
            link.onClosed = { [weak self] error in
                self?.queue.async {
                    guard let self else { return }
                    guard self.generation == generation else {
                        self.staleTransportCallbacks &+= 1
                        return
                    }
                    self.stopLocked(notify: false)
                    self.publish(.failed(error?.localizedDescription ?? "SC2 mobile link closed"))
                }
            }
            self.publish(.opening)
            link.start()
            self.write(session.start())
            self.publish(.discovering)
            self.log("SC2 libmux handshake started · channels 1–6 opened")
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked(notify: true) }
    }

    func sendStreamControl(_ packet: Data) {
        queue.async { [weak self] in
            guard let self, let session = self.session else { return }
            self.write([session.sendStreamControl(packet)])
        }
    }

    private func receiveLocked(_ bytes: Data, generation: UInt64) {
        guard self.generation == generation, let session else {
            staleTransportCallbacks &+= 1
            return
        }
        handle(session.receive(bytes), generation: generation)
    }

    private func handle(_ events: [SC2MuxSessionEvent], generation: UInt64) {
        for event in events {
            switch event {
            case .write(let bytes):
                link?.write(bytes)
            case .deviceAdded(let device):
                log("SC2 mobile link found \(device.product.displayName) · \(device.name)")
                if session?.selectedDevice == device { publish(.connecting(device)) }
            case .deviceRemoved(let identifier):
                guard session?.selectedDevice == nil else {
                    log("SC2 mobile-link product removed · \(identifier)")
                    continue
                }
                arsdkClient.stop()
                publish(.discovering)
                log("SC2 mobile-link product removed · \(identifier)")
            case .connected(let device, let json):
                arsdkClient.connectMux(product: device.product, send: { [weak self] packet in
                    self?.queue.async {
                        guard let self, self.generation == generation,
                              let session = self.session else { return }
                        self.write([session.sendTransport(packet)])
                    }
                }) { [weak self] result in
                    self?.queue.async {
                        guard let self, self.generation == generation,
                              self.session?.selectedDevice == device else { return }
                        switch result {
                        case .success:
                            self.publish(.connected(device))
                            self.log("SC2 libmux ARSDK connected · \(json)")
                        case .failure(let error):
                            self.stopLocked(notify: false)
                            self.publish(.failed(error.localizedDescription))
                        }
                    }
                }
            case .connectionRejected(let status, let json):
                stopLocked(notify: false)
                publish(.failed("SC2 rejected ARSDK connection (status \(status))"))
                log("SC2 libmux connection rejected · \(json)")
                return
            case .transport(let packet):
                arsdkClient.receiveMuxTransport(packet)
            case .streamData(let packet):
                dispatchMain(generation: generation) { transport in
                    transport.onStreamData?(packet)
                }
            case .streamControl(let packet):
                dispatchMain(generation: generation) { transport in
                    transport.onStreamControl?(packet)
                }
            case .rtp(let port, let packet, let isControl):
                dispatchMain(generation: generation) { transport in
                    transport.onRTP?(port, packet, isControl)
                }
            case .channelReset(let channel):
                log("SC2 libmux channel \(channel) reset")
                if channel == SC2MuxChannel.transport.rawValue {
                    arsdkClient.stop()
                    publish(.discovering)
                }
            }
        }
    }

    private func write(_ events: [SC2MuxSessionEvent]) {
        for case .write(let data) in events { link?.write(data) }
    }

    private func stopLocked(notify: Bool) {
        generation &+= 1
        updateCallbackGenerationLocked()
        if let link = link as? SC2MuxFileHandleLink {
            lastLinkDiagnostics = link.diagnosticSummary
        }
        if let session { write(session.disconnect()) }
        link?.onBytes = nil
        link?.onClosed = nil
        link?.stop()
        link = nil
        session = nil
        arsdkClient.stop()
        if notify { publish(.idle) }
    }

    private func publish(_ state: SC2ProductionTransportState) {
        publishedState = state
        dispatchMain(generation: generation) { transport in
            transport.onState?(state)
        }
    }

    private func log(_ message: String) {
        dispatchMain(generation: generation) { transport in
            transport.onLog?(message)
        }
    }

    private func updateCallbackGenerationLocked() {
        callbackGenerationLock.lock()
        callbackGeneration = generation
        callbackGenerationLock.unlock()
    }

    private func dispatchMain(
        generation: UInt64,
        _ operation: @escaping (SC2ProductionTransport) -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.callbackGenerationLock.lock()
            let isCurrent = self.callbackGeneration == generation
            if !isCurrent { self.staleMainCallbacks &+= 1 }
            self.callbackGenerationLock.unlock()
            guard isCurrent else { return }
            operation(self)
        }
    }
}

private final class SC2TestByteLink: SC2MuxByteLink {
    var onBytes: ((Data) -> Void)?
    var onClosed: ((Error?) -> Void)?
    func start() {}
    func write(_ data: Data) {}
    func stop() {}
}

enum SC2TransportLifecycleSelfTest {
    static func run() -> Bool {
        let transport = SC2ProductionTransport(arsdkClient: ARSDKCommandClient())
        var states: [SC2ProductionTransportState] = []
        transport.onState = { states.append($0) }
        let first = SC2TestByteLink()
        transport.start(link: first)
        guard wait({ states.last == .discovering }) else { return false }
        let staleBytes = first.onBytes
        let staleClose = first.onClosed
        first.onClosed?(nil)
        guard wait({ if case .failed? = states.last { return true }; return false }) else { return false }
        let second = SC2TestByteLink()
        transport.start(link: second)
        guard wait({ states.filter { $0 == .discovering }.count == 2 }) else { return false }
        staleBytes?(Data([0, 1, 2]))
        staleClose?(nil)
        guard wait({ transport.diagnosticSummary.contains("stale-transport=2") }) else { return false }
        guard states.last == .discovering,
              transport.diagnosticSummary.contains("state=discovering") else { return false }
        transport.stop()
        return wait({ states.last == .idle })
    }

    private static func wait(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while !predicate(), Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }
}
