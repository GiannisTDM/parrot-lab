import Foundation

/// ANAFI 4K ARSDK-ng network subset. Wire definitions come from Parrot's
/// public arsdk-ng and arsdk-xml sources, not firmware/debug interfaces.
enum AnafiRoute: Int, CaseIterable {
    case direct, skyController3, skyController3Mux
    var usesMux: Bool { self == .skyController3Mux }
    var isSC3: Bool { self != .direct }
    var title: String { usesMux ? "SC3 USB bridge" : self == .direct ? "Direct Wi-Fi" : "SC3 network" }
    var defaultHost: String { usesMux ? "127.0.0.1" : self == .direct ? "192.168.42.1" : "192.168.53.1" }
    var videoPort: UInt16 { self == .direct ? 554 : 654 }
    var bonjourType: String { self == .direct ? "_arsdk-0914._udp." : "_arsdk-0918._udp." }
    func videoURL(host: String) -> URL? {
        guard !usesMux, Self.validHost(host) else { return nil }
        return URL(string: "rtsp://\(host):\(videoPort)/live")
    }
    static func validHost(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy {
            !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } && UInt8($0) != nil
        } && host != "0.0.0.0" && host != "255.255.255.255"
    }
}

struct AnafiWireReader {
    private let bytes: [UInt8]
    private(set) var offset = 0
    init(_ data: Data) { bytes = Array(data) }
    mutating func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }
    mutating func integer<T: FixedWidthInteger>(_ type: T.Type = T.self) -> T? {
        guard bytes.count - offset >= MemoryLayout<T>.size else { return nil }
        var result: T = 0
        for index in 0..<MemoryLayout<T>.size { result |= T(truncatingIfNeeded: bytes[offset + index]) << (index * 8) }
        offset += MemoryLayout<T>.size
        return result
    }
    mutating func float() -> Float? {
        guard let value = integer(UInt32.self) else { return nil }
        let result = Float(bitPattern: value)
        return result.isFinite ? result : nil
    }
    mutating func string() -> String? {
        guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        defer { offset = end + 1 }
        return String(bytes: bytes[offset..<end], encoding: .utf8)
    }
}

enum AnafiCommand {
    static func feature(_ feature: UInt8, _ command: UInt16, id: UInt8, values: [UInt32] = []) -> Data {
        var data = Data([feature, 0, UInt8(truncatingIfNeeded: command), UInt8(command >> 8), id])
        for value in values { data.appendAnafiLE(value) }
        return data
    }
    static func camera(_ command: UInt16, id: UInt8, values: [UInt32] = []) -> Data {
        feature(143, command, id: id, values: values)
    }
    static func recording(id: UInt8, mode: UInt32, resolution: UInt32, fps: UInt32, hyperlapse: UInt32) -> Data {
        camera(33, id: id, values: [mode, resolution, fps, hyperlapse])
    }
    static func photo(id: UInt8, mode: UInt32, format: UInt32, file: UInt32,
                      burst: UInt32, bracketing: UInt32, interval: Float) -> Data {
        var data = camera(35, id: id, values: [mode, format, file, burst, bracketing])
        data.appendAnafiLE(interval.bitPattern)
        return data
    }
    static func gimbalPitch(id: UInt8, degrees: Float) -> Data {
        // Position, yaw/roll unused, pitch absolute (horizon referenced).
        var data = feature(148, 5, id: id, values: [0, 0])
        data.appendAnafiLE(Float(0).bitPattern)
        data.appendAnafiLE(UInt32(2))
        data.appendAnafiLE(degrees.bitPattern)
        data.appendAnafiLE(UInt32(0))
        data.appendAnafiLE(Float(0).bitPattern)
        return data
    }
    static func zoom(id: UInt8, level: Float) -> Data {
        var data = camera(21, id: id, values: [0]) // position control
        data.appendAnafiLE(level.bitPattern)
        return data
    }
    static func gimbalSpeed(id: UInt8, yaw: Float, pitch: Float, roll: Float) -> Data {
        var data = feature(148, 4, id: id)
        for value in [yaw, pitch, roll] { data.appendAnafiLE(value.bitPattern) }
        return data
    }
    static func pilotingSource(mac: Bool) -> Data {
        var data = Data([4, 20, 0, 0])
        data.appendAnafiLE(UInt32(mac ? 1 : 0))
        return data
    }
    static func handshake(localPort: UInt16) -> Data {
        // Explicitly negotiate ARSDK-ng v1, which upstream continues to support.
        // Reject a reply selecting a different framing version.
        let object: [String: Any] = ["controller_name": "Parrot Lab", "controller_type": "computer",
                                   "d2c_port": Int(localPort), "proto_v_min": 1, "proto_v_max": 1, "qos_mode": 0]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }
    static func commandPort(_ object: [String: Any]) -> UInt16? {
        guard let status = object["status"] as? Int, status == 0,
              (object["proto_v"] as? Int ?? 1) == 1,
              let port = object["c2d_port"] as? Int, (1...65535).contains(port) else { return nil }
        return UInt16(port)
    }
}

