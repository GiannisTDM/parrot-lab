import Foundation
import Network
import Darwin

enum ARSDKPictureFormat: UInt32, Equatable {
    case raw = 0
    case jpeg = 1
    case snapshot = 2
    case jpegFisheye = 3
}

enum ARSDKPictureState: UInt32, Equatable {
    case ready = 0
    case busy = 1
    case notAvailable = 2
}

enum ARSDKPictureStateError: UInt32, Equatable {
    case ok = 0
    case unknown = 1
    case cameraKO = 2
    case memoryFull = 3
    case lowBattery = 4
}

enum ARSDKPictureEventKind: UInt32, Equatable {
    case taken = 0
    case failed = 1
}

enum ARSDKPictureEventError: UInt32, Equatable {
    case ok = 0
    case unknown = 1
    case busy = 2
    case notAvailable = 3
    case errorAssert = 4
}

enum ARSDKPhotoEvent: Equatable {
    case formatChanged(ARSDKPictureFormat)
    case pictureState(ARSDKPictureState, ARSDKPictureStateError)
    case pictureEvent(ARSDKPictureEventKind, ARSDKPictureEventError)
}

enum ARSDKTelemetryEvent: Equatable {
    case droneBattery(Int)
    case controllerBattery(Int)
    case controllerBatteryState(UInt32)
    case flyingState(UInt32)
    case gpsPosition(latitude: Double, longitude: Double)
    case homePosition(latitude: Double, longitude: Double)
    case altitude(Double)
    case speed(north: Float, east: Float, down: Float)
    case attitude(roll: Float, pitch: Float, yaw: Float)
    case gpsFix(Bool)
    case satelliteCount(Int)
}

enum ARSDKPhotoCommand {
    // ARCommands payloads are project, class, command (little-endian), args.
    static let setFisheye = Data([1, 19, 0, 0, 3, 0, 0, 0])
    static let takePictureV2 = Data([1, 7, 2, 0])
    static let requestAllStates = Data([0, 4, 0, 0])
    static let requestSkyControllerAllStates = Data([4, 6, 0, 0])
}

enum ARSDKPhotoProtocol {
    static func decode(_ data: Data) -> ARSDKPhotoEvent? {
        guard data.count >= 4 else { return nil }
        let project = data[0]
        let commandClass = data[1]
        let command = UInt16(data[2]) | UInt16(data[3]) << 8

        if project == 1, commandClass == 20, command == 0,
           let raw = uint32(data, at: 4), let format = ARSDKPictureFormat(rawValue: raw) {
            return .formatChanged(format)
        }
        if project == 1, commandClass == 8, command == 2,
           let rawState = uint32(data, at: 4), let rawError = uint32(data, at: 8),
           let state = ARSDKPictureState(rawValue: rawState),
           let error = ARSDKPictureStateError(rawValue: rawError) {
            return .pictureState(state, error)
        }
        if project == 1, commandClass == 3, command == 0,
           let rawEvent = uint32(data, at: 4), let rawError = uint32(data, at: 8),
           let event = ARSDKPictureEventKind(rawValue: rawEvent),
           let error = ARSDKPictureEventError(rawValue: rawError) {
            return .pictureEvent(event, error)
        }
        return nil
    }

    static func frame(type: UInt8, id: UInt8, sequence: UInt8, payload: Data) -> Data {
        let size = UInt32(7 + payload.count)
        var result = Data([type, id, sequence])
        result.append(contentsOf: [
            UInt8(size & 0xff), UInt8((size >> 8) & 0xff),
            UInt8((size >> 16) & 0xff), UInt8((size >> 24) & 0xff)
        ])
        result.append(payload)
        return result
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }
}

