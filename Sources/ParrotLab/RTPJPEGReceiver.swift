import Foundation

enum RTPJPEGWireFormat: String, Equatable {
    case unknown = "UNKNOWN"
    case rfc2435 = "RFC2435"
    case forwardedARStream1 = "ARSTREAM1-FORWARDED"
    case jpegBoundaries = "JPEG-BOUNDARIES"
}

struct RTPJPEGStats: Equatable {
    var packets: UInt64 = 0
    var packetsLost: UInt64 = 0
    var frames: UInt64 = 0
    var receiveRate: Double = 0
    var frameRate: Double = 0
    var wireFormat: RTPJPEGWireFormat = .unknown
    var incompleteFrames: UInt64 = 0
    var lastFrameID: UInt64?
    var lastAssembledJPEGBytes: Int?
}

/// Strict JPEG restream receiver. It classifies the SC2 wire format from RTP
/// headers and payload structure before any bytes are submitted to ImageIO.
final class RTPJPEGReceiver {
    var onFrame: ((Data, UInt64) -> Void)?
    var onStats: ((RTPJPEGStats) -> Void)?
    var onDebug: ((String) -> Void)?

    private let queue = DispatchQueue(label: "parrotlab.rtp-jpeg", qos: .userInteractive)
    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var payloadType: UInt8 = 96
    private var wireFormat = RTPJPEGWireFormat.unknown
    private var rfc2435 = RFC2435JPEGAssembler()
    private var arstream1 = ARStream1VideoAssembler()
    private var boundedJPEG = BoundedRTPJPEGAssembler()
    private var previousSequence: UInt16?
    private var stats = RTPJPEGStats()
    private var packetsInWindow: UInt64 = 0
    private var framesInWindow: UInt64 = 0
    private var windowStarted = Date()
    private var unidentifiedPackets = 0
    private var assemblingTimestamp: UInt32?
    private var assemblingFrameCompleted = false
    private var lastDiagnosticLog = Date.distantPast

    func start(port: UInt16, payloadType: UInt8 = 96) throws {
        stop()
        self.payloadType = payloadType
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw socketError("Could not open JPEG/RTP UDP socket") }
        socketFD = fd

