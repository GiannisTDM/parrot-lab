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

enum ARSDKMagnetometerAxis: UInt32, Equatable {
    case x = 0
    case y = 1
    case z = 2
    case none = 3

    var displayName: String {
        switch self {
        case .x: return "X axis"
        case .y: return "Y axis"
        case .z: return "Z axis"
        case .none: return "complete"
        }
    }
}

enum ARSDKTelemetryEvent: Equatable {
    case droneBattery(Int)
    case wifiSignal(Int)
    case jumpingSumoLinkQuality(Int)
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
    case aircraftConnection(status: UInt32, deviceName: String, productID: UInt16)
    case productVersion(software: String, hardware: String)
    case flatTrimChanged
    case magnetometerCalibrationState(x: Bool, y: Bool, z: Bool, failed: Bool)
    case magnetometerCalibrationRequired(Bool)
    case magnetometerCalibrationAxis(ARSDKMagnetometerAxis)
    case magnetometerCalibrationStarted(Bool)
}

enum ARSDKPhotoCommand {
    enum JumpingSumoJumpType: UInt8 {
        case long = 0
        case high = 1
    }

    // ARCommands payloads are project, class, command (little-endian), args.
    static let setFisheye = Data([1, 19, 0, 0, 3, 0, 0, 0])
    static let takePictureV2 = Data([1, 7, 2, 0])
    static let requestAllStates = Data([0, 4, 0, 0])
    static let requestSkyControllerAllStates = Data([4, 6, 0, 0])
    static let requestAllSettings = Data([0, 2, 0, 0])
    static let takeOff = Data([1, 0, 1, 0])
    static let landing = Data([1, 0, 3, 0])
    static let emergency = Data([1, 0, 4, 0])
    static let flatTrim = Data([1, 0, 0, 0])

    static func magnetometerCalibration(start: Bool) -> Data {
        Data([0, 13, 0, 0, start ? 1 : 0])
    }

    static func navigateHome(start: Bool) -> Data {
        Data([1, 0, 5, 0, start ? 1 : 0])
    }

    static func videoEnable(_ enabled: Bool) -> Data {
        Data([1, 21, 0, 0, enabled ? 1 : 0])
    }

    static func cameraOrientation(tilt: Int8, pan: Int8) -> Data {
        Data([1, 1, 0, 0, UInt8(bitPattern: tilt), UInt8(bitPattern: pan)])
    }

    static func pcmd(
        flag: Bool,
        roll: Int8,
        pitch: Int8,
        yaw: Int8,
        gaz: Int8,
        timestampAndSequence: UInt32
    ) -> Data {
        var result = Data([
            1, 0, 2, 0,
            flag ? 1 : 0,
            UInt8(bitPattern: roll), UInt8(bitPattern: pitch),
            UInt8(bitPattern: yaw), UInt8(bitPattern: gaz)
        ])
        result.append(contentsOf: (0..<4).map {
            UInt8((timestampAndSequence >> UInt32($0 * 8)) & 0xff)
        })
        return result
    }

    /// Jumping Sumo project 3, Piloting class 0, PCMD command 0.
    /// The installed Sumo firmware's libarcommands generator defines the wire
    /// arguments as flag, signed speed and signed turn.
    static func jumpingSumoPCMD(flag: Bool, speed: Int8, turn: Int8) -> Data {
        Data([3, 0, 0, 0, flag ? 1 : 0, UInt8(bitPattern: speed), UInt8(bitPattern: turn)])
    }

    /// JumpingSumo.Animations.Jump (project 3, class 2, command 3).
    static func jumpingSumoJump(_ type: JumpingSumoJumpType) -> Data {
        Data([3, 2, 3, 0, type.rawValue])
    }

    /// Jumping Sumo project 3, MediaStreaming class 18, VideoEnable command 0.
    static func jumpingSumoVideoEnable(_ enabled: Bool) -> Data {
        Data([3, 18, 0, 0, enabled ? 1 : 0])
    }
}

enum ARSDKConnectionRoute: Equatable {
    case skyController
    case directProduct

    var displayName: String {
        switch self {
        case .skyController: return "SkyController 2"
        case .directProduct: return "Parrot product direct"
        }
    }
}

struct BebopPilotingInput: Equatable {
    var roll: Int8 = 0
    var pitch: Int8 = 0
    var yaw: Int8 = 0
    var gaz: Int8 = 0

    var flag: Bool { roll != 0 || pitch != 0 }
    static let neutral = BebopPilotingInput()
}

struct JumpingSumoPilotingInput: Equatable {
    let speed: Int8
    let turn: Int8

    var flag: Bool { speed != 0 || turn != 0 }

    init(speed: Int8, turn: Int8) {
        self.speed = speed
        self.turn = turn
    }

    init(sharedInput: BebopPilotingInput) {
        // The existing right-stick / WASD mapping is forward/turn in ground
        // mode. Left-stick yaw/gaz deliberately has no effect on a car.
        speed = sharedInput.pitch
        turn = sharedInput.roll
    }
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

    static func nextSequence(after previous: UInt8?) -> UInt8 {
        (previous ?? 0) &+ 1
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32? {
        guard data.count >= offset + 4 else { return nil }
        return UInt32(data[offset]) |
            UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 |
            UInt32(data[offset + 3]) << 24
    }
}

enum ARSDKDiscoveryProtocol {
    static func responseObject(from data: Data) -> [String: Any]? {
        guard let incoming = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = incoming.trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        guard let json = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: json) as? [String: Any]
    }

    static func arstream1Negotiation(from object: [String: Any]) -> ARStream1Negotiation {
        ARStream1Negotiation(
            fragmentSize: integer(object["arstream_fragment_size"]),
            fragmentMaximumNumber: integer(object["arstream_fragment_maximum_number"]),
            maximumAcknowledgementInterval: integer(object["arstream_max_ack_interval"])
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }
}

struct ARStream1Negotiation: Equatable {
    let fragmentSize: Int?
    let fragmentMaximumNumber: Int?
    let maximumAcknowledgementInterval: Int?