enum ARSDKTelemetryProtocol {
    static func decode(_ data: Data) -> ARSDKTelemetryEvent? {
        guard data.count >= 4 else { return nil }
        let project = data[0]
        let commandClass = data[1]
        let command = UInt16(data[2]) | UInt16(data[3]) << 8

        if project == 0, commandClass == 5, command == 1, data.count >= 5 {
            return .droneBattery(Int(data[4]))
        }
        if project == 4, commandClass == 8, command == 0, data.count >= 5 {
            return .controllerBattery(Int(data[4]))
        }
        if project == 4, commandClass == 8, command == 3, let state = uint32(data, at: 4) {
            return .controllerBatteryState(state)
        }
        if project == 1, commandClass == 4, command == 1, let state = uint32(data, at: 4) {
            return .flyingState(state)
        }
        if project == 1, commandClass == 4, command == 4,
           let latitude = double(data, at: 4), let longitude = double(data, at: 12) {
            return .gpsPosition(latitude: latitude, longitude: longitude)
        }
        if project == 1, commandClass == 4, command == 8, let altitude = double(data, at: 4) {
            return .altitude(altitude)
        }
        if project == 1, commandClass == 4, command == 9,
           let latitude = double(data, at: 4), let longitude = double(data, at: 12) {
            return .gpsPosition(latitude: latitude, longitude: longitude)
        }
        if project == 1, commandClass == 4, command == 5,
           let north = float(data, at: 4), let east = float(data, at: 8), let down = float(data, at: 12) {
            return .speed(north: north, east: east, down: down)
        }
        if project == 1, commandClass == 4, command == 6,
           let roll = float(data, at: 4), let pitch = float(data, at: 8), let yaw = float(data, at: 12) {
            return .attitude(roll: roll, pitch: pitch, yaw: yaw)
        }
        if project == 1, commandClass == 24, command == 2, data.count >= 5 {
            return .gpsFix(data[4] != 0)
        }
        if project == 1, commandClass == 24, command == 0,
           let latitude = double(data, at: 4), let longitude = double(data, at: 12) {
            return .homePosition(latitude: latitude, longitude: longitude)
        }
        if project == 1, commandClass == 31, command == 0, data.count >= 5 {
            return .satelliteCount(Int(data[4]))
        }
        return nil
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }

    private static func float(_ data: Data, at offset: Int) -> Float? {
        uint32(data, at: offset).map(Float.init(bitPattern:))
    }

    private static func double(_ data: Data, at offset: Int) -> Double? {
        guard data.count >= offset + 8 else { return nil }
        var bits: UInt64 = 0
        for index in 0..<8 {
            bits |= UInt64(data[offset + index]) << UInt64(index * 8)
        }
        return Double(bitPattern: bits)
    }
}

enum ARSDKPhotoConnectionError: LocalizedError {
    case invalidHost
    case socket(String)
    case discovery(String)
    case discoveryTimeout
    case connectionRejected(Int)
    case missingCommandPort

    var errorDescription: String? {
        switch self {
        case .invalidHost: return "The SC2 host is not a valid IPv4 address."
        case .socket(let detail): return "Could not open the ARSDK command socket: \(detail)"
        case .discovery(let detail): return "SC2 ARDiscovery failed: \(detail)"
        case .discoveryTimeout: return "SC2 ARDiscovery timed out."
        case .connectionRejected(let status): return "The SC2 rejected the ARSDK connection (status \(status))."
        case .missingCommandPort: return "The SC2 discovery reply did not contain a command port."
        }
    }
}

/// Persistent ARDiscovery/ARNetwork/ARCommands client for structured telemetry
/// and stock camera commands routed by the SkyController to its connected Bebop.
final class ARSDKCommandClient {
    var onEvent: ((ARSDKPhotoEvent) -> Void)?
    var onTelemetryEvent: ((ARSDKTelemetryEvent) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "parrotlab.arsdk.command", qos: .userInitiated)
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var discoveryConnection: NWConnection?
    private var discoveryTimeout: DispatchWorkItem?
    private var remoteAddress: sockaddr_in?
    private var sequenceByBuffer: [UInt8: UInt8] = [:]
    private struct PendingAcknowledgement {
        let packet: Data
        var retries: Int
    }
    private var pendingAcknowledgements: [UInt8: PendingAcknowledgement] = [:]
    private var connectionCompletions: [(Result<Void, Error>) -> Void] = []
    private var connectingHost: String?
    private var connectedHost: String?

    func connect(host: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.remoteAddress != nil, self.connectedHost == host {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            if self.connectingHost == host, self.discoveryConnection != nil {
                self.connectionCompletions.append(completion)
                return
            }
            self.stopLocked()
            self.connectionCompletions = [completion]
            self.connectingHost = host
            do {
                let localPort = try self.openUDPSocket()
                try self.startDiscovery(host: host, localPort: localPort)
            } catch {
                self.finishConnection(.failure(error))
            }
        }
    }