        var reuse: Int32 = 1
        _ = withUnsafePointer(to: &reuse) {
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, $0, socklen_t(MemoryLayout<Int32>.size))
        }

        var requestedReceiveBytes: Int32 = 4 * 1_024 * 1_024
        if withUnsafePointer(to: &requestedReceiveBytes, {
            setsockopt(fd, SOL_SOCKET, SO_RCVBUF, $0, socklen_t(MemoryLayout<Int32>.size))
        }) != 0 {
            requestedReceiveBytes = 1_024 * 1_024
            _ = withUnsafePointer(to: &requestedReceiveBytes) {
                setsockopt(fd, SOL_SOCKET, SO_RCVBUF, $0, socklen_t(MemoryLayout<Int32>.size))
            }
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = in_addr_t(INADDR_ANY)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            socketFD = -1
            throw socketError("Could not bind JPEG/RTP UDP \(port)")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var actualReceiveBytes: Int32 = 0
        var optionLength = socklen_t(MemoryLayout<Int32>.size)
        _ = withUnsafeMutablePointer(to: &actualReceiveBytes) {
            getsockopt(fd, SOL_SOCKET, SO_RCVBUF, $0, &optionLength)
        }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receiveDatagrams() }
        source.setCancelHandler { Darwin.close(fd) }
        readSource = source
        source.resume()
        resetAssemblers()
        debug("Listening for SC2 JPEG/RTP on UDP \(port) · payload type \(payloadType) · RX buffer \(actualReceiveBytes) bytes")
    }

    func stop() {
        if let source = readSource {
            source.cancel()
            readSource = nil
        } else if socketFD >= 0 {
            Darwin.close(socketFD)
        }
        socketFD = -1
        resetAssemblers()
        stats = RTPJPEGStats()
        packetsInWindow = 0
        framesInWindow = 0
        windowStarted = Date()
    }

    private func resetAssemblers() {
        wireFormat = .unknown
        rfc2435.reset()
        arstream1.configure(fragmentSize: nil, maximumFragments: 128)
        boundedJPEG.reset()
        previousSequence = nil
        unidentifiedPackets = 0
        assemblingTimestamp = nil
        assemblingFrameCompleted = false
        lastDiagnosticLog = .distantPast
    }

    private func receiveDatagrams() {
        guard socketFD >= 0 else { return }
        var bytes = [UInt8](repeating: 0, count: 65_535)
        while true {
            let count = Darwin.recv(socketFD, &bytes, bytes.count, MSG_DONTWAIT)
            if count > 0 {
                consume(Data(bytes.prefix(count)))
                continue
            }
            if count < 0, errno != EAGAIN, errno != EWOULDBLOCK {
                debug("JPEG/RTP receive error: \(String(cString: strerror(errno)))")
            }
            break
        }
    }

    private func socketError(_ prefix: String) -> NSError {
        NSError(
            domain: "ParrotLab.RTPJPEG",
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(prefix): \(String(cString: strerror(errno)))"]
        )
    }

    private func consume(_ data: Data) {
        guard let packet = RTPPacket(data: data), packet.payloadType == payloadType else {
            if unidentifiedPackets < 4 {
                unidentifiedPackets += 1
                debug("SC2 JPEG probe rejected non-RTP or unexpected payload-type datagram · \(data.count) bytes")
            }
            return
        }
        stats.packets &+= 1
        packetsInWindow &+= 1
        if let previousSequence {
            let expected = previousSequence &+ 1
            if packet.sequence != expected {
                let gap = packet.sequence &- expected
                if gap < 0x8000 { stats.packetsLost &+= UInt64(gap) }
            }
        }
        previousSequence = packet.sequence

        if assemblingTimestamp != packet.timestamp {
            if assemblingTimestamp != nil, !assemblingFrameCompleted {
                stats.incompleteFrames &+= 1
            }
            assemblingTimestamp = packet.timestamp
            assemblingFrameCompleted = false
        }

        if wireFormat == .unknown {
            wireFormat = Self.classify(packet.payload)
            unidentifiedPackets += 1
            let prefix = packet.payload.prefix(12).map { String(format: "%02X", $0) }.joined(separator: " ")
            let soi = packet.payload.starts(with: [0xff, 0xd8])
            let eoi = packet.payload.suffix(2) == Data([0xff, 0xd9])
            debug("SC2 JPEG packet #\(unidentifiedPackets) · RTP seq \(packet.sequence) ts \(packet.timestamp) marker \(packet.marker ? 1 : 0) · payload \(packet.payload.count) · SOI \(soi ? 1 : 0) EOI \(eoi ? 1 : 0) · \(prefix)")
            if wireFormat != .unknown {
                stats.wireFormat = wireFormat
                debug("SC2 JPEG restream identified as \(wireFormat.rawValue)")
            } else {
                publishStatsIfNeeded()
                return
            }
        }

        var completed: Data?
        var completedFrameID = UInt64(packet.timestamp)
        switch wireFormat {
        case .rfc2435:
            completed = rfc2435.consume(packet)
        case .forwardedARStream1:
            if let frame = arstream1.consume(packet.payload)?.frame {
                completed = ARStream1VideoAssembler.jpegPayload(in: frame.payload)
                completedFrameID = frame.frameNumber
            }
        case .jpegBoundaries:
            completed = boundedJPEG.consume(packet)
        case .unknown:
            break
        }
        if let completed, ARStream1VideoAssembler.jpegPayload(in: completed) != nil {
            assemblingFrameCompleted = true
            stats.frames &+= 1
            framesInWindow &+= 1
            stats.lastFrameID = completedFrameID
            stats.lastAssembledJPEGBytes = completed.count
            DispatchQueue.main.async { [weak self] in self?.onFrame?(completed, completedFrameID) }
        }
        publishStatsIfNeeded()
    }

    private func publishStatsIfNeeded() {
        let elapsed = Date().timeIntervalSince(windowStarted)
        guard elapsed >= 1 else { return }
        stats.receiveRate = Double(packetsInWindow) / elapsed
        stats.frameRate = Double(framesInWindow) / elapsed
        stats.wireFormat = wireFormat
        packetsInWindow = 0
        framesInWindow = 0
        windowStarted = Date()
        let snapshot = stats
        DispatchQueue.main.async { [weak self] in self?.onStats?(snapshot) }
        if Date().timeIntervalSince(lastDiagnosticLog) >= 5 {
            lastDiagnosticLog = Date()
            debug(
                String(
                    format: "SC2 JPEG RX %.1f pkt/s · decoded %.1f fps · frame %@ · JPEG %@ bytes · lost %llu · incomplete %llu · %@",
                    stats.receiveRate,
                    stats.frameRate,
                    stats.lastFrameID.map(String.init) ?? "—",
                    stats.lastAssembledJPEGBytes.map(String.init) ?? "—",
                    stats.packetsLost,
                    stats.incompleteFrames,
                    stats.wireFormat.rawValue
                )
            )
        }
    }

    static func classify(_ payload: Data) -> RTPJPEGWireFormat {
        if payload.count >= 5,
           payload[3] == 0,
           (1...128).contains(Int(payload[4])),
           payload.count >= 7,
           payload[5] == 0xff, payload[6] == 0xd8 {
            return .forwardedARStream1
        }
        if payload.count >= 8 {
            let offset = Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
            let jpegType = Int(payload[4] & 0x3f)
            if offset == 0, jpegType <= 1, payload[6] != 0, payload[7] != 0 {
                return .rfc2435
            }
        }
        if payload.starts(with: [0xff, 0xd8]) { return .jpegBoundaries }
        return .unknown
    }

    static func selfTest() -> Bool {
        let raw = Data([0xff, 0xd8, 1, 2, 0xff, 0xd9])
        let rfc = Data([0, 0, 0, 0, 1, 70, 80, 60, 1, 2])
        let forwarded = Data([7, 0, 0, 0, 2, 0xff, 0xd8])
        guard classify(raw) == .jpegBoundaries,
              classify(rfc) == .rfc2435,
              classify(forwarded) == .forwardedARStream1,
              classify(Data([1, 2, 3])) == .unknown else { return false }

        var rawAssembler = BoundedRTPJPEGAssembler()
        guard let rawPacket = RTPPacket(data: testPacket(sequence: 1, timestamp: 90_000, marker: true, payload: raw)),
              rawAssembler.consume(rawPacket) == raw else { return false }

        var rfcAssembler = RFC2435JPEGAssembler()
        guard let rfcPacket = RTPPacket(data: testPacket(sequence: 2, timestamp: 180_000, marker: true, payload: rfc)),
              let jpeg = rfcAssembler.consume(rfcPacket),
              jpeg.starts(with: [0xff, 0xd8]), jpeg.suffix(2) == Data([0xff, 0xd9]) else { return false }
        return true
    }

    private static func testPacket(sequence: UInt16, timestamp: UInt32, marker: Bool, payload: Data) -> Data {
        var data = Data([
            0x80, marker ? 0xe0 : 0x60,
            UInt8(truncatingIfNeeded: sequence >> 8), UInt8(truncatingIfNeeded: sequence),
            UInt8(truncatingIfNeeded: timestamp >> 24), UInt8(truncatingIfNeeded: timestamp >> 16),
            UInt8(truncatingIfNeeded: timestamp >> 8), UInt8(truncatingIfNeeded: timestamp),
            0, 0, 0, 1
        ])
        data.append(payload)
        return data
    }

    private func debug(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onDebug?(message) }
    }
}