struct AnafiRecordingCapability: Equatable {
    let id: UInt16
    let modes: UInt16
    let resolutions: UInt16
    let framerates: UInt32
    let hdr: Bool
    func supports(mode: Int, resolution: Int, fps: Int) -> Bool {
        AnafiCameraState.contains(modes, mode) && AnafiCameraState.contains(resolutions, resolution) &&
            AnafiCameraState.contains(framerates, fps)
    }
}
struct AnafiPhotoCapability: Equatable {
    let id: UInt16
    let modes: UInt16
    let formats: UInt16
    let files: UInt16
}

/// Only confirmed state is displayed. Camera/gimbal identifiers and option
/// combinations are taken from the device's events, never assumed to be zero.
struct AnafiCameraState {
    var id: UInt8?
    var gimbalID: UInt8?
    var styles: UInt16 = 0
    var whiteBalances: UInt32 = 0
    var evValues: UInt64 = 0
    var streamingModes: UInt8 = 0
    var streamingMode: UInt32?
    var cameraModes: UInt8 = 0
    var hyperlapseValues: UInt16 = 0
    var burstValues: UInt16 = 0
    var bracketingValues: UInt16 = 0
    var timelapseMinimum: Float = 1
    var gpslapseMinimum: Float = 1
    var recordingCapabilities: [UInt16: AnafiRecordingCapability] = [:]
    var photoCapabilities: [UInt16: AnafiPhotoCapability] = [:]
    var mode: UInt32?
    var recordingMode: UInt32?
    var resolution: UInt32?
    var framerate: UInt32?
    var hyperlapse: UInt32 = 0
    var photoMode: UInt32?
    var photoFormat: UInt32?
    var photoFile: UInt32?
    var burst: UInt32 = 0
    var bracketing: UInt32 = 0
    var interval: Float = 1
    var style: UInt32?
    var whiteBalance: UInt32?
    var whiteBalanceTemperature: UInt32 = 16 // 5500 K; ignored for automatic WB
    var ev: UInt32?
    var hdr: Bool?
    var hdrAvailable = false
    var recordingAvailable = false
    var recording: Bool?
    var photoAvailable = false
    var photoActive = false
    var zoom: Float = 1
    var zoomMaximum: Float = 1
    var zoomAvailable = false
    var pitch: Float = 0
    var pitchMinimum: Float = -90
    var pitchMaximum: Float = 90
    var pitchSpeed: Float?
    var pitchSpeedMinimum: Float = 1
    var pitchSpeedMaximum: Float = 90
    var yawSpeed: Float = 0
    var rollSpeed: Float = 0

    static func contains<T: FixedWidthInteger>(_ mask: T, _ value: Int) -> Bool {
        value >= 0 && value < T.bitWidth && mask & (T(1) << value) != 0
    }

