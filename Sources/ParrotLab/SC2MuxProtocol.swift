import Foundation

/// Parrot's public libmux framing and ARSDK channel assignment, implemented in
/// Swift so the SC2 path remains isolated from direct Wi-Fi ARDiscovery.
enum SC2MuxChannel: UInt32, CaseIterable {
    case control = 0
    case transport = 1
    case discovery = 2
    case backend = 3
    case streamData = 4
    case streamControl = 5
    case rtp = 6
}

struct SC2MuxFrame: Equatable {
    let channel: UInt32
    let payload: Data
}

enum SC2MuxCodec {
    static let headerSize = 12
    static let maximumFrameSize = 8 * 1_024 * 1_024

    static func encode(channel: UInt32, payload: Data) -> Data {
        var data = Data("MUX!".utf8)
        data.appendLE(channel)
        data.appendLE(UInt32(headerSize + payload.count))
        data.append(payload)
        return data
    }
}

struct SC2MuxStreamDecoder {
    private var buffer = Data()

    mutating func append(_ bytes: Data) -> [SC2MuxFrame] {
        buffer.append(bytes)
        var frames: [SC2MuxFrame] = []
        while true {
            if buffer.count < SC2MuxCodec.headerSize { break }
            if buffer.prefix(4) != Data("MUX!".utf8) {
                if let next = buffer.range(of: Data("MUX!".utf8), options: [], in: 1..<buffer.count) {
                    buffer = Data(buffer[next.lowerBound...])
                } else {
                    buffer = Data(buffer.suffix(3))
                    break
                }
                continue
            }
            guard let channel = buffer.u32LE(at: 4),
                  let total = buffer.u32LE(at: 8) else { break }
            let size = Int(total)
            guard size >= SC2MuxCodec.headerSize, size <= SC2MuxCodec.maximumFrameSize else {
                buffer = Data(buffer.dropFirst(4))
                continue
            }
            guard buffer.count >= size else { break }
            let payloadStart = buffer.index(buffer.startIndex, offsetBy: SC2MuxCodec.headerSize)
            let payloadEnd = buffer.index(buffer.startIndex, offsetBy: size)
            frames.append(SC2MuxFrame(
                channel: channel,
                payload: buffer.subdata(in: payloadStart..<payloadEnd)
            ))
            buffer = Data(buffer.dropFirst(size))
        }
        return frames
    }
}

private struct SC2MuxControlMessage {
    static let open: UInt32 = 0
    static let close: UInt32 = 1
    static let reset: UInt32 = 6
    static let handshake: UInt32 = 127

    let id: UInt32
    let channel: UInt32
    let arguments: [UInt32]

    func encoded() -> Data {
        var data = Data()
        data.appendLE(id)
        data.appendLE(channel)
        for index in 0..<6 { data.appendLE(index < arguments.count ? arguments[index] : 0) }
        return data
    }

    static func decode(_ data: Data) -> SC2MuxControlMessage? {
        guard data.count >= 32, let id = data.u32LE(at: 0), let channel = data.u32LE(at: 4) else {
            return nil
        }
        let arguments = (0..<6).compactMap { data.u32LE(at: 8 + $0 * 4) }
        guard arguments.count == 6 else { return nil }
        return SC2MuxControlMessage(id: id, channel: channel, arguments: arguments)
    }
}

// Shared wire primitives also used by the isolated SC3 backend.
enum SC2PompField {
    case i32(Int32)
    case u32(UInt32)
    case u16(UInt16)
    case string(String)
    case buffer(Data)
}

struct SC2PompMessage {
    static let headerSize = 12
    let id: UInt32
    let payload: Data

    static func encode(id: UInt32, fields: [SC2PompField] = []) -> Data {
        var payload = Data()
        for field in fields {
            switch field {
            case .i32(let value):
                payload.append(0x05)
                let zigzag = UInt32(bitPattern: (value << 1) ^ (value >> 31))
                payload.appendVarint(UInt64(zigzag))
            case .u32(let value):
                payload.append(0x06)
                payload.appendVarint(UInt64(value))
            case .u16(let value):
                payload.append(0x04)
                payload.appendLE(value)
            case .string(let string):
                var bytes = Data(string.utf8)
                bytes.append(0)
                payload.append(0x09)
                payload.appendVarint(UInt64(bytes.count))
                payload.append(bytes)
            case .buffer(let bytes):
                payload.append(0x0a)
                payload.appendVarint(UInt64(bytes.count))
                payload.append(bytes)
            }
        }
        var result = Data("POMP".utf8)
        result.appendLE(id)
        result.appendLE(UInt32(headerSize + payload.count))
        result.append(payload)
        return result
    }