private struct BoundedRTPJPEGAssembler {
    private var timestamp: UInt32?
    private var expectedSequence: UInt16?
    private var bytes = Data()
    private var valid = false

    mutating func reset() {
        timestamp = nil
        expectedSequence = nil
        bytes.removeAll(keepingCapacity: false)
        valid = false
    }

    mutating func consume(_ packet: RTPPacket) -> Data? {
        if timestamp != packet.timestamp {
            reset()
            timestamp = packet.timestamp
            valid = packet.payload.starts(with: [0xff, 0xd8])
        }
        if let expectedSequence, expectedSequence != packet.sequence { valid = false }
        expectedSequence = packet.sequence &+ 1
        guard valid, bytes.count + packet.payload.count <= 8 * 1_024 * 1_024 else { return nil }
        bytes.append(packet.payload)
        guard packet.marker else { return nil }
        defer { reset() }
        return ARStream1VideoAssembler.jpegPayload(in: bytes)
    }
}

private struct RFC2435JPEGAssembler {
    private struct Parameters {
        let type: UInt8
        let quality: UInt8
        let width: Int
        let height: Int
        let restartInterval: UInt16?
        let quantizationTables: Data?
    }

    private var timestamp: UInt32?
    private var parameters: Parameters?
    private var fragments: [Int: Data] = [:]
    private var expectedSize: Int?