    @discardableResult mutating func consume(_ data: Data) -> Bool {
        var reader = AnafiWireReader(data)
        guard let feature = reader.byte(), reader.byte() == 0,
              let command = reader.integer(UInt16.self) else { return false }
        if feature == 148 {
            guard let incomingID = reader.byte() else { return false }
            if command == 1, let _: UInt32 = reader.integer(), reader.byte() != nil {
                if gimbalID == nil { gimbalID = incomingID }
                return true
            }
            guard gimbalID == incomingID else { return false }
            if command == 3 {
                guard reader.float() != nil, reader.float() != nil, let yaw = reader.float(),
                      let minimum = reader.float(), let maximum = reader.float(), let current = reader.float(),
                      reader.float() != nil, reader.float() != nil, let roll = reader.float(), minimum <= maximum else { return false }
                yawSpeed = yaw; rollSpeed = roll; pitchSpeed = current
                pitchSpeedMinimum = minimum; pitchSpeedMaximum = maximum
                return true
            }
            if command == 10 {
                guard reader.float() != nil, reader.float() != nil,
                      let minimum = reader.float(), let maximum = reader.float(), minimum <= maximum,
                      reader.float() != nil, reader.float() != nil else { return false }
                pitchMinimum = minimum; pitchMaximum = maximum
                return true
            }
            if command == 6 {
                for _ in 0..<3 { guard reader.integer(UInt32.self) != nil else { return false } }
                for _ in 0..<4 { guard reader.float() != nil else { return false } }
                guard let value = reader.float(), reader.float() != nil else { return false }
                pitch = value
                return true
            }
            return false
        }
        guard feature == 143 else { return false }
        if command == 2 {
            guard let key = reader.integer(UInt16.self), let modes = reader.integer(UInt16.self),
                  let resolutions = reader.integer(UInt16.self), let rates = reader.integer(UInt32.self),
                  let hdr = reader.integer(UInt32.self), let flags = reader.byte() else { return false }
            if flags & 1 != 0 || flags & 4 != 0 { recordingCapabilities.removeAll() }
            if flags & 8 != 0 { recordingCapabilities.removeValue(forKey: key) }
            else if flags & 4 == 0 {
                recordingCapabilities[key] = .init(id: key, modes: modes, resolutions: resolutions, framerates: rates, hdr: hdr == 1)
            }
            return true
        }
        if command == 3 {
            guard let key = reader.integer(UInt16.self), let modes = reader.integer(UInt16.self),
                  let formats = reader.integer(UInt16.self), let files = reader.integer(UInt16.self),
                  reader.integer(UInt32.self) != nil, let flags = reader.byte() else { return false }
            if flags & 1 != 0 || flags & 4 != 0 { photoCapabilities.removeAll() }
            if flags & 8 != 0 { photoCapabilities.removeValue(forKey: key) }
            else if flags & 4 == 0 { photoCapabilities[key] = .init(id: key, modes: modes, formats: formats, files: files) }
            return true
        }
        guard let incomingID = reader.byte() else { return false }
        if command == 1 {
            guard reader.integer(UInt32.self) != nil, reader.byte() != nil, reader.integer(UInt32.self) != nil,
                  reader.integer(UInt32.self) != nil, let ev = reader.integer(UInt64.self),
                  let wb = reader.integer(UInt32.self), reader.integer(UInt64.self) != nil,
                  reader.integer(UInt32.self) != nil, let styles = reader.integer(UInt16.self),
                  let modes = reader.byte(), let hyper = reader.integer(UInt16.self),
                  let bracket = reader.integer(UInt16.self), let burst = reader.integer(UInt16.self),
                  let stream = reader.byte(), let timeMin = reader.float(), let gpsMin = reader.float() else { return false }
            guard id == nil || id == incomingID else { return false }
            id = incomingID; evValues = ev; whiteBalances = wb; self.styles = styles
            cameraModes = modes; hyperlapseValues = hyper; bracketingValues = bracket; burstValues = burst
            streamingModes = stream; timelapseMinimum = max(0.1, timeMin); gpslapseMinimum = max(0.1, gpsMin)
            return true
        }
        guard id == incomingID else { return false }
        switch command {
        case 13:
            guard let mode = reader.integer(UInt32.self), let temperature = reader.integer(UInt32.self),
                  reader.integer(UInt32.self) != nil else { return false }
            whiteBalance = mode; whiteBalanceTemperature = temperature
        case 15:
            guard let value = reader.integer(UInt32.self) else { return false }; ev = value
        case 20:
            guard let value = reader.integer(UInt32.self) else { return false }
            for _ in 0..<9 { guard reader.byte() != nil else { return false } }
            style = value
        case 22:
            guard let value = reader.float(), value >= 1 else { return false }; zoom = value
        case 23:
            guard let available = reader.integer(UInt32.self), reader.float() != nil,
                  let maximum = reader.float(), maximum >= 1 else { return false }
            zoomAvailable = available == 1; zoomMaximum = maximum
        case 29:
            guard let value = reader.integer(UInt32.self) else { return false }; hdr = value == 1
        case 30:
            guard let available = reader.integer(UInt32.self), reader.integer(UInt32.self) != nil else { return false }
            hdrAvailable = available == 1
        case 32:
            guard let value = reader.integer(UInt32.self) else { return false }; mode = value
        case 34:
            guard let mode = reader.integer(UInt32.self), let resolution = reader.integer(UInt32.self),
                  let fps = reader.integer(UInt32.self), let hyper = reader.integer(UInt32.self),
                  reader.integer(UInt32.self) != nil else { return false }
            recordingMode = mode; self.resolution = resolution; framerate = fps; hyperlapse = hyper
        case 36:
            guard let mode = reader.integer(UInt32.self), let format = reader.integer(UInt32.self),
                  let file = reader.integer(UInt32.self), let burst = reader.integer(UInt32.self),
                  let bracket = reader.integer(UInt32.self), let interval = reader.float() else { return false }
            photoMode = mode; photoFormat = format; photoFile = file
            self.burst = burst; bracketing = bracket; self.interval = interval
        case 38:
            guard let value = reader.integer(UInt32.self) else { return false }; streamingMode = value
        case 41, 45:
            guard let available = reader.integer(UInt32.self), let active = reader.integer(UInt32.self) else { return false }
            if command == 45 {
                guard reader.integer(UInt64.self) != nil else { return false }
                recordingAvailable = available == 1; recording = active == 1
            } else { photoAvailable = available == 1; photoActive = active == 1 }
        default: return false
        }
        return true
    }
}