    func sendSetFisheye() { sendCommand(ARSDKPhotoCommand.setFisheye) }
    func sendTakePictureV2() { sendCommand(ARSDKPhotoCommand.takePictureV2) }
    func sendRequestAllStates() { sendCommand(ARSDKPhotoCommand.requestAllStates) }
    func sendRequestSkyControllerAllStates() {
        sendCommand(ARSDKPhotoCommand.requestSkyControllerAllStates)
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    private func openUDPSocket() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ARSDKPhotoConnectionError.socket(String(cString: strerror(errno))) }
        socketFD = fd

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw ARSDKPhotoConnectionError.socket(String(cString: strerror(errno)))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw ARSDKPhotoConnectionError.socket(String(cString: strerror(errno)))
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receiveDatagrams() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()
        return UInt16(bigEndian: bound.sin_port)
    }

    private func startDiscovery(host: String, localPort: UInt16) throws {
        var ipv4 = in_addr()
        guard inet_pton(AF_INET, host, &ipv4) == 1 else {
            throw ARSDKPhotoConnectionError.invalidHost
        }

        let connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: 44_444)!,
            using: .tcp
        )
        discoveryConnection = connection
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                let body: [String: Any] = [
                    "controller_name": "Parrot Lab",
                    "controller_type": "computer",
                    "d2c_port": Int(localPort),
                    "qos_mode": 0
                ]
                do {
                    let data = try JSONSerialization.data(withJSONObject: body)
                    connection.send(content: data, completion: .contentProcessed { [weak self] error in
                        if let error { self?.failDiscovery(error.localizedDescription) }
                    })
                    self.receiveDiscoveryResponse(connection, accumulated: Data(), host: host, ipv4: ipv4)
                } catch {
                    self.failDiscovery(error.localizedDescription)
                }
            case .failed(let error): self.failDiscovery(error.localizedDescription)
            case .cancelled: break
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            self?.finishConnection(.failure(ARSDKPhotoConnectionError.discoveryTimeout))
        }
        discoveryTimeout = timeout
        queue.asyncAfter(deadline: .now() + 8, execute: timeout)
        connection.start(queue: queue)
    }

    private func receiveDiscoveryResponse(
        _ connection: NWConnection,
        accumulated: Data,
        host: String,
        ipv4: in_addr
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_535) { [weak self] data, _, complete, error in
            guard let self else { return }
            var combined = accumulated
            if let data { combined.append(data) }
            if let object = try? JSONSerialization.jsonObject(with: combined) as? [String: Any] {
                let status = object["status"] as? Int ?? 0
                guard status == 0 else {
                    self.finishConnection(.failure(ARSDKPhotoConnectionError.connectionRejected(status)))
                    return
                }
                guard let portValue = object["c2d_port"] as? Int,
                      let port = UInt16(exactly: portValue) else {
                    self.finishConnection(.failure(ARSDKPhotoConnectionError.missingCommandPort))
                    return
                }
                var remote = sockaddr_in()
                remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                remote.sin_family = sa_family_t(AF_INET)
                remote.sin_port = port.bigEndian
                remote.sin_addr = ipv4
                self.remoteAddress = remote
                self.connectedHost = host
                self.log("ARSDK connected through SC2 \(host) · command UDP \(port)")
                self.finishConnection(.success(()))
                return
            }
            if let error {
                self.failDiscovery(error.localizedDescription)
            } else if complete {
                self.failDiscovery("invalid JSON reply")
            } else {
                self.receiveDiscoveryResponse(connection, accumulated: combined, host: host, ipv4: ipv4)
            }
        }
    }

    private func failDiscovery(_ detail: String) {
        finishConnection(.failure(ARSDKPhotoConnectionError.discovery(detail)))
    }

    private func finishConnection(_ result: Result<Void, Error>) {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        discoveryConnection?.cancel()
        discoveryConnection = nil
        let callbacks = connectionCompletions
        connectionCompletions.removeAll()
        connectingHost = nil
        DispatchQueue.main.async { callbacks.forEach { $0(result) } }
    }

    private func sendCommand(_ payload: Data) {
        queue.async { [weak self] in self?.sendFrame(type: 4, id: 11, payload: payload) }
    }

    private func sendFrame(type: UInt8, id: UInt8, payload: Data) {
        guard socketFD >= 0, var remoteAddress else { return }
        let sequence = nextSequence(for: id)
        let packet = ARSDKPhotoProtocol.frame(type: type, id: id, sequence: sequence, payload: payload)
        sendPacket(packet, to: &remoteAddress)
        if type == 4, id == 11 {
            pendingAcknowledgements[sequence] = PendingAcknowledgement(packet: packet, retries: 0)
            scheduleRetry(sequence: sequence)
        }
    }

    private func sendPacket(_ packet: Data, to remoteAddress: inout sockaddr_in) {
        packet.withUnsafeBytes { bytes in
            _ = withUnsafePointer(to: &remoteAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(socketFD, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func scheduleRetry(sequence: UInt8) {
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self, var pending = self.pendingAcknowledgements[sequence],
                  var remote = self.remoteAddress else { return }
            guard pending.retries < 5 else {
                self.pendingAcknowledgements.removeValue(forKey: sequence)
                self.log("ARSDK command acknowledgement timed out")
                return
            }
            pending.retries += 1
            self.pendingAcknowledgements[sequence] = pending
            self.sendPacket(pending.packet, to: &remote)
            self.scheduleRetry(sequence: sequence)
        }
    }

    private func nextSequence(for id: UInt8) -> UInt8 {
        let next = (sequenceByBuffer[id] ?? 255) &+ 1
        sequenceByBuffer[id] = next
        return next
    }

    private func receiveDatagrams() {
        var storage = [UInt8](repeating: 0, count: 65_535)
        while true {
            let count = storage.withUnsafeMutableBytes { bytes in
                recv(socketFD, bytes.baseAddress, bytes.count, 0)
            }
            if count <= 0 { break }
            parseFrames(Data(storage.prefix(count)))
        }
    }

    private func parseFrames(_ datagram: Data) {
        var offset = 0
        while offset + 7 <= datagram.count {
            let type = datagram[offset]
            let id = datagram[offset + 1]
            let sequence = datagram[offset + 2]
            let size = Int(UInt32(datagram[offset + 3]) |
                UInt32(datagram[offset + 4]) << 8 |
                UInt32(datagram[offset + 5]) << 16 |
                UInt32(datagram[offset + 6]) << 24)
            guard size >= 7, offset + size <= datagram.count else { return }
            let payload = datagram.subdata(in: (offset + 7)..<(offset + size))
            if type == 1, id == 139, let acknowledgedSequence = payload.first {
                pendingAcknowledgements.removeValue(forKey: acknowledgedSequence)
            }
            if type == 4 {
                sendFrame(type: 1, id: id &+ 128, payload: Data([sequence]))
            }
            if type == 2, id == 0 {
                sendFrame(type: 2, id: 1, payload: payload)
            } else if (id == 126 || id == 127), let event = ARSDKPhotoProtocol.decode(payload) {
                DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
            }
            if id == 126 || id == 127, let telemetry = ARSDKTelemetryProtocol.decode(payload) {
                DispatchQueue.main.async { [weak self] in self?.onTelemetryEvent?(telemetry) }
            }
            offset += size
        }
    }

    private func stopLocked() {
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        discoveryConnection?.cancel()
        discoveryConnection = nil
        connectionCompletions.removeAll()
        connectingHost = nil
        remoteAddress = nil
        connectedHost = nil
        sequenceByBuffer.removeAll()
        pendingAcknowledgements.removeAll()
        if let source = readSource {
            source.cancel()
            readSource = nil
        } else if socketFD >= 0 {
            Darwin.close(socketFD)
        }
        socketFD = -1
    }

    private func log(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onLog?(message) }
    }
}

enum DroneFisheyeFailure: LocalizedError, Equatable {
    case busy
    case notAvailable
    case memoryFull
    case lowBattery
    case cameraKO
    case camera(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .busy: return "The drone camera is busy."
        case .notAvailable: return "Drone photo capture is not available."
        case .memoryFull: return "The drone media storage is full."
        case .lowBattery: return "The drone battery is too low for a photo."
        case .cameraKO: return "The drone reported a camera fault (camera_ko)."
        case .camera(let detail): return "Drone photo capture failed: \(detail)"
        case .timeout: return "The 4K fisheye capture timed out."
        }
    }
}