    var sendsVideoAcknowledgements: Bool {
        maximumAcknowledgementInterval != -1
    }
}

struct ARStream1VideoFragmentResult {
    let acknowledgement: Data
    let frame: ARStream1CompletedFrame?
}

struct ARStream1CompletedFrame: Equatable {
    let frameNumber: UInt64
    let payload: Data
}

struct ARStream1AssemblyStatistics: Equatable {
    let receivedFragments: UInt64
    let completedFrames: UInt64
    let incompleteFrames: UInt64
    let missingFragments: UInt64
    let lastFrameNumber: UInt64?
    let lastAssembledBytes: Int?
}

struct ARStream1VideoDiagnostics: Equatable {
    let fragmentReceiveRate: Double
    let assembledFrameRate: Double
    let assembly: ARStream1AssemblyStatistics
    let negotiation: ARStream1Negotiation
}

/// Reassembles the legacy ARStream 1 video carried inside ARNetwork buffer 125.
/// The transport is codec-neutral: BB1 completes Annex-B H.264 frames while
/// Jumping Sumo completes JPEG payloads through the same fragment/ACK protocol.
struct ARStream1VideoAssembler {
    private static let dataHeaderSize = 5
    private static let maximumFragments = 128
    private static let maximumPendingFrames = 4

    private struct PendingFrame {
        let fragmentCount: Int
        var fragments: [Data?]
        var highAcknowledgementMask: UInt64
        var lowAcknowledgementMask: UInt64
        var receivedCount = 0

        init(fragmentCount: Int) {
            self.fragmentCount = fragmentCount
            fragments = [Data?](repeating: nil, count: fragmentCount)
            if fragmentCount < 64 {
                lowAcknowledgementMask = UInt64.max << UInt64(fragmentCount)
                highAcknowledgementMask = UInt64.max
            } else if fragmentCount == 64 {
                lowAcknowledgementMask = 0
                highAcknowledgementMask = UInt64.max
            } else if fragmentCount < ARStream1VideoAssembler.maximumFragments {
                lowAcknowledgementMask = 0
                highAcknowledgementMask = UInt64.max << UInt64(fragmentCount - 64)
            } else {
                lowAcknowledgementMask = 0
                highAcknowledgementMask = 0
            }
        }

        mutating func insert(_ payload: Data, fragmentNumber: Int) {
            guard fragments[fragmentNumber] == nil else { return }
            fragments[fragmentNumber] = payload
            receivedCount += 1
            if fragmentNumber < 64 {
                lowAcknowledgementMask |= UInt64(1) << UInt64(fragmentNumber)
            } else {
                highAcknowledgementMask |= UInt64(1) << UInt64(fragmentNumber - 64)
            }
        }

        var isComplete: Bool { receivedCount == fragmentCount }

        var payload: Data {
            var result = Data()
            result.reserveCapacity(fragments.reduce(0) { $0 + ($1?.count ?? 0) })
            for fragment in fragments {
                if let fragment { result.append(fragment) }
            }
            return result
        }
    }

    private var pendingFrames: [UInt16: PendingFrame] = [:]
    private var pendingOrder: [UInt16] = []
    private var lastDeliveredFrameNumber: UInt64?
    private var negotiatedFragmentSize: Int?
    private var negotiatedMaximumFragments = Self.maximumFragments
    private var receivedFragmentCount: UInt64 = 0
    private var completedFrameCount: UInt64 = 0
    private var incompleteFrameCount: UInt64 = 0
    private var missingFragmentCount: UInt64 = 0
    private var lastCompletedFrameNumber: UInt64?
    private var lastCompletedFrameBytes: Int?

    mutating func configure(fragmentSize: Int?, maximumFragments: Int?) {
        negotiatedFragmentSize = fragmentSize.flatMap { $0 > 0 ? $0 : nil }
        negotiatedMaximumFragments = min(
            Self.maximumFragments,
            max(1, maximumFragments ?? Self.maximumFragments)
        )
        reset()
    }

    mutating func reset() {
        pendingFrames.removeAll(keepingCapacity: false)
        pendingOrder.removeAll(keepingCapacity: false)
        lastDeliveredFrameNumber = nil
        receivedFragmentCount = 0
        completedFrameCount = 0
        incompleteFrameCount = 0
        missingFragmentCount = 0
        lastCompletedFrameNumber = nil
        lastCompletedFrameBytes = nil
    }

    var statistics: ARStream1AssemblyStatistics {
        ARStream1AssemblyStatistics(
            receivedFragments: receivedFragmentCount,
            completedFrames: completedFrameCount,
            incompleteFrames: incompleteFrameCount,
            missingFragments: missingFragmentCount,
            lastFrameNumber: lastCompletedFrameNumber,
            lastAssembledBytes: lastCompletedFrameBytes
        )
    }

    mutating func consume(_ payload: Data) -> ARStream1VideoFragmentResult? {
        guard payload.count >= Self.dataHeaderSize else { return nil }
        let incomingFrameNumber = UInt16(payload[0]) | UInt16(payload[1]) << 8
        let fragmentNumber = Int(payload[3])
        let fragmentCount = Int(payload[4])
        let fragmentPayloadSize = payload.count - Self.dataHeaderSize
        guard (1...negotiatedMaximumFragments).contains(fragmentCount),
              fragmentNumber < fragmentCount,
              negotiatedFragmentSize.map({ fragmentPayloadSize <= $0 }) ?? true else { return nil }
        receivedFragmentCount &+= 1

        var pending: PendingFrame
        if let existing = pendingFrames[incomingFrameNumber],
           existing.fragmentCount == fragmentCount {
            pending = existing
        } else {
            if let existing = pendingFrames[incomingFrameNumber] {
                recordIncomplete(existing)
            }
            pending = PendingFrame(fragmentCount: fragmentCount)
            pendingOrder.removeAll { $0 == incomingFrameNumber }
            pendingOrder.append(incomingFrameNumber)
        }
        pending.insert(
            Data(payload.dropFirst(Self.dataHeaderSize)),
            fragmentNumber: fragmentNumber
        )
        pendingFrames[incomingFrameNumber] = pending
        prunePendingFrames()

        let acknowledgement = makeAcknowledgement(
            frameNumber: incomingFrameNumber,
            highMask: pending.highAcknowledgementMask,
            lowMask: pending.lowAcknowledgementMask
        )
        guard pending.isComplete else {
            return ARStream1VideoFragmentResult(acknowledgement: acknowledgement, frame: nil)
        }

        let extended = extendedFrameNumber(for: incomingFrameNumber)
        guard lastDeliveredFrameNumber.map({ extended > $0 }) ?? true else {
            return ARStream1VideoFragmentResult(acknowledgement: acknowledgement, frame: nil)
        }
        lastDeliveredFrameNumber = extended
        let completedPayload = pending.payload
        pendingFrames.removeValue(forKey: incomingFrameNumber)
        pendingOrder.removeAll { $0 == incomingFrameNumber }
        completedFrameCount &+= 1
        lastCompletedFrameNumber = extended
        lastCompletedFrameBytes = completedPayload.count
        return ARStream1VideoFragmentResult(
            acknowledgement: acknowledgement,
            frame: ARStream1CompletedFrame(
                frameNumber: extended,
                payload: completedPayload
            )
        )
    }