    mutating func reset() {
        timestamp = nil
        parameters = nil
        fragments.removeAll(keepingCapacity: false)
        expectedSize = nil
    }

    mutating func consume(_ packet: RTPPacket) -> Data? {
        if timestamp != packet.timestamp {
            reset()
            timestamp = packet.timestamp
        }
        guard let fragment = parse(packet.payload) else { return nil }
        if fragment.offset == 0 { parameters = fragment.parameters }
        guard fragments[fragment.offset] == nil else { return nil }
        fragments[fragment.offset] = fragment.scan
        if packet.marker { expectedSize = fragment.offset + fragment.scan.count }
        guard let expectedSize, let parameters else { return nil }
        var offset = 0
        var scan = Data()
        scan.reserveCapacity(expectedSize)
        while offset < expectedSize {
            guard let part = fragments[offset] else { return nil }
            scan.append(part)
            offset += part.count
        }
        guard offset == expectedSize else { return nil }
        let jpeg = Self.makeJPEG(parameters: parameters, scan: scan)
        reset()
        return jpeg
    }

    private func parse(_ payload: Data) -> (offset: Int, scan: Data, parameters: Parameters?)? {
        guard payload.count >= 8 else { return nil }
        let offset = Int(payload[1]) << 16 | Int(payload[2]) << 8 | Int(payload[3])
        let type = payload[4]
        let baseType = type & 0x3f
        guard baseType <= 1 else { return nil }
        let quality = payload[5]
        let width = (payload[6] == 0 ? 256 : Int(payload[6])) * 8
        let height = (payload[7] == 0 ? 256 : Int(payload[7])) * 8
        var cursor = 8
        var restartInterval: UInt16?
        if type >= 64 {
            guard payload.count >= cursor + 4 else { return nil }
            restartInterval = UInt16(payload[cursor]) << 8 | UInt16(payload[cursor + 1])
            cursor += 4
        }
        var tables: Data?
        if quality >= 128, offset == 0 {
            guard payload.count >= cursor + 4, payload[cursor] == 0, payload[cursor + 1] == 0 else { return nil }
            let length = Int(payload[cursor + 2]) << 8 | Int(payload[cursor + 3])
            cursor += 4
            guard (length == 64 || length == 128), payload.count >= cursor + length else { return nil }
            tables = payload.subdata(in: cursor..<(cursor + length))
            cursor += length
        }
        guard cursor < payload.count else { return nil }
        let params = offset == 0 ? Parameters(
            type: baseType,
            quality: quality,
            width: width,
            height: height,
            restartInterval: restartInterval,
            quantizationTables: tables
        ) : nil
        return (offset, Data(payload.dropFirst(cursor)), params)
    }