enum DroneFisheyeAction: Equatable {
    case sendFormat
    case requestAllStates
    case takePicture
    case complete
    case fail(DroneFisheyeFailure)
}

struct DroneFisheyeStateMachine {
    private(set) var formatConfirmed = false
    private(set) var currentState: ARSDKPictureState?
    private(set) var pictureCommandSent = false
    private(set) var sawBusy = false
    private(set) var pictureTaken = false
    private(set) var readyAfterPicture = false

    mutating func start() -> [DroneFisheyeAction] {
        [.sendFormat, .requestAllStates]
    }

    mutating func consume(_ event: ARSDKPhotoEvent) -> [DroneFisheyeAction] {
        switch event {
        case .formatChanged(let format):
            guard format == .jpegFisheye else { return [] }
            formatConfirmed = true
            return takeIfReady()

        case .pictureState(let state, let error):
            if let failure = Self.failure(for: error) { return [.fail(failure)] }
            currentState = state
            if pictureCommandSent {
                if state == .busy { sawBusy = true }
                if state == .ready, sawBusy { readyAfterPicture = true }
                return completionIfReady()
            }
            switch state {
            case .ready: return takeIfReady()
            case .busy: return [.fail(.busy)]
            case .notAvailable: return [.fail(.notAvailable)]
            }

        case .pictureEvent(let event, let error):
            if event == .taken, error == .ok {
                pictureTaken = true
                return completionIfReady()
            }
            return [.fail(Self.failure(for: error) ?? .camera("unknown camera error"))]
        }
    }