    private mutating func prunePendingFrames() {
        while pendingOrder.count > Self.maximumPendingFrames {
            if let discarded = pendingFrames.removeValue(forKey: pendingOrder.removeFirst()) {
                recordIncomplete(discarded)
            }
        }
    }

    private mutating func recordIncomplete(_ frame: PendingFrame) {
        guard !frame.isComplete else { return }
        incompleteFrameCount &+= 1
        missingFragmentCount &+= UInt64(max(0, frame.fragmentCount - frame.receivedCount))
    }

    private func extendedFrameNumber(for rawValue: UInt16) -> UInt64 {
        guard let lastDeliveredFrameNumber else { return UInt64(rawValue) }
        let wrap = UInt64(UInt16.max) + 1
        let halfWrap = wrap / 2
        let base = lastDeliveredFrameNumber & ~(wrap - 1)
        var candidate = base | UInt64(rawValue)
        if candidate + halfWrap < lastDeliveredFrameNumber {
            candidate += wrap
        } else if candidate > lastDeliveredFrameNumber + halfWrap, candidate >= wrap {
            candidate -= wrap
        }
        return candidate
    }

    private func makeAcknowledgement(frameNumber: UInt16, highMask: UInt64, lowMask: UInt64) -> Data {
        var result = Data()
        Self.appendLittleEndian(frameNumber, to: &result)
        Self.appendLittleEndian(highMask, to: &result)
        Self.appendLittleEndian(lowMask, to: &result)
        return result
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    static func splitAnnexB(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var startCodes: [(offset: Int, length: Int)] = []
        var index = 0
        while index + 3 <= bytes.count {
            if index + 4 <= bytes.count,
               bytes[index] == 0, bytes[index + 1] == 0,
               bytes[index + 2] == 0, bytes[index + 3] == 1 {
                startCodes.append((index, 4))
                index += 4
            } else if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                startCodes.append((index, 3))
                index += 3
            } else {
                index += 1
            }
        }

        var nalUnits: [Data] = []
        for (position, startCode) in startCodes.enumerated() {
            let start = startCode.offset + startCode.length
            var end = position + 1 < startCodes.count ? startCodes[position + 1].offset : bytes.count
            while end > start, bytes[end - 1] == 0 { end -= 1 }
            if end > start { nalUnits.append(data.subdata(in: start..<end)) }
        }
        return nalUnits
    }

