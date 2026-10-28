import Foundation

/// The optional v2 observer mirrors the controller's existing ARNetwork
/// session. It never opens another Sumo session or carries piloting commands.
enum SC3SumoNativeObserver {
    static let port: UInt16 = 44_447
    static let headerSize = 32
    static let maximumDatagram = 65_507
    static let maximumPayload = maximumDatagram - headerSize

    enum Kind: UInt8 { case hello = 1, info = 2, raw = 3, acknowledgement = 4, bye = 5 }
    struct Packet: Equatable {
        let kind: Kind
        let instance: UInt64
        let generation: UInt32
        let nonce: UInt64
        let payload: Data
        var encoded: Data {
            var data = Data([0x50, 0x53, 0x4e, 0x32, 1, kind.rawValue, 0, 0])
            data.appendAnafiLE(UInt32(payload.count)); data.appendAnafiLE(instance)
            data.appendAnafiLE(generation); data.appendAnafiLE(nonce); data.append(payload)
            return data
        }
    }
    struct Info: Equatable {
        let flags: UInt32
        let model: UInt32
        let negotiation: ARStream1Negotiation
        var linkedSumo: Bool { flags & 3 == 3 && model == 0x0902 }
        var ready: Bool { linkedSumo && flags & 12 == 12 }
    }
    static func decode(_ data: Data) -> Packet? {
        guard data.count >= headerSize, data.count <= maximumDatagram else { return nil }
        var reader = AnafiWireReader(data)
        guard reader.integer(UInt32.self) == 0x324e5350, reader.byte() == 1,
              let rawKind = reader.byte(), let kind = Kind(rawValue: rawKind),
              reader.integer(UInt16.self) == 0, let size = reader.integer(UInt32.self),
              Int(size) == data.count - headerSize,
              let instance = reader.integer(UInt64.self), let generation = reader.integer(UInt32.self),
              let nonce = reader.integer(UInt64.self), nonce != 0 else { return nil }
        switch kind {
        case .hello: guard size == 0, instance == 0, generation == 0 else { return nil }
        case .bye: guard size == 0, instance != 0 else { return nil }
        case .info: guard size == 24, instance != 0 else { return nil }
        case .raw: guard size >= 7, instance != 0 else { return nil }
        case .acknowledgement: guard size == 25, instance != 0 else { return nil }
        }
        return Packet(kind: kind, instance: instance, generation: generation, nonce: nonce,
                      payload: Data(data.dropFirst(headerSize)))
    }
    static func info(_ packet: Packet) -> Info? {
        guard packet.kind == .info else { return nil }
        var reader = AnafiWireReader(packet.payload)
        guard let flags = reader.integer(UInt32.self), flags & ~UInt32(15) == 0,
              let model = reader.integer(UInt32.self), let size = reader.integer(UInt32.self),
              let maximum = reader.integer(UInt32.self), let interval = reader.integer(Int32.self),
              let protocolVersion = reader.integer(UInt32.self) else { return nil }
        // A disconnected controller legitimately has no negotiation yet. Do
        // not invent defaults or let its zeros configure the frame assembler.
        if flags & 4 == 0 {
            return Info(flags: flags, model: model, negotiation: ARStream1Negotiation(
                fragmentSize: nil, fragmentMaximumNumber: nil, maximumAcknowledgementInterval: nil))
        }
        guard protocolVersion == 1,
              (1...UInt32(maximumPayload - 12)).contains(size), (1...128).contains(maximum),
              UInt64(size) * UInt64(maximum) <= 4_194_304, interval >= -1 else { return nil }
        return Info(flags: flags, model: model, negotiation: ARStream1Negotiation(
            fragmentSize: Int(size), fragmentMaximumNumber: Int(maximum), maximumAcknowledgementInterval: Int(interval)))
    }
}

/// A nonce protects a newly started receiver from delayed packets belonging to
/// its predecessor, including when the OS reuses a UDP source port.
struct SC3SumoNativeVideoWire {
    let nonce: UInt64
    private(set) var instance: UInt64?
    private(set) var generation: UInt32?
    private(set) var info: SC3SumoNativeObserver.Info?
    private(set) var statistics = ARStream1VideoAssembler().statistics
    private var assembler = ARStream1VideoAssembler()
    private var acknowledgementSequence: UInt8 = 0
    private(set) var rejectedPackets: UInt64 = 0