    private mutating func takeIfReady() -> [DroneFisheyeAction] {
        guard formatConfirmed, currentState == .ready, !pictureCommandSent else { return [] }
        pictureCommandSent = true
        readyAfterPicture = false
        return [.takePicture]
    }

    private func completionIfReady() -> [DroneFisheyeAction] {
        pictureTaken && sawBusy && readyAfterPicture ? [.complete] : []
    }

    mutating func timedOut() -> [DroneFisheyeAction] { [.fail(.timeout)] }

    private static func failure(for error: ARSDKPictureStateError) -> DroneFisheyeFailure? {
        switch error {
        case .ok: return nil
        case .cameraKO: return .cameraKO
        case .memoryFull: return .memoryFull
        case .lowBattery: return .lowBattery
        case .unknown: return .camera("unknown camera state")
        }
    }

    private static func failure(for error: ARSDKPictureEventError) -> DroneFisheyeFailure? {
        switch error {
        case .ok: return nil
        case .busy: return .busy
        case .notAvailable: return .notAvailable
        case .unknown: return .camera("unknown camera event")
        case .errorAssert: return .camera("camera assertion")
        }
    }
}

final class DroneFisheyeCaptureController {
    var onStatus: ((String) -> Void)?
    var onLog: ((String) -> Void)?
    var onCompletion: ((Result<Void, Error>) -> Void)?

    private let client: ARSDKCommandClient
    private var machine = DroneFisheyeStateMachine()
    private var timeout: Timer?
    private var active = false
    private var finished = false

    init(client: ARSDKCommandClient) {
        self.client = client
        client.onLog = { [weak self] message in self?.onLog?(message) }
        client.onEvent = { [weak self] event in self?.consume(event) }
    }

    func start(host: String) {
        cancel()
        active = true
        finished = false
        machine = DroneFisheyeStateMachine()
        onStatus?("CONNECTING TO DRONE CAMERA")
        client.connect(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.finish(.failure(error))
            case .success:
                self.onStatus?("SETTING 4K FISHEYE")
                self.perform(self.machine.start())
                self.timeout = Timer.scheduledTimer(withTimeInterval: 35, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.perform(self.machine.timedOut())
                }
            }
        }
    }

    func cancel() {
        active = false
        timeout?.invalidate()
        timeout = nil
    }

    private func consume(_ event: ARSDKPhotoEvent) {
        guard active else { return }
        switch event {
        case .formatChanged(.jpegFisheye): onStatus?("4K FISHEYE READY")
        case .pictureState(.busy, _): onStatus?("CAPTURING 4K FISHEYE")
        case .pictureState(.ready, _) where machine.pictureCommandSent:
            onStatus?("FINALIZING 4K FISHEYE")
        default: break
        }
        perform(machine.consume(event))
    }

    private func perform(_ actions: [DroneFisheyeAction]) {
        for action in actions {
            switch action {
            case .sendFormat: client.sendSetFisheye()
            case .requestAllStates: client.sendRequestAllStates()
            case .takePicture:
                onStatus?("CAPTURING 4K FISHEYE")
                client.sendTakePictureV2()
            case .complete: finish(.success(()))
            case .fail(let error): finish(.failure(error))
            }
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        guard active, !finished else { return }
        active = false
        finished = true
        timeout?.invalidate()
        timeout = nil
        onCompletion?(result)
    }
}