    private static func makeJPEG(parameters: Parameters, scan: Data) -> Data {
        let tables: (Data, Data)
        if let supplied = parameters.quantizationTables {
            let luma = Data(supplied.prefix(64))
            tables = (luma, supplied.count >= 128 ? Data(supplied.dropFirst(64).prefix(64)) : luma)
        } else {
            tables = quantizationTables(quality: Int(parameters.quality))
        }
        var jpeg = Data([0xff, 0xd8])
        appendDQT(tables.0, id: 0, to: &jpeg)
        appendDQT(tables.1, id: 1, to: &jpeg)
        if let interval = parameters.restartInterval, interval > 0 {
            jpeg.append(contentsOf: [
                0xff, 0xdd, 0, 4,
                UInt8(truncatingIfNeeded: interval >> 8), UInt8(truncatingIfNeeded: interval)
            ])
        }
        jpeg.append(contentsOf: [
            0xff, 0xc0, 0, 17, 8,
            UInt8(truncatingIfNeeded: parameters.height >> 8), UInt8(truncatingIfNeeded: parameters.height),
            UInt8(truncatingIfNeeded: parameters.width >> 8), UInt8(truncatingIfNeeded: parameters.width),
            3,
            1, parameters.type == 0 ? 0x21 : 0x22, 0,
            2, 0x11, 1,
            3, 0x11, 1
        ])
        appendStandardHuffmanTables(to: &jpeg)
        jpeg.append(contentsOf: [
            0xff, 0xda, 0, 12, 3,
            1, 0x00, 2, 0x11, 3, 0x11,
            0, 63, 0
        ])
        jpeg.append(scan)
        if !jpeg.suffix(2).elementsEqual([0xff, 0xd9]) { jpeg.append(contentsOf: [0xff, 0xd9]) }
        return jpeg
    }

    private static func appendDQT(_ table: Data, id: UInt8, to jpeg: inout Data) {
        jpeg.append(contentsOf: [0xff, 0xdb, 0, 67, id])
        jpeg.append(table.prefix(64))
    }

    private static func quantizationTables(quality: Int) -> (Data, Data) {
        let luma = [16,11,12,14,12,10,16,14,13,14,18,17,16,19,24,40,26,24,22,22,24,49,35,37,29,40,58,51,61,60,57,51,56,55,64,72,92,78,64,68,87,69,55,56,80,109,81,87,95,98,103,104,103,62,77,113,121,112,100,120,92,101,103,99]
        let chroma = [17,18,18,24,21,24,47,26,26,47,99,66,56,66,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99]
        let q = min(99, max(1, quality))
        let scale = q < 50 ? 5_000 / q : 200 - q * 2
        func scaled(_ values: [Int]) -> Data {
            Data(values.map { UInt8(min(255, max(1, ($0 * scale + 50) / 100))) })
        }
        return (scaled(luma), scaled(chroma))
    }

    private static func appendStandardHuffmanTables(to jpeg: inout Data) {
        appendDHT(id: 0x00, bits: [0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0], values: Array(0...11), to: &jpeg)
        appendDHT(id: 0x10, bits: [0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d], values: luminanceAC, to: &jpeg)
        appendDHT(id: 0x01, bits: [0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0], values: Array(0...11), to: &jpeg)
        appendDHT(id: 0x11, bits: [0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77], values: chrominanceAC, to: &jpeg)
    }

    private static func appendDHT(id: UInt8, bits: [UInt8], values: [UInt8], to jpeg: inout Data) {
        let length = 2 + 1 + bits.count + values.count
        jpeg.append(contentsOf: [0xff, 0xc4, UInt8(length >> 8), UInt8(length), id])
        jpeg.append(contentsOf: bits)
        jpeg.append(contentsOf: values)
    }

    private static let luminanceAC: [UInt8] = [
        0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa
    ]
    private static let chrominanceAC: [UInt8] = [
        0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,0x52,0xf0,0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,0xe1,0x25,0xf1,0x17,0x18,0x19,0x1a,0x26,0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x82,0x83,0x84,0x85,0x86,0x87,0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,0xf9,0xfa
    ]
}