    static func decode(_ data: Data) -> SC2PompMessage? {
        guard data.count >= headerSize,
              data.prefix(4) == Data("POMP".utf8),
              let id = data.u32LE(at: 4),
              let total = data.u32LE(at: 8), Int(total) == data.count else { return nil }
        return SC2PompMessage(id: id, payload: Data(data.dropFirst(headerSize)))
    }
}

struct SC2PompReader {
    let data: Data
    private(set) var offset = 0

    mutating func readString() -> String? {
        guard takeByte() == 0x09, let length = readVarint(), length > 0,
              offset <= data.count, length <= UInt64(data.count - offset) else { return nil }
        let byteCount = Int(length)
        let bytes = data.subdata(in: offset..<(offset + byteCount))
        offset += byteCount
        guard bytes.last == 0 else { return nil }
        return String(data: bytes.dropLast(), encoding: .utf8)
    }

    mutating func readU32() -> UInt32? {
        guard takeByte() == 0x06, let value = readVarint(), value <= UInt64(UInt32.max) else { return nil }
        return UInt32(value)
    }

    mutating func readI32() -> Int32? {
        guard takeByte() == 0x05, let value = readVarint(), value <= UInt64(UInt32.max) else { return nil }
        let raw = UInt32(value)
        return Int32(bitPattern: (raw >> 1) ^ UInt32(bitPattern: -Int32(raw & 1)))
    }

    mutating func readU16() -> UInt16? {
        guard takeByte() == 0x04, offset + 2 <= data.count else { return nil }
        defer { offset += 2 }
        return UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    mutating func readBuffer() -> Data? {
        guard takeByte() == 0x0a, let length = readVarint(),
              offset <= data.count, length <= UInt64(data.count - offset) else { return nil }
        let byteCount = Int(length)
        defer { offset += byteCount }
        return data.subdata(in: offset..<(offset + byteCount))
    }

    private mutating func takeByte() -> UInt8? {
        guard offset < data.count else { return nil }
        defer { offset += 1 }
        return data[offset]
    }

    private mutating func readVarint() -> UInt64? {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while offset < data.count, shift < 64 {
            let byte = data[offset]
            offset += 1
            value |= UInt64(byte & 0x7f) << shift
            if byte & 0x80 == 0 { return value }
            shift += 7
        }
        return nil
    }
}

struct SC2MuxDevice: Equatable {
    let name: String
    let product: ParrotProductModel
    let identifier: String
}

enum SC2MuxSessionEvent: Equatable {
    case write(Data)
    case deviceAdded(SC2MuxDevice)
    case deviceRemoved(String)
    case connected(SC2MuxDevice, json: String)
    case connectionRejected(Int32, json: String)
    case transport(Data)
    case streamData(Data)
    case streamControl(Data)
    case rtp(port: UInt16, packet: Data, isControl: Bool)
    case channelReset(UInt32)
}

/// Deterministic libmux/ARSDK mobile-link session. A platform USB adapter only
/// has to feed bytes into `receive` and write the emitted `.write` values.
final class SC2MuxSession {
    private var decoder = SC2MuxStreamDecoder()
    private(set) var remoteProtocolVersion: UInt32?
    private(set) var selectedDevice: SC2MuxDevice?
    private let preferredProduct: ParrotProductModel?

    init(preferredProduct: ParrotProductModel? = nil) {
        self.preferredProduct = preferredProduct
    }

    func start() -> [SC2MuxSessionEvent] {
        remoteProtocolVersion = nil
        selectedDevice = nil
        decoder = SC2MuxStreamDecoder()
        return startupEvents()
    }

    private func startupEvents() -> [SC2MuxSessionEvent] {
        var events: [SC2MuxSessionEvent] = [
            .write(control(id: SC2MuxControlMessage.handshake, arguments: [0, 2]))
        ]
        for channel in SC2MuxChannel.allCases where channel != .control {
            events.append(.write(control(id: SC2MuxControlMessage.open, channel: channel.rawValue, arguments: [0])))
        }
        events.append(.write(frame(channel: .discovery, payload: SC2PompMessage.encode(id: 1))))
        return events
    }

    func disconnect() -> [SC2MuxSessionEvent] {
        var events: [SC2MuxSessionEvent] = []
        for channel in SC2MuxChannel.allCases.reversed() where channel != .control {
            events.append(.write(control(id: SC2MuxControlMessage.close, channel: channel.rawValue, arguments: [0])))
        }
        selectedDevice = nil
        return events
    }

    func sendTransport(_ packet: Data) -> SC2MuxSessionEvent {
        .write(frame(channel: .transport, payload: packet))
    }