enum ARSDKPhotoCaptureSelfTest {
    static func run() -> Bool {
        guard ARSDKPhotoCommand.setFisheye == Data([1, 19, 0, 0, 3, 0, 0, 0]),
              ARSDKPhotoCommand.takePictureV2 == Data([1, 7, 2, 0]),
              ARSDKPhotoCommand.requestSkyControllerAllStates == Data([4, 6, 0, 0]) else { return false }

        let formatEvent = Data([1, 20, 0, 0, 3, 0, 0, 0])
        let readyEvent = Data([1, 8, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        let busyEvent = Data([1, 8, 2, 0, 1, 0, 0, 0, 0, 0, 0, 0])
        let takenEvent = Data([1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        guard ARSDKPhotoProtocol.decode(formatEvent) == .formatChanged(.jpegFisheye),
              ARSDKPhotoProtocol.decode(readyEvent) == .pictureState(.ready, .ok),
              ARSDKPhotoProtocol.decode(takenEvent) == .pictureEvent(.taken, .ok) else { return false }

        var machine = DroneFisheyeStateMachine()
        guard machine.start() == [.sendFormat, .requestAllStates],
              machine.consume(ARSDKPhotoProtocol.decode(readyEvent)!) == [],
              machine.consume(ARSDKPhotoProtocol.decode(formatEvent)!) == [.takePicture],
              machine.consume(ARSDKPhotoProtocol.decode(busyEvent)!) == [],
              machine.consume(ARSDKPhotoProtocol.decode(takenEvent)!) == [],
              machine.consume(ARSDKPhotoProtocol.decode(readyEvent)!) == [.complete] else { return false }

        var errors = DroneFisheyeStateMachine()
        _ = errors.start()
        guard errors.consume(.pictureState(.ready, .memoryFull)) == [.fail(.memoryFull)],
              errors.consume(.pictureState(.ready, .lowBattery)) == [.fail(.lowBattery)],
              errors.consume(.pictureState(.ready, .cameraKO)) == [.fail(.cameraKO)],
              errors.consume(.pictureState(.notAvailable, .ok)) == [.fail(.notAvailable)],
              errors.consume(.pictureState(.busy, .ok)) == [.fail(.busy)],
              errors.timedOut() == [.fail(.timeout)] else { return false }

        let frame = ARSDKPhotoProtocol.frame(type: 4, id: 11, sequence: 7, payload: ARSDKPhotoCommand.takePictureV2)
        guard frame == Data([4, 11, 7, 11, 0, 0, 0, 1, 7, 2, 0]),
              ARSDKTelemetryProtocol.decode(Data([0, 5, 1, 0, 74])) == .droneBattery(74),
              ARSDKTelemetryProtocol.decode(Data([4, 8, 0, 0, 83])) == .controllerBattery(83),
              ARSDKTelemetryProtocol.decode(Data([1, 4, 1, 0, 0, 0, 0, 0])) == .flyingState(0),
              ARSDKTelemetryProtocol.decode(Data([1, 24, 2, 0, 1])) == .gpsFix(true),
              ARSDKTelemetryProtocol.decode(Data([1, 31, 0, 0, 12])) == .satelliteCount(12) else {
            return false
        }

        var speed = Data([1, 4, 5, 0])
        appendLittleEndian(Float(3), to: &speed)
        appendLittleEndian(Float(4), to: &speed)
        appendLittleEndian(Float(0), to: &speed)
        guard ARSDKTelemetryProtocol.decode(speed) == .speed(north: 3, east: 4, down: 0) else {
            return false
        }

        var position = Data([1, 4, 9, 0])
        appendLittleEndian(Double(38.1), to: &position)
        appendLittleEndian(Double(21.7), to: &position)
        appendLittleEndian(Double(100), to: &position)
        position.append(contentsOf: [1, 1, 2])
        return ARSDKTelemetryProtocol.decode(position) == .gpsPosition(latitude: 38.1, longitude: 21.7)
    }

    private static func appendLittleEndian(_ value: Float, to data: inout Data) {
        let bits = value.bitPattern
        data.append(contentsOf: (0..<4).map { UInt8((bits >> UInt32($0 * 8)) & 0xff) })
    }

    private static func appendLittleEndian(_ value: Double, to data: inout Data) {
        let bits = value.bitPattern
        data.append(contentsOf: (0..<8).map { UInt8((bits >> UInt64($0 * 8)) & 0xff) })
    }
}