/// Stop-and-wait keeps command ordering and prevents sequence reuse while an
/// ACK is outstanding. Retries repeat the exact packet, never a new sequence.
struct AnafiReliableChannel {
    struct Pending { let packet: Data; let sequence: UInt8; var deadline: TimeInterval; var retries = 0 }
    private let channel: UInt8
    private let maximumRetries: Int?
    private(set) var pending: Pending?
    private(set) var queued: [Data] = []
    private(set) var sequence: UInt8 = 0
    private(set) var failed = false
    init(channel: UInt8 = 11, maximumRetries: Int? = 5) {
        self.channel = channel; self.maximumRetries = maximumRetries
    }
    mutating func enqueue(_ command: Data) -> Bool {
        guard queued.count < 64, !failed else { return false }
        queued.append(command); return true
    }
    mutating func next(now: TimeInterval) -> Data? {
        guard !failed else { return nil }
        if var value = pending {
            guard now >= value.deadline else { return nil }
            if let maximumRetries, value.retries >= maximumRetries { failed = true; return nil }
            value.retries += 1; value.deadline = now + 0.15; pending = value
            return value.packet
        }
        guard !queued.isEmpty else { return nil }
        sequence &+= 1
        let packet = ARSDKPhotoProtocol.frame(type: 4, id: channel, sequence: sequence, payload: queued.removeFirst())
        pending = Pending(packet: packet, sequence: sequence, deadline: now + 0.15)
        return packet
    }
    mutating func acknowledge(_ value: UInt8) {
        if pending?.sequence == value { pending = nil }
    }
    /// Best-effort ownership return immediately before closing the transport.
    /// Reuse this channel's counter so the drone cannot reject it as an old
    /// retransmission. No ordinary queued commands may follow it.
    mutating func closingPacket(_ command: Data) -> Data {
        pending = nil; queued.removeAll(); sequence &+= 1
        return ARSDKPhotoProtocol.frame(type: 4, id: channel, sequence: sequence, payload: command)
    }
}

struct AnafiNetworkFrame: Equatable {
    let type: UInt8; let channel: UInt8; let sequence: UInt8; let payload: Data
    static func decode(_ data: Data) -> [Self]? {
        let bytes = Array(data)
        var result: [Self] = []
        var offset = 0
        while offset < bytes.count {
            guard bytes.count - offset >= 7, (1...4).contains(bytes[offset]) else { return nil }
            var reader = AnafiWireReader(Data(bytes[(offset + 3)..<(offset + 7)]))
            guard let size = reader.integer(UInt32.self), size >= 7, Int(size) <= bytes.count - offset else { return nil }
            result.append(.init(type: bytes[offset], channel: bytes[offset + 1], sequence: bytes[offset + 2],
                                payload: Data(bytes[(offset + 7)..<(offset + Int(size))])))
            offset += Int(size)
        }
        return result
    }
}

extension Data {
    mutating func appendAnafiLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