    static func jpegPayload(in data: Data) -> Data? {
        guard data.count >= 4,
              data[data.startIndex] == 0xff,
              data[data.startIndex + 1] == 0xd8,
              data[data.endIndex - 2] == 0xff,
              data[data.endIndex - 1] == 0xd9 else { return nil }
        return data
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
        if project == 0, commandClass == 5, command == 7,
           let rawRSSI = int16(data, at: 4) {
            return .wifiSignal(Int(rawRSSI))
        }
        if project == 3, commandClass == 11, command == 4, data.count >= 5 {
            return .jumpingSumoLinkQuality(Int(data[4]))
        }
        if project == 1, commandClass == 4, command == 0 {
            return .flatTrimChanged
        }
        if project == 0, commandClass == 14, command == 0, data.count >= 8 {
            return .magnetometerCalibrationState(
                x: data[4] != 0,
                y: data[5] != 0,
                z: data[6] != 0,
                failed: data[7] != 0
            )
        }
        if project == 0, commandClass == 14, command == 1, data.count >= 5 {
            return .magnetometerCalibrationRequired(data[4] != 0)
        }
        if project == 0, commandClass == 14, command == 2,
           let rawAxis = uint32(data, at: 4),
           let axis = ARSDKMagnetometerAxis(rawValue: rawAxis) {
            return .magnetometerCalibrationAxis(axis)
        }
        if project == 0, commandClass == 14, command == 3, data.count >= 5 {
            return .magnetometerCalibrationStarted(data[4] != 0)
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
        if project == 4, commandClass == 3, command == 1,
           let status = uint32(data, at: 4),
           let name = cString(data, at: 8),
           let productID = uint16(data, at: name.nextOffset) {
            return .aircraftConnection(
                status: status,
                deviceName: name.value,
                productID: productID
            )
        }
        if project == 0, commandClass == 3, command == 3,
           let software = cString(data, at: 4),
           let hardware = cString(data, at: software.nextOffset) {
            return .productVersion(software: software.value, hardware: hardware.value)
        }
        return nil
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16? {
        guard data.count >= offset + 2 else { return nil }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func int16(_ data: Data, at offset: Int) -> Int16? {
        uint16(data, at: offset).map { Int16(bitPattern: $0) }
    }

    private static func cString(_ data: Data, at offset: Int) -> (value: String, nextOffset: Int)? {
        guard offset < data.count,
              let end = data[offset...].firstIndex(of: 0) else { return nil }
        let bytes = data[offset..<end]
        guard let value = String(data: bytes, encoding: .utf8) else { return nil }
        return (value, end + 1)
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
        case .invalidHost: return "The ARSDK host is not a valid IPv4 address."
        case .socket(let detail): return "Could not open the ARSDK command socket: \(detail)"
        case .discovery(let detail): return "ARDiscovery failed: \(detail)"
        case .discoveryTimeout: return "ARDiscovery timed out."
        case .connectionRejected(let status): return "The ARSDK endpoint rejected the connection (status \(status))."
        case .missingCommandPort: return "The discovery reply did not contain a command port."
        }
    }
}

/// Persistent ARDiscovery/ARNetwork/ARCommands client for structured telemetry
/// and stock camera commands routed by the SkyController to its connected Bebop.
final class ARSDKCommandClient {
    var onEvent: ((ARSDKPhotoEvent) -> Void)?
    var onTelemetryEvent: ((ARSDKTelemetryEvent) -> Void)?
    var onVideoAccessUnit: ((H264AccessUnit) -> Void)?
    var onMJPEGFrame: ((Data, UInt64) -> Void)?
    var onARStream1Diagnostics: ((ARStream1VideoDiagnostics) -> Void)?
    var onLog: ((String) -> Void)?

    private let queue = DispatchQueue(label: "parrotlab.arsdk.command", qos: .userInitiated)
    private let videoAssemblyQueue = DispatchQueue(
        label: "parrotlab.arsdk.arstream1",
        qos: .userInteractive
    )
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var discoveryConnection: NWConnection?
    private var discoveryTimeout: DispatchWorkItem?
    private var remoteAddress: sockaddr_in?
    private var sequenceByBuffer: [UInt8: UInt8] = [:]
    private struct PendingAcknowledgement {
        let buffer: UInt8
        let sequence: UInt8
        let packet: Data
        var retries: Int
        let maximumRetries: Int?
    }
    private var pendingAcknowledgements: [UInt16: PendingAcknowledgement] = [:]
    private var connectionCompletions: [(Result<Void, Error>) -> Void] = []
    private var connectingHost: String?
    private var connectedHost: String?
    private var connectionRoute = ARSDKConnectionRoute.skyController
    private var requestedVideoStreamPort: UInt16?
    private var pcmdTimer: DispatchSourceTimer?
    private var pilotingInput = BebopPilotingInput.neutral
    private var pcmdSequence: UInt8 = 0
    private var productModel = ParrotProductModel.unknown
    private var arstream1VideoAssembler = ARStream1VideoAssembler()
    private var arstream1Negotiation = ARStream1Negotiation(
        fragmentSize: nil,
        fragmentMaximumNumber: nil,
        maximumAcknowledgementInterval: nil
    )
    private var videoAssemblyGeneration: UInt64 = 0
    private var activeVideoAssemblyGeneration: UInt64 = 0
    private var diagnosticWindowStartedNanoseconds: UInt64 = 0
    private var diagnosticWindowReceivedFragments: UInt64 = 0
    private var diagnosticWindowCompletedFrames: UInt64 = 0
    private var lastVideoDiagnosticLogNanoseconds: UInt64 = 0
    private var lastInvalidJPEGLog: UInt64 = 0

    func setProductModel(_ model: ParrotProductModel) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.productModel != model { self.resetVideoAssemblyLocked() }
            self.productModel = model
        }
    }

    func connect(
        host: String,
        route: ARSDKConnectionRoute = .skyController,
        videoStreamPort: UInt16? = nil,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
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
            self.connectionRoute = route
            self.requestedVideoStreamPort = videoStreamPort
            do {
                let localPort = try self.openUDPSocket()
                try self.startDiscovery(host: host, localPort: localPort)
            } catch {
                self.finishConnection(.failure(error))
            }
        }
    }

    func sendSetFisheye() {
        guard productModel.capabilities.supportsSharedARDrone3Commands else { return }
        sendCommand(ARSDKPhotoCommand.setFisheye)
    }
    func sendTakePictureV2() {
        guard productModel.capabilities.supportsSharedARDrone3Commands else { return }
        sendCommand(ARSDKPhotoCommand.takePictureV2)
    }
    func sendRequestAllStates() { sendCommand(ARSDKPhotoCommand.requestAllStates) }
    func sendRequestSkyControllerAllStates() {
        sendCommand(ARSDKPhotoCommand.requestSkyControllerAllStates)
    }
    func sendRequestAllSettings() { sendCommand(ARSDKPhotoCommand.requestAllSettings) }
    func sendVideoEnable(_ enabled: Bool) {
        let payload = productModel.capabilities.supportsJumpingSumoCommands
            ? ARSDKPhotoCommand.jumpingSumoVideoEnable(enabled)
            : ARSDKPhotoCommand.videoEnable(enabled)
        sendCommand(payload)
    }
    func sendJumpingSumoHighJump() {
        guard productModel.capabilities.supportsJumpingSumoCommands else { return }
        sendAcknowledgedCommand(ARSDKPhotoCommand.jumpingSumoJump(.high))
    }
    func sendTakeOff() {
        guard productModel.capabilities.supportsSharedARDrone3Commands else { return }
        sendAcknowledgedCommand(ARSDKPhotoCommand.takeOff)
    }
    func sendFlatTrim() {
        guard productModel.capabilities.supportsBebopCalibration else { return }
        sendAcknowledgedCommand(ARSDKPhotoCommand.flatTrim)
    }
    func sendMagnetometerCalibration(start: Bool) {
        guard productModel.capabilities.supportsBebopCalibration else { return }
        sendAcknowledgedCommand(ARSDKPhotoCommand.magnetometerCalibration(start: start))
    }
    func sendLanding() {
        guard productModel.capabilities.supportsSharedARDrone3Commands else { return }
        sendAcknowledgedCommand(ARSDKPhotoCommand.landing)
    }
    func sendEmergency() {
        guard productModel.capabilities.supportsSharedARDrone3Commands else { return }
        sendAcknowledgedCommand(ARSDKPhotoCommand.emergency, buffer: 12, maximumRetries: nil)
    }
    func sendCameraOrientation(tilt: Int8, pan: Int8) {
        guard productModel.capabilities.supportsSharedARDrone3Commands else { return }
        sendUnacknowledgedCommand(ARSDKPhotoCommand.cameraOrientation(tilt: tilt, pan: pan))
    }

