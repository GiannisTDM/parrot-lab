import Foundation

/// Public libmux v2 and ARSDK-ng MUX backend subset. The byte adapter is
/// deliberately separate: a USB/accessory bridge must provide raw MUX! bytes.
struct SC3MuxControl {
    let id: UInt32
    let channel: UInt32
    let args: [UInt32]
    let extra: Data
    init(_ id: UInt32, channel: UInt32 = 0, args: [UInt32] = [], extra: Data = Data()) {
        self.id = id; self.channel = channel; self.args = args; self.extra = extra
    }
    var packet: Data {
        var data = Data(); data.appendAnafiLE(id); data.appendAnafiLE(channel)
        for index in 0..<6 { data.appendAnafiLE(index < args.count ? args[index] : 0) }
        data.append(extra)
        return SC2MuxCodec.encode(channel: 0, payload: data)
    }
    static func decode(_ data: Data) -> Self? {
        var reader = AnafiWireReader(data)
        guard let id = reader.integer(UInt32.self), let channel = reader.integer(UInt32.self) else { return nil }
        var args: [UInt32] = []
        for _ in 0..<6 { guard let value = reader.integer(UInt32.self) else { return nil }; args.append(value) }
        return Self(id, channel: channel, args: args, extra: Data(data.dropFirst(32)))
    }
}

enum SC3MuxEvent: Equatable {
    case write(Data), connected, transport(Data), videoResolved, videoConnected, videoData(Data), videoWritable
    case videoClosed(String), failed(String)
}

final class SC3MuxProtocol {
    private var decoder = SC2MuxStreamDecoder()
    private var identifier: String?
    private(set) var connected = false
    private(set) var videoAddress: UInt32?
    private(set) var videoChannel: UInt32?
    private(set) var videoConnected = false
    private(set) var videoWaitingACK = false
    private var videoBytesSent = 0
    private var nextID: UInt32 = 1024
    private var proxyID: UInt32?

    func start() -> [SC3MuxEvent] {
        [.write(SC3MuxControl(127, args: [0, 2]).packet)] +
        [UInt32(1), 2, 3].map { .write(SC3MuxControl(0, channel: $0).packet) } +
        [.write(SC2MuxCodec.encode(channel: 2, payload: SC2PompMessage.encode(id: 1)))]
    }
    func sendTransport(_ packet: Data) -> Data { SC2MuxCodec.encode(channel: 1, payload: packet) }
    func requestVideo() -> [SC3MuxEvent] {
        let old = closeVideo()
        nextID &+= 1; proxyID = nextID
        return old + [.write(SC3MuxControl(9, args: [nextID, 0, 0, 554], extra: Data("drone\0".utf8)).packet)]
    }
    func connectVideo() -> [SC3MuxEvent] {
        guard let address = videoAddress, videoChannel == nil else { return [] }
        nextID &+= 1; videoChannel = nextID
        return [.write(SC3MuxControl(0, channel: nextID, args: [1]).packet),
                .write(SC3MuxControl(13, channel: nextID, args: [0, 0, address, 554]).packet)]
    }
    func sendVideo(_ bytes: Data) -> [SC3MuxEvent] {
        guard let channel = videoChannel, videoConnected, !videoWaitingACK else { return [] }
        var result: [SC3MuxEvent] = [.write(SC2MuxCodec.encode(channel: channel, payload: bytes))]
        videoBytesSent += bytes.count
        if videoBytesSent >= 1_048_576 {
            videoWaitingACK = true; result.append(.write(SC3MuxControl(17, channel: channel).packet))
        }
        return result
    }
    func closeVideo() -> [SC3MuxEvent] {
        defer {
            videoChannel = nil; videoAddress = nil; proxyID = nil
            videoConnected = false; videoWaitingACK = false; videoBytesSent = 0
        }
        guard let channel = videoChannel else { return [] }
        return [.write(SC3MuxControl(14, channel: channel).packet),
                .write(SC3MuxControl(1, channel: channel, args: [1]).packet)]
    }
    func disconnect() -> [SC3MuxEvent] {
        connected = false
        return closeVideo() + [UInt32(3), 2, 1].map { .write(SC3MuxControl(1, channel: $0).packet) }
    }
    func receive(_ bytes: Data) -> [SC3MuxEvent] { decoder.append(bytes).flatMap(consume) }
    private func consume(_ frame: SC2MuxFrame) -> [SC3MuxEvent] {
        if let channel = videoChannel, frame.channel == channel | 0x8000_0000, videoConnected {
            return [.videoData(frame.payload)]
        }
        switch frame.channel {
        case 0:
            guard let control = SC3MuxControl.decode(frame.payload) else { return [] }
            switch control.id {
            case 127:
                guard control.args[1] >= 2 else { return [.failed("SC3 bridge requires libmux protocol 2 for video")] }
                return control.args[0] == 0 ? [.write(SC3MuxControl(127, args: [1, 2]).packet)] : []
            case 6: return [.failed("SC3 reset the USB session; reconnect")]
            case 1:
                if [UInt32(1), 2, 3].contains(control.channel) { return [.failed("SC3 closed an ARSDK channel; reconnect")] }
                if control.channel & 0x7fff_ffff == videoChannel { return [.videoClosed("SC3 closed the video channel")] }
            case 10:
                guard control.args[0] == proxyID, control.args[1] == 0, control.args[2] == 0,
                      control.extra == Data("drone\0".utf8), control.args[4] == 554 else { return [] }
                guard control.args[3] != 0, control.args[3] != UInt32.max else { return [.videoClosed("SC3 has no aircraft video endpoint")] }
                videoAddress = control.args[3]; return [.videoResolved]
            case 15:
                guard let channel = videoChannel, control.channel == channel | 0x8000_0000 else { return [] }
                videoConnected = true; return [.videoConnected]
            case 16:
                guard let channel = videoChannel, control.channel == channel | 0x8000_0000 else { return [] }
                videoConnected = false; return [.videoClosed("SC3 aircraft video disconnected")]
            case 18:
                guard let channel = videoChannel, control.channel == channel | 0x8000_0000, videoWaitingACK else { return [] }
                videoWaitingACK = false; videoBytesSent = 0; return [.videoWritable]
            default: break
            }
        case 2:
            guard let message = SC2PompMessage.decode(frame.payload), message.id == 2 || message.id == 3 else { return [] }
            var reader = SC2PompReader(data: message.payload)
            guard reader.readString() != nil, let product = reader.readU32(), let id = reader.readString() else { return [] }
            if message.id == 3 { return id == identifier ? [.failed("SC3 USB device removed")] : [] }
            // Select the remote controller. It forwards drone commands and
            // reports drone_manager/CoPilotingState under the same session.
            guard product == 0x0918, identifier == nil else { return [] }
            identifier = id
            let request = SC2PompMessage.encode(id: 1, fields: [.string("Parrot Lab"), .string("computer"),
                .string(id), .string("{\"proto_v_min\":1,\"proto_v_max\":1}")])
            return [.write(SC2MuxCodec.encode(channel: 3, payload: request))]
        case 3:
            guard identifier != nil, !connected, let message = SC2PompMessage.decode(frame.payload), message.id == 2 else { return [] }
            var reader = SC2PompReader(data: message.payload)
            guard let status = reader.readI32(), let json = reader.readString(), let data = json.data(using: .utf8),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
            guard status == 0, (object["proto_v"] as? Int ?? 1) == 1 else {
                return [.failed("SC3 rejected the USB connection or selected unsupported ARSDK framing")]
            }
            connected = true; return [.connected]
        case 1: return connected ? [.transport(frame.payload)] : []
        default: break
        }
        return []
    }
}
