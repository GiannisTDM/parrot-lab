import Foundation

/// Legacy ARSDK3 BLE framing. Deliberately independent of CoreBluetooth and UDP.
enum MiniDroneChannel: String, CaseIterable {
    case piloting = "fa0a", command = "fa0b", emergency = "fa0c", acknowledge = "fa1e"
    case state = "fb0e", telemetry = "fb0f", commandACK = "fb1b", emergencyACK = "fb1c"

    var uuid: String { "9a66\(rawValue)-0800-9191-11e4-012d1540cb8e" }
    static let notifications: Set<Self> = [.state, .telemetry, .commandACK, .emergencyACK]
    static let outputs: Set<Self> = [.piloting, .command, .emergency, .acknowledge]
}

enum MiniDroneCommand {
    static let flatTrim = Data([2, 0, 0, 0])
    static let takeOff = Data([2, 0, 1, 0])
    static let landing = Data([2, 0, 3, 0])
    static let emergency = Data([2, 0, 4, 0])
    static let allStates = Data([0, 4, 0, 0])
    static let allSettings = Data([0, 2, 0, 0])

    static func pcmd(roll: Int8, pitch: Int8, yaw: Int8, gaz: Int8, milliseconds: UInt32) -> Data {
        let axes = [roll, pitch, yaw, gaz].map { min(100, max(-100, $0)) }
        return Data([2, 0, 2, 0, axes[0] != 0 || axes[1] != 0 ? 1 : 0] +
                    axes.map { UInt8(bitPattern: $0) } + le32(milliseconds))
    }

    static func grabber(id: UInt8, close: Bool) -> Data {
        Data([2, 16, 1, 0, id] + le32(close ? 1 : 0))
    }

    static func cannon(id: UInt8) -> Data { Data([2, 16, 2, 0, id, 0, 0, 0, 0]) }

    static func le32(_ value: UInt32) -> [UInt8] {
        (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
}

enum MiniDroneFlyingState: UInt32 {
    case landed, takingOff, hovering, flying, landing, emergency, rolling, initializing
    var title: String {
        switch self {
        case .landed: return "Landed"
        case .takingOff: return "Taking off"
        case .hovering: return "Hovering"
        case .flying: return "Flying"
        case .landing: return "Landing"
        case .emergency: return "Emergency"
        case .rolling: return "Rolling"
        case .initializing: return "Initializing"
        }
    }
}

struct MiniDroneTelemetry {
    private(set) var battery: UInt8?
    private(set) var flightState: MiniDroneFlyingState?
    private(set) var grabbers: [UInt8: UInt32] = [:]
    private(set) var cannons: [UInt8: UInt32] = [:]

    mutating func consume(_ payload: Data) {
        let b = [UInt8](payload)
        guard b.count >= 4 else { return }
        let command = UInt16(b[2]) | UInt16(b[3]) << 8
        func word(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | UInt32(b[offset + $1]) << ($1 * 8) }
        }
        switch (b[0], b[1], command) {
        case (0, 5, 1) where b.count >= 5:
            battery = b[4] <= 100 ? b[4] : nil
        case (2, 3, 1) where b.count == 5 || b.count >= 8:
            // ARCommands encodes enums as i32. A few legacy MiniDrone builds
            // emit the same value as a single byte, so accept both forms.
            let value = b.count >= 8 ? word(4) : UInt32(b[4])
            flightState = MiniDroneFlyingState(rawValue: value)
        case (2, 15, 1), (2, 15, 2):
            guard b.count == 7 || b.count >= 10 else { return }
            var inventory = command == 1 ? grabbers : cannons
            let legacyEnum = b.count < 10
            let state = legacyEnum ? UInt32(b[5]) : word(5)
            let flags = b[legacyEnum ? 6 : 9]
            if flags & 1 != 0 || flags & 4 != 0 { inventory.removeAll() }
            if flags & 4 == 0 {
                if flags & 8 != 0 { inventory.removeValue(forKey: b[4]) }
                else { inventory[b[4]] = state }
            }
            if command == 1 { grabbers = inventory } else { cannons = inventory }
        default: break
        }
    }

    func canUseGrabber(_ id: UInt8) -> Bool { grabbers[id] == 0 || grabbers[id] == 2 }
    func canFireCannon(_ id: UInt8) -> Bool { cannons[id] == 0 }
}

/// Readiness is an explicit subscription barrier, shared by the adapter and offline tests.
struct MiniDroneSubscriptions {
    private(set) var enabled: Set<MiniDroneChannel> = []
    var ready: Bool { enabled == MiniDroneChannel.notifications }
    mutating func subscribed(_ channel: MiniDroneChannel) { enabled.insert(channel) }
}

/// A deterministic ARNetwork scheduler. The write closure must return false for
/// backpressure; only accepted writes start ACK timers. Retries reuse their sequence.
struct MiniDroneLink {
    struct Write: Equatable {
        let channel: MiniDroneChannel
        let data: Data
    }
    private struct Pending {
        let write: Write
        var sentAt: TimeInterval?
        var retries = 0
    }
    private var sequences: [MiniDroneChannel: UInt8] = [:]
    private var receivedSequences: [MiniDroneChannel: UInt8] = [:]
    private var queues: [MiniDroneChannel: [Pending]] = [:]
    private var acknowledgements: [Write] = []
    private(set) var failure: String?
    var pendingCount: Int { queues.values.reduce(0) { $0 + $1.count } }