    struct Output {
        var accepted = false
        var changed = false
        var retireFrames = false
        var jpeg: ARStream1CompletedFrame?
        var acknowledgement: Data?
        var failure: String?
    }
    init(nonce: UInt64) { precondition(nonce != 0); self.nonce = nonce }
    var hello: Data {
        SC3SumoNativeObserver.Packet(kind: .hello, instance: 0, generation: 0, nonce: nonce, payload: Data()).encoded
    }
    var bye: Data? {
        guard let instance, let generation else { return nil }
        return SC3SumoNativeObserver.Packet(kind: .bye, instance: instance, generation: generation,
                                           nonce: nonce, payload: Data()).encoded
    }
    mutating func consume(_ bytes: Data) -> Output {
        var output = Output()
        guard let packet = SC3SumoNativeObserver.decode(bytes), packet.nonce == nonce else {
            rejectedPackets &+= 1; return output
        }
        if packet.kind == .info {
            guard let incoming = SC3SumoNativeObserver.info(packet) else { rejectedPackets &+= 1; return output }
            if let instance, instance != packet.instance {
                output.failure = "SC3 native video service restarted; reconnect to retire the previous session"
                return output
            }
            if let generation, generation != packet.generation,
               packet.generation &- generation >= 0x8000_0000 {
                rejectedPackets &+= 1; return output
            }
            if generation != packet.generation || info?.negotiation != incoming.negotiation ||
                (info?.ready == true && !incoming.ready) {
                output.retireFrames = true
                assembler.configure(fragmentSize: incoming.negotiation.fragmentSize,
                                    maximumFragments: incoming.negotiation.fragmentMaximumNumber)
                statistics = assembler.statistics; acknowledgementSequence = 0
            }
            output.changed = info != incoming || generation != packet.generation
            output.accepted = true
            instance = packet.instance; generation = packet.generation; info = incoming
            return output
        }
        guard packet.kind == .raw, instance == packet.instance, generation == packet.generation,
              let info, info.ready,
              let frames = AnafiNetworkFrame.decode(packet.payload), frames.count == 1,
              let frame = frames.first else {
            rejectedPackets &+= 1; return output
        }
        // State remains on the native mobile proxy, which owns its reliable
        // ACKs. Mirrored upstream events must not generate a second ACK stream.
        if (frame.channel == 126 || frame.channel == 127), frame.type == 2 || frame.type == 4 {
            output.accepted = true; return output
        }
        guard frame.channel == 125, frame.type == 2 || frame.type == 3 else { rejectedPackets &+= 1; return output }
        guard let result = assembler.consume(frame.payload) else { rejectedPackets &+= 1; return output }
        output.accepted = true
        statistics = assembler.statistics
        if info.negotiation.sendsVideoAcknowledgements {
            acknowledgementSequence &+= 1
            let raw = ARSDKPhotoProtocol.frame(type: 2, id: 13, sequence: acknowledgementSequence,
                                               payload: result.acknowledgement)
            output.acknowledgement = SC3SumoNativeObserver.Packet(kind: .acknowledgement,
                instance: packet.instance, generation: packet.generation, nonce: nonce, payload: raw).encoded
        }
        if let frame = result.frame, let jpeg = ARStream1VideoAssembler.jpegPayload(in: frame.payload) {
            output.jpeg = ARStream1CompletedFrame(frameNumber: frame.frameNumber, payload: jpeg)
        }
        return output
    }
}

struct SC3SumoNativeState {
    var connected = false
    var controllerProductID: UInt16?
    var linkedProductID: UInt16?
    var linkedName = ""
    var telemetryReady = false
    var pilotingSource: UInt32?
    var battery: Int?
    var videoRequested = false
    var videoAvailable = false
    var videoReceiving = false
    var message = "Connect to the native SC3 Sumo controller"
    var videoMessage = "Native ARStream-1 video requires the separately staged v2 observer"
    var linkedSumo: Bool { connected && linkedProductID == 0x0902 }
}

/// The native viewer has a deliberately tiny command vocabulary. Cancelling
/// video removes its outstanding retry without resetting the channel counter.
struct SC3SumoNativeCommands {
    private struct Pending { let command: Data; let packet: Data; let sequence: UInt8; var deadline: TimeInterval; var retries: Int }
    private var current: Pending?
    private var queued: [Data] = []
    private var sequence: UInt8 = 0
    private(set) var failed = false
    var pending: Bool { current != nil }
    mutating func enqueue(_ command: Data) -> Bool {
        guard [ARSDKPhotoCommand.requestAllStates, ARSDKPhotoCommand.requestSkyControllerAllStates,
               ARSDKPhotoCommand.jumpingSumoVideoEnable(true)].contains(command), queued.count < 8, !failed else { return false }
        if queued.contains(command) || current?.command == command { return true }
        queued.append(command); return true
    }
    mutating func next(now: TimeInterval) -> Data? {
        guard !failed else { return nil }
        if var current {
            guard now >= current.deadline else { return nil }
            guard current.retries < 5 else { failed = true; return nil }
            current.retries += 1; current.deadline = now + 0.15; self.current = current
            return current.packet
        }
        guard !queued.isEmpty else { return nil }
        let command = queued.removeFirst(); sequence &+= 1
        let packet = ARSDKPhotoProtocol.frame(type: 4, id: 11, sequence: sequence, payload: command)
        current = Pending(command: command, packet: packet, sequence: sequence, deadline: now + 0.15, retries: 0)
        return packet
    }
    mutating func acknowledge(_ sequence: UInt8) { if current?.sequence == sequence { current = nil } }
    mutating func cancelVideo() {
        let video = ARSDKPhotoCommand.jumpingSumoVideoEnable(true)
        queued.removeAll { $0 == video }
        if current?.command == video { current = nil }
    }
}