    func sendStreamControl(_ packet: Data) -> SC2MuxSessionEvent {
        .write(frame(channel: .streamControl, payload: packet))
    }

    func receive(_ bytes: Data) -> [SC2MuxSessionEvent] {
        decoder.append(bytes).flatMap(process)
    }

    private func process(_ incoming: SC2MuxFrame) -> [SC2MuxSessionEvent] {
        guard let channel = SC2MuxChannel(rawValue: incoming.channel) else { return [] }
        switch channel {
        case .control:
            guard let message = SC2MuxControlMessage.decode(incoming.payload) else { return [] }
            if message.id == SC2MuxControlMessage.handshake {
                remoteProtocolVersion = message.arguments[1]
                return message.arguments[0] == 0
                    ? [.write(control(id: SC2MuxControlMessage.handshake, arguments: [1, 2]))]
                    : []
            }
            if message.id == SC2MuxControlMessage.reset {
                selectedDevice = nil
                return [.channelReset(0)] + startupEvents()
            }
            if message.id == SC2MuxControlMessage.close {
                if message.channel == SC2MuxChannel.transport.rawValue { selectedDevice = nil }
                guard let closed = SC2MuxChannel(rawValue: message.channel), closed != .control else {
                    return [.channelReset(message.channel)]
                }
                var events: [SC2MuxSessionEvent] = [
                    .channelReset(message.channel),
                    .write(control(id: SC2MuxControlMessage.open, channel: message.channel, arguments: [0]))
                ]
                if closed == .discovery || closed == .transport {
                    events.append(.write(frame(channel: .discovery, payload: SC2PompMessage.encode(id: 1))))
                }
                return events
            }
            return []
        case .discovery:
            return processDiscovery(incoming.payload)
        case .backend:
            return processBackend(incoming.payload)
        case .transport:
            return [.transport(incoming.payload)]
        case .streamData:
            return [.streamData(incoming.payload)]
        case .streamControl:
            return [.streamControl(incoming.payload)]
        case .rtp:
            guard let message = SC2PompMessage.decode(incoming.payload), message.id == 1 || message.id == 2 else { return [] }
            var reader = SC2PompReader(data: message.payload)
            guard let port = reader.readU16(), let packet = reader.readBuffer() else { return [] }
            return [.rtp(port: port, packet: packet, isControl: message.id == 2)]
        }
    }

    private func processDiscovery(_ payload: Data) -> [SC2MuxSessionEvent] {
        guard let message = SC2PompMessage.decode(payload), message.id == 2 || message.id == 3 else { return [] }
        var reader = SC2PompReader(data: message.payload)
        guard let name = reader.readString(), let rawProduct = reader.readU32(),
              let identifier = reader.readString() else { return [] }
        if message.id == 3 {
            if selectedDevice?.identifier == identifier { selectedDevice = nil }
            return [.deviceRemoved(identifier)]
        }
        let product = ParrotProductModel(productID: UInt16(truncatingIfNeeded: rawProduct))
        guard product != .unknown else { return [] }
        let device = SC2MuxDevice(name: name, product: product, identifier: identifier)
        var events: [SC2MuxSessionEvent] = [.deviceAdded(device)]
        let matchesPreference = preferredProduct == nil || preferredProduct == product
        if selectedDevice == nil, matchesPreference {
            selectedDevice = device
            let json = "{\"proto_v_min\":1,\"proto_v_max\":1}"
            let request = SC2PompMessage.encode(id: 1, fields: [
                .string("Parrot Lab"), .string("computer"), .string(identifier), .string(json)
            ])
            events.append(.write(frame(channel: .backend, payload: request)))
        }
        return events
    }

    private func processBackend(_ payload: Data) -> [SC2MuxSessionEvent] {
        guard let message = SC2PompMessage.decode(payload), message.id == 2,
              let device = selectedDevice else { return [] }
        var reader = SC2PompReader(data: message.payload)
        guard let status = reader.readI32(), let json = reader.readString() else { return [] }
        return status == 0 ? [.connected(device, json: json)] : [.connectionRejected(status, json: json)]
    }

    private func control(id: UInt32, channel: UInt32 = 0, arguments: [UInt32]) -> Data {
        frame(channel: .control, payload: SC2MuxControlMessage(id: id, channel: channel, arguments: arguments).encoded())
    }