    private mutating func frame(_ payload: Data, channel: MiniDroneChannel, type: UInt8) -> Write {
        let sequence = (sequences[channel] ?? 0) &+ 1
        sequences[channel] = sequence
        return Write(channel: channel, data: Data([type, sequence]) + payload)
    }

    mutating func pilotingPacket(_ payload: Data) -> Write {
        frame(payload, channel: .piloting, type: 2)
    }

    @discardableResult
    mutating func enqueue(_ payload: Data, emergency: Bool = false) -> Bool {
        guard failure == nil, payload.count >= 4, payload.count <= 18 else { return false }
        let channel: MiniDroneChannel = emergency ? .emergency : .command
        if emergency {
            // Never replay queued takeoff/accessory commands after an emergency.
            queues[.command] = []
            if !(queues[.emergency] ?? []).isEmpty { return true }
        }
        guard (queues[channel]?.count ?? 0) < (emergency ? 1 : 20) else { return false }
        let write = frame(payload, channel: channel, type: 4)
        queues[channel, default: []].append(Pending(write: write))
        return true
    }

    mutating func receive(_ data: Data, on channel: MiniDroneChannel) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes.count <= 20 else { return nil }
        if channel == .commandACK || channel == .emergencyACK {
            let output: MiniDroneChannel = channel == .commandACK ? .command : .emergency
            guard bytes.count == 3, bytes[0] == 1,
                  let pending = queues[output]?.first, pending.sentAt != nil,
                  pending.write.data[1] == bytes[2] else { return nil }
            queues[output]?.removeFirst()
            return nil
        }
        // The GATT characteristic determines whether the packet needs an ACK.
        // Firmware revisions have used both ARNetwork data markers on FB0E/FB0F.
        guard bytes[0] == 2 || bytes[0] == 4, bytes.count >= 6 else { return nil }
        if channel == .state {
            // ACK duplicate notifications too: the drone may have lost our ACK.
            let ack = frame(Data([bytes[1]]), channel: .acknowledge, type: 1)
            if acknowledgements.count >= 32 { acknowledgements.removeFirst() }
            acknowledgements.append(ack)
        }
        if let previous = receivedSequences[channel] {
            let delta = bytes[1] &- previous
            guard delta > 0, delta < 128 else { return nil }
        }
        receivedSequences[channel] = bytes[1]
        return Data(bytes.dropFirst(2))
    }

    mutating func tick(now: TimeInterval, pcmd: Data?, write: (Write) -> Bool) {
        guard failure == nil else { return }
        // Emergency gets the first available transmission slot.
        for channel in [MiniDroneChannel.emergency, .acknowledge, .command] {
            if channel == .acknowledge {
                while let first = acknowledgements.first {
                    guard write(first) else { break }
                    acknowledgements.removeFirst()
                }
                continue
            }
            guard var pending = queues[channel]?.first else { continue }
            if let sentAt = pending.sentAt {
                guard now - sentAt >= 0.15 else { continue }
                if channel != .emergency && pending.retries >= 5 {
                    failure = "Command acknowledgement timed out. Reconnect before retrying."
                    return
                }
            }
            if write(pending.write) {
                if pending.sentAt != nil { pending.retries += 1 }
                pending.sentAt = now
                queues[channel]?[0] = pending
            }
        }
        if let pcmd, pcmd.count <= 18 {
            // PCMD is never queued: an old stick position must not outlive congestion.
            let packet = pilotingPacket(pcmd)
            _ = write(packet)
        }
    }
}