    func sendNavigateHome(start: Bool) {
        queue.async { [weak self] in
            guard let self, self.productModel.capabilities.supportsSharedARDrone3Commands else { return }
            self.pilotingInput = .neutral
            self.sendPCMDLocked()
            self.queue.asyncAfter(deadline: .now() + .milliseconds(55)) { [weak self] in
                self?.sendAcknowledgedFrame(payload: ARSDKPhotoCommand.navigateHome(start: start))
            }
        }
    }

    func startPiloting() {
        queue.async { [weak self] in
            guard let self, self.pcmdTimer == nil else { return }
            self.pilotingInput = .neutral
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(4))
            timer.setEventHandler { [weak self] in self?.sendPCMDLocked() }
            self.pcmdTimer = timer
            timer.resume()
        }
    }

    func updatePilotingInput(_ input: BebopPilotingInput) {
        queue.async { [weak self] in self?.pilotingInput = input }
    }

    func neutralizePilotingInput() {
        queue.async { [weak self] in
            self?.pilotingInput = .neutral
            self?.sendPCMDLocked()
        }
    }

    func stopPiloting() {
        queue.async { [weak self] in self?.stopPilotingLocked() }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    private func openUDPSocket() throws -> UInt16 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw ARSDKPhotoConnectionError.socket(String(cString: strerror(errno))) }
        socketFD = fd

        // ARStream1 can burst up to 128 fragments for one MJPEG image. Give
        // the kernel enough room to absorb that burst while the command queue
        // dispatches assembly work separately. macOS may clamp the request.
        var requestedReceiveBytes: Int32 = 4 * 1_024 * 1_024
        var receiveBufferResult = withUnsafePointer(to: &requestedReceiveBytes) {
            setsockopt(
                fd, SOL_SOCKET, SO_RCVBUF, $0,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }
        if receiveBufferResult != 0 {
            requestedReceiveBytes = 1_024 * 1_024
            receiveBufferResult = withUnsafePointer(to: &requestedReceiveBytes) {
                setsockopt(
                    fd, SOL_SOCKET, SO_RCVBUF, $0,
                    socklen_t(MemoryLayout<Int32>.size)
                )
            }
        }
        if receiveBufferResult != 0 {
            log("ARSDK UDP receive-buffer enlargement was not supported; using the system default")
        }

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
                var body: [String: Any] = [
                    "controller_name": "Parrot Lab",
                    "controller_type": "computer",
                    "d2c_port": Int(localPort),
                    "qos_mode": 0
                ]
                if self.connectionRoute == .directProduct,
                   let videoPort = self.requestedVideoStreamPort {
                    body["arstream2_client_stream_port"] = Int(videoPort)
                    body["arstream2_client_control_port"] = Int(videoPort &+ 1)
                }
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
            if let object = ARSDKDiscoveryProtocol.responseObject(from: combined) {
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
                self.log("ARSDK connected to \(self.connectionRoute.displayName) \(host) · command UDP \(port)")
                // Buffer 125 belongs to a directly connected legacy product.
                // An SC2 session may report that its downstream product is a
                // Sumo, but its video still arrives through the SC2 /video
                // restream and must never alter this transport route.
                if self.connectionRoute == .directProduct,
                   self.productModel.capabilities.usesARStream1Video {
                    let negotiation = ARSDKDiscoveryProtocol.arstream1Negotiation(from: object)
                    self.arstream1Negotiation = negotiation
                    self.resetVideoAssemblyLocked(negotiation: negotiation)
                    let fragmentSize = negotiation.fragmentSize.map(String.init) ?? "unspecified"
                    let maximumFragments = negotiation.fragmentMaximumNumber.map(String.init) ?? "unspecified"
                    let acknowledgement = negotiation.sendsVideoAcknowledgements
                        ? "enabled (interval \(negotiation.maximumAcknowledgementInterval.map(String.init) ?? "unspecified"))"
                        : "disabled (-1)"
                    self.log(
                        "ARStream1 negotiated · fragment \(fragmentSize) bytes · max \(maximumFragments) · video ACK \(acknowledgement)"
                    )
                }
                if self.connectionRoute == .directProduct,
                   let clientPort = self.requestedVideoStreamPort {
                    let serverStream = object["arstream2_server_stream_port"] as? Int
                    let serverControl = object["arstream2_server_control_port"] as? Int
                    self.log(
                        "ARStream2 direct client UDP \(clientPort)/\(clientPort &+ 1) · " +
                        "drone UDP \(serverStream.map(String.init) ?? "not announced")/" +
                        "\(serverControl.map(String.init) ?? "not announced")"
                    )
                }
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
        sendAcknowledgedCommand(payload)
    }

    private func sendAcknowledgedCommand(
        _ payload: Data,
        buffer: UInt8 = 11,
        maximumRetries: Int? = 5
    ) {
        queue.async { [weak self] in
            self?.sendAcknowledgedFrame(payload: payload, buffer: buffer, maximumRetries: maximumRetries)
        }
    }

    private func sendAcknowledgedFrame(
        payload: Data,
        buffer: UInt8 = 11,
        maximumRetries: Int? = 5
    ) {
        guard socketFD >= 0, var remoteAddress else { return }
        let sequence = nextSequence(for: buffer)
        let packet = ARSDKPhotoProtocol.frame(type: 4, id: buffer, sequence: sequence, payload: payload)
        sendPacket(packet, to: &remoteAddress)
        let key = acknowledgementKey(buffer: buffer, sequence: sequence)
        pendingAcknowledgements[key] = PendingAcknowledgement(
            buffer: buffer,
            sequence: sequence,
            packet: packet,
            retries: 0,
            maximumRetries: maximumRetries
        )
        scheduleRetry(key: key)
    }

    private func sendUnacknowledgedCommand(_ payload: Data) {
        queue.async { [weak self] in self?.sendFrame(type: 2, id: 10, payload: payload) }
    }

    private func sendFrame(type: UInt8, id: UInt8, payload: Data) {
        guard socketFD >= 0, var remoteAddress else { return }
        let sequence = nextSequence(for: id)
        let packet = ARSDKPhotoProtocol.frame(type: type, id: id, sequence: sequence, payload: payload)
        sendPacket(packet, to: &remoteAddress)
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

    private func scheduleRetry(key: UInt16) {
        queue.asyncAfter(deadline: .now() + .milliseconds(150)) { [weak self] in
            guard let self, var pending = self.pendingAcknowledgements[key],
                  var remote = self.remoteAddress else { return }
            if let maximumRetries = pending.maximumRetries, pending.retries >= maximumRetries {
                self.pendingAcknowledgements.removeValue(forKey: key)
                self.log("ARSDK buffer \(pending.buffer) command acknowledgement timed out")
                return
            }
            pending.retries += 1
            self.pendingAcknowledgements[key] = pending
            self.sendPacket(pending.packet, to: &remote)
            self.scheduleRetry(key: key)
        }
    }

    private func acknowledgementKey(buffer: UInt8, sequence: UInt8) -> UInt16 {
        UInt16(buffer) << 8 | UInt16(sequence)
    }

    private func sendPCMDLocked() {
        guard remoteAddress != nil else { return }
        if productModel.capabilities.supportsJumpingSumoCommands {
            let drive = JumpingSumoPilotingInput(sharedInput: pilotingInput)
            sendFrame(
                type: 2,
                id: 10,
                payload: ARSDKPhotoCommand.jumpingSumoPCMD(
                    flag: drive.flag,
                    speed: drive.speed,
                    turn: drive.turn
                )
            )
            return
        }
        guard productModel.capabilities.supportsSharedARDrone3Commands else { return }
        pcmdSequence &+= 1
        let milliseconds = UInt32((DispatchTime.now().uptimeNanoseconds / 1_000_000) & 0x00ff_ffff)
        let timestampAndSequence = UInt32(pcmdSequence) << 24 | milliseconds
        let payload = ARSDKPhotoCommand.pcmd(
            flag: pilotingInput.flag,
            roll: pilotingInput.roll,
            pitch: pilotingInput.pitch,
            yaw: pilotingInput.yaw,
            gaz: pilotingInput.gaz,
            timestampAndSequence: timestampAndSequence
        )
        sendFrame(type: 2, id: 10, payload: payload)
    }

    private func stopPilotingLocked() {
        pilotingInput = .neutral
        sendPCMDLocked()
        pcmdTimer?.cancel()
        pcmdTimer = nil
    }

    private func nextSequence(for id: UInt8) -> UInt8 {
        let next = ARSDKPhotoProtocol.nextSequence(after: sequenceByBuffer[id])
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

            // Command reliability always takes precedence over video work.
            // ARStream payloads are handed to a separate serial worker below.
            if type == 1, (id == 139 || id == 140), let acknowledgedSequence = payload.first {
                let sourceBuffer = id &- 128
                pendingAcknowledgements.removeValue(
                    forKey: acknowledgementKey(buffer: sourceBuffer, sequence: acknowledgedSequence)
                )
                offset += size
                continue
            }
            if type == 4 {
                sendFrame(type: 1, id: id &+ 128, payload: Data([sequence]))
            }
            if type == 2, id == 0 {
                sendFrame(type: 2, id: 1, payload: payload)
            }

            if connectionRoute == .directProduct,
               productModel.capabilities.usesARStream1Video, id == 125 {
                enqueueARStream1PayloadLocked(payload)
                offset += size
                continue
            }

            if (id == 126 || id == 127), let event = ARSDKPhotoProtocol.decode(payload) {
                DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
            }
            if id == 126 || id == 127, let telemetry = ARSDKTelemetryProtocol.decode(payload) {
                if case .aircraftConnection(let status, _, let productID) = telemetry, status == 2 {
                    let detectedModel = ParrotProductModel(productID: productID)
                    if productModel != detectedModel { resetVideoAssemblyLocked() }
                    productModel = detectedModel
                }
                DispatchQueue.main.async { [weak self] in self?.onTelemetryEvent?(telemetry) }
            }
            offset += size
        }
    }

    private func enqueueARStream1PayloadLocked(_ payload: Data) {
        let generation = videoAssemblyGeneration
        let codec = productModel.capabilities.videoCodec
        let negotiation = arstream1Negotiation
        videoAssemblyQueue.async { [weak self] in
            guard let self, self.activeVideoAssemblyGeneration == generation else { return }
            self.diagnosticWindowReceivedFragments &+= 1
            if let result = self.arstream1VideoAssembler.consume(payload) {
                if negotiation.sendsVideoAcknowledgements {
                    self.queue.async { [weak self] in
                        guard let self, self.videoAssemblyGeneration == generation else { return }
                        self.sendFrame(type: 2, id: 13, payload: result.acknowledgement)
                    }
                }
                if let frame = result.frame {
                    self.diagnosticWindowCompletedFrames &+= 1
                    self.deliverARStream1Frame(frame, codec: codec)
                }
            }
            self.publishARStream1DiagnosticsIfNeeded(negotiation: negotiation)
        }
    }

    private func resetVideoAssemblyLocked(negotiation: ARStream1Negotiation? = nil) {
        videoAssemblyGeneration &+= 1
        let generation = videoAssemblyGeneration
        let applied = negotiation ?? arstream1Negotiation
        videoAssemblyQueue.async { [weak self] in
            guard let self else { return }
            self.activeVideoAssemblyGeneration = generation
            self.arstream1VideoAssembler.configure(
                fragmentSize: applied.fragmentSize,
                maximumFragments: applied.fragmentMaximumNumber
            )
            self.diagnosticWindowStartedNanoseconds = DispatchTime.now().uptimeNanoseconds
            self.diagnosticWindowReceivedFragments = 0
            self.diagnosticWindowCompletedFrames = 0
            self.lastVideoDiagnosticLogNanoseconds = 0
            self.lastInvalidJPEGLog = 0
        }
    }

    private func publishARStream1DiagnosticsIfNeeded(negotiation: ARStream1Negotiation) {
        let now = DispatchTime.now().uptimeNanoseconds
        if diagnosticWindowStartedNanoseconds == 0 {
            diagnosticWindowStartedNanoseconds = now
            return
        }
        let elapsedNanoseconds = now &- diagnosticWindowStartedNanoseconds
        guard elapsedNanoseconds >= 1_000_000_000 else { return }
        let elapsed = Double(elapsedNanoseconds) / 1_000_000_000
        let diagnostics = ARStream1VideoDiagnostics(
            fragmentReceiveRate: Double(diagnosticWindowReceivedFragments) / elapsed,
            assembledFrameRate: Double(diagnosticWindowCompletedFrames) / elapsed,
            assembly: arstream1VideoAssembler.statistics,
            negotiation: negotiation
        )
        diagnosticWindowStartedNanoseconds = now
        diagnosticWindowReceivedFragments = 0
        diagnosticWindowCompletedFrames = 0
        DispatchQueue.main.async { [weak self] in self?.onARStream1Diagnostics?(diagnostics) }

        if now &- lastVideoDiagnosticLogNanoseconds >= 5_000_000_000 {
            lastVideoDiagnosticLogNanoseconds = now
            let stats = diagnostics.assembly
            log(
                String(
                    format: "ARStream1 RX %.1f frag/s · assembled %.1f fps · frame %@ · JPEG %@ bytes · incomplete %llu · missing %llu",
                    diagnostics.fragmentReceiveRate,
                    diagnostics.assembledFrameRate,
                    stats.lastFrameNumber.map(String.init) ?? "—",
                    stats.lastAssembledBytes.map(String.init) ?? "—",
                    stats.incompleteFrames,
                    stats.missingFragments
                )
            )
        }
    }

    private func deliverARStream1Frame(_ frame: ARStream1CompletedFrame, codec: ParrotVideoCodec) {
        switch codec {
        case .h264:
            let nalUnits = ARStream1VideoAssembler.splitAnnexB(frame.payload)
            guard !nalUnits.isEmpty else { return }
            let accessUnit = H264AccessUnit(
                nalUnits: nalUnits,
                rtpTimestamp: UInt32(truncatingIfNeeded: frame.frameNumber &* 3_000),
                rtpHeaderExtensions: []
            )
            DispatchQueue.main.async { [weak self] in self?.onVideoAccessUnit?(accessUnit) }
        case .mjpeg:
            guard let jpeg = ARStream1VideoAssembler.jpegPayload(in: frame.payload) else {
                let now = DispatchTime.now().uptimeNanoseconds
                if now &- lastInvalidJPEGLog >= 2_000_000_000 {
                    lastInvalidJPEGLog = now
                    log("Jumping Sumo ARStream 1 dropped an invalid JPEG (missing SOI/EOI boundary)")
                }
                return
            }
            DispatchQueue.main.async { [weak self] in self?.onMJPEGFrame?(jpeg, frame.frameNumber) }
        }
    }

    private func stopLocked() {
        stopPilotingLocked()
        discoveryTimeout?.cancel()
        discoveryTimeout = nil
        discoveryConnection?.cancel()
        discoveryConnection = nil
        connectionCompletions.removeAll()
        connectingHost = nil
        remoteAddress = nil
        connectedHost = nil
        requestedVideoStreamPort = nil
        sequenceByBuffer.removeAll()
        pendingAcknowledgements.removeAll()
        pcmdSequence = 0
        arstream1Negotiation = ARStream1Negotiation(
            fragmentSize: nil,
            fragmentMaximumNumber: nil,
            maximumAcknowledgementInterval: nil
        )
        resetVideoAssemblyLocked(negotiation: arstream1Negotiation)
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
              ARSDKPhotoCommand.requestSkyControllerAllStates == Data([4, 6, 0, 0]),
              ARSDKPhotoCommand.flatTrim == Data([1, 0, 0, 0]),
              ARSDKPhotoCommand.magnetometerCalibration(start: true) == Data([0, 13, 0, 0, 1]),
              ARSDKPhotoCommand.magnetometerCalibration(start: false) == Data([0, 13, 0, 0, 0]) else { return false }

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
              ARSDKPhotoProtocol.nextSequence(after: nil) == 1,
              ARSDKPhotoProtocol.nextSequence(after: 255) == 0,
              ARSDKTelemetryProtocol.decode(Data([0, 5, 1, 0, 74])) == .droneBattery(74),
              ARSDKTelemetryProtocol.decode(Data([0, 5, 7, 0, 0xc8, 0xff])) == .wifiSignal(-56),
              ARSDKTelemetryProtocol.decode(Data([3, 11, 4, 0, 5])) == .jumpingSumoLinkQuality(5),
              ARSDKTelemetryProtocol.decode(Data([4, 8, 0, 0, 83])) == .controllerBattery(83),
              ARSDKTelemetryProtocol.decode(Data([1, 4, 1, 0, 0, 0, 0, 0])) == .flyingState(0),
              ARSDKTelemetryProtocol.decode(Data([1, 24, 2, 0, 1])) == .gpsFix(true),
              ARSDKTelemetryProtocol.decode(Data([1, 31, 0, 0, 12])) == .satelliteCount(12),
              ARSDKTelemetryProtocol.decode(Data([1, 4, 0, 0])) == .flatTrimChanged,
              ARSDKTelemetryProtocol.decode(Data([0, 14, 0, 0, 1, 0, 1, 0])) ==
                .magnetometerCalibrationState(x: true, y: false, z: true, failed: false),
              ARSDKTelemetryProtocol.decode(Data([0, 14, 1, 0, 1])) ==
                .magnetometerCalibrationRequired(true),
              ARSDKTelemetryProtocol.decode(Data([0, 14, 2, 0, 2, 0, 0, 0])) ==
                .magnetometerCalibrationAxis(.z),
              ARSDKTelemetryProtocol.decode(Data([0, 14, 3, 0, 1])) ==
                .magnetometerCalibrationStarted(true) else {
            return false
        }

        let paddedDiscovery = Data(#"{"status":0,"c2d_port":54321}"#.utf8) + Data([0])
        guard let discovery = ARSDKDiscoveryProtocol.responseObject(from: paddedDiscovery),
              discovery["status"] as? Int == 0,
              discovery["c2d_port"] as? Int == 54_321 else { return false }

        let patchedSumoDiscovery = Data(
            #"{"status":0,"c2d_port":54321,"arstream_fragment_size":1400,"arstream_fragment_maximum_number":128,"arstream_max_ack_interval":-1}"#.utf8
        )
        guard let patchedSumoObject = ARSDKDiscoveryProtocol.responseObject(from: patchedSumoDiscovery) else {
            return false
        }
        let patchedSumoNegotiation = ARSDKDiscoveryProtocol.arstream1Negotiation(from: patchedSumoObject)
        guard patchedSumoNegotiation == ARStream1Negotiation(
            fragmentSize: 1_400,
            fragmentMaximumNumber: 128,
            maximumAcknowledgementInterval: -1
        ), !patchedSumoNegotiation.sendsVideoAcknowledgements else { return false }

        let accessUnitBytes = Data([
            0, 0, 0, 1, 0x67, 0x11,
            0, 0, 0, 1, 0x68, 0x22,
            0, 0, 0, 1, 0x65, 0x33, 0x44
        ])
        let midpoint = 10
        var firstFragment = Data([42, 0, 1, 0, 2])
        firstFragment.append(accessUnitBytes.prefix(midpoint))
        var secondFragment = Data([42, 0, 1, 1, 2])
        secondFragment.append(accessUnitBytes.dropFirst(midpoint))
        var arstream1 = ARStream1VideoAssembler()
        arstream1.configure(fragmentSize: 1_400, maximumFragments: 128)
        guard let firstResult = arstream1.consume(firstFragment),
              firstResult.frame == nil,
              firstResult.acknowledgement.count == 18,
              firstResult.acknowledgement[0] == 42,
              firstResult.acknowledgement[10] == 0xfd,
              let completed = arstream1.consume(secondFragment)?.frame,
              completed.payload == accessUnitBytes,
              completed.frameNumber == 42,
              ARStream1VideoAssembler.splitAnnexB(completed.payload) == [
                Data([0x67, 0x11]), Data([0x68, 0x22]), Data([0x65, 0x33, 0x44])
              ] else { return false }

        let completeJPEG = Data([0xff, 0xd8, 0x11, 0x22, 0xff, 0xd9])
        let paddedJPEG = Data([0, 1]) + completeJPEG + Data([3])
        guard ARStream1VideoAssembler.jpegPayload(in: completeJPEG) == completeJPEG,
              ARStream1VideoAssembler.jpegPayload(in: paddedJPEG) == nil,
              ARStream1VideoAssembler.jpegPayload(in: Data([0xff, 0xd8, 1])) == nil,
              ARSDKPhotoCommand.jumpingSumoPCMD(flag: true, speed: 100, turn: -100) ==
                Data([3, 0, 0, 0, 1, 100, 156]),
              ARSDKPhotoCommand.jumpingSumoVideoEnable(true) == Data([3, 18, 0, 0, 1]) else {
            return false
        }

        // The patched 1400/128 geometry accepts the full negotiated fragment
        // range while rejecting a sender that exceeds it.
        var geometry = ARStream1VideoAssembler()
        geometry.configure(fragmentSize: 1_400, maximumFragments: 128)
        var fragment128 = Data([7, 0, 0, 127, 128])
        fragment128.append(contentsOf: [0xaa])
        var fragment129 = Data([8, 0, 0, 0, 129])
        fragment129.append(contentsOf: [0xbb])
        guard geometry.consume(fragment128) != nil,
              geometry.consume(fragment129) == nil else { return false }

        // When more interleaved frame IDs arrive than the bounded window can
        // retain, the evicted frame contributes precise loss diagnostics.
        var lossDiagnostics = ARStream1VideoAssembler()
        for frameID: UInt8 in 1...5 {
            var fragment = Data([frameID, 0, 0, 0, 2])
            fragment.append(contentsOf: [0xff, 0xd8])
            guard lossDiagnostics.consume(fragment) != nil else { return false }
        }
        guard lossDiagnostics.statistics.incompleteFrames == 1,
              lossDiagnostics.statistics.missingFragments == 1 else { return false }

        // A late fragment from frame 50 must not discard the newer frame 51.
        // Both frames are assembled independently and stale completion is not
        // delivered after a newer frame has already reached the client.
        var interleaved = ARStream1VideoAssembler()
        var frame50Part0 = Data([50, 0, 1, 0, 2])
        frame50Part0.append(contentsOf: [0xff, 0xd8, 0x50])
        var frame51Part0 = Data([51, 0, 1, 0, 2])
        frame51Part0.append(contentsOf: [0xff, 0xd8, 0x51])
        var frame51Part1 = Data([51, 0, 1, 1, 2])
        frame51Part1.append(contentsOf: [0xff, 0xd9])
        var frame50Part1 = Data([50, 0, 1, 1, 2])
        frame50Part1.append(contentsOf: [0xff, 0xd9])
        guard interleaved.consume(frame50Part0)?.frame == nil,
              interleaved.consume(frame51Part0)?.frame == nil,
              interleaved.consume(frame51Part1)?.frame?.payload == Data([0xff, 0xd8, 0x51, 0xff, 0xd9]),
              interleaved.consume(frame50Part1)?.frame == nil else { return false }

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
        guard ARSDKTelemetryProtocol.decode(position) == .gpsPosition(latitude: 38.1, longitude: 21.7) else {
            return false
        }

        var product = Data([4, 3, 1, 0])
        product.append(contentsOf: [2, 0, 0, 0])
        product.append(contentsOf: Data("BebopDrone\0".utf8))
        product.append(contentsOf: [0x01, 0x09])
        var version = Data([0, 3, 3, 0])
        version.append(contentsOf: Data("4.0.6\0HW_01\0".utf8))
        return ARSDKTelemetryProtocol.decode(product) == .aircraftConnection(
            status: 2,
            deviceName: "BebopDrone",
            productID: 0x0901
        ) && ARSDKTelemetryProtocol.decode(version) == .productVersion(
            software: "4.0.6",
            hardware: "HW_01"
        )
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