    private func frame(channel: SC2MuxChannel, payload: Data) -> Data {
        SC2MuxCodec.encode(channel: channel.rawValue, payload: payload)
    }
}

enum SC2MuxSelfTest {
    static func run() -> Bool {
        var oversizedString = Data([0x09])
        oversizedString.appendVarint(UInt64(Int.max))
        var oversizedBuffer = Data([0x0a])
        oversizedBuffer.appendVarint(UInt64(Int.max))
        var stringReader = SC2PompReader(data: oversizedString)
        var bufferReader = SC2PompReader(data: oversizedBuffer)
        guard stringReader.readString() == nil, bufferReader.readBuffer() == nil else { return false }

        let payload = Data([1, 2, 3, 4])
        let encoded = SC2MuxCodec.encode(channel: SC2MuxChannel.transport.rawValue, payload: payload)
        guard encoded.prefix(4) == Data("MUX!".utf8), encoded.u32LE(at: 4) == 1,
              encoded.u32LE(at: 8) == 16 else { return false }

        var decoder = SC2MuxStreamDecoder()
        guard decoder.append(encoded.prefix(7)).isEmpty,
              decoder.append(encoded.dropFirst(7)) == [SC2MuxFrame(channel: 1, payload: payload)] else { return false }

        for (rawProduct, product) in [(UInt32(0x0901), ParrotProductModel.bebopDrone),
                                      (UInt32(0x0902), .jumpingSumo),
                                      (UInt32(0x090c), .bebop2)] {
            let productSession = SC2MuxSession(preferredProduct: product)
            _ = productSession.start()
            let discovered = SC2PompMessage.encode(id: 2, fields: [
                .string(product.shortLabel), .u32(rawProduct), .string("device-\(rawProduct)")
            ])
            let events = productSession.receive(SC2MuxCodec.encode(channel: 2, payload: discovered))
            guard productSession.selectedDevice?.product == product,
                  events.contains(where: { if case .write = $0 { return true }; return false }) else { return false }
        }

        let session = SC2MuxSession(preferredProduct: .bebop2)
        let startup = session.start()
        guard startup.count == 8 else { return false }

        let handshake = SC2MuxControlMessage(id: 127, channel: 0, arguments: [0, 2]).encoded()
        guard session.receive(SC2MuxCodec.encode(channel: 0, payload: handshake)).contains(where: {
            if case .write = $0 { return true }; return false
        }), session.remoteProtocolVersion == 2 else { return false }

        let deviceMessage = SC2PompMessage.encode(id: 2, fields: [
            .string("Bebop2-Test"), .u32(0x090c), .string("090c-test")
        ])
        let deviceEvents = session.receive(SC2MuxCodec.encode(channel: 2, payload: deviceMessage))
        guard deviceEvents.contains(.deviceAdded(SC2MuxDevice(name: "Bebop2-Test", product: .bebop2, identifier: "090c-test"))),
              deviceEvents.contains(where: { if case .write = $0 { return true }; return false }) else { return false }

        let response = SC2PompMessage.encode(id: 2, fields: [.i32(0), .string("{\"proto_v\":1}")])
        guard session.receive(SC2MuxCodec.encode(channel: 3, payload: response)).contains(
            .connected(SC2MuxDevice(name: "Bebop2-Test", product: .bebop2, identifier: "090c-test"), json: "{\"proto_v\":1}")
        ) else { return false }

        guard session.receive(SC2MuxCodec.encode(channel: 1, payload: payload)) == [.transport(payload)] else { return false }
        let rtp = SC2PompMessage.encode(id: 1, fields: [.u16(55_004), .buffer(payload)])
        guard session.receive(SC2MuxCodec.encode(channel: 6, payload: rtp)) == [
            .rtp(port: 55_004, packet: payload, isControl: false)
        ] else { return false }

        let closedTransport = SC2MuxControlMessage(id: 1, channel: 1, arguments: [0]).encoded()
        let recovery = session.receive(SC2MuxCodec.encode(channel: 0, payload: closedTransport))
        guard recovery.contains(.channelReset(1)), recovery.filter({ if case .write = $0 { return true }; return false }).count == 2,
              session.selectedDevice == nil else { return false }

        var recoveringDecoder = SC2MuxStreamDecoder()
        let damaged = Data([0xff, 0, 1, 2, 3]) + encoded
        return recoveringDecoder.append(damaged) == [SC2MuxFrame(channel: 1, payload: payload)]
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func appendVarint(_ value: UInt64) {
        var remaining = value
        repeat {
            var byte = UInt8(remaining & 0x7f)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            append(byte)
        } while remaining != 0
    }

    func u32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let base = index(startIndex, offsetBy: offset)
        return UInt32(self[base]) | UInt32(self[index(base, offsetBy: 1)]) << 8 |
            UInt32(self[index(base, offsetBy: 2)]) << 16 |
            UInt32(self[index(base, offsetBy: 3)]) << 24
    }
}
