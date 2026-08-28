import Foundation
import Network

struct RTPVideoStats: Equatable {
    var packets: UInt64 = 0
    var duplicatePackets: UInt64 = 0
    var packetsLost: UInt64 = 0
    var bitrateKbps: Int = 0
    var encodedAUFPS: Double = 0
    var uniqueTimestampFPS: Double = 0
    var jitterMs: Double = 0
}

struct H264AccessUnit: Equatable {
    let nalUnits: [Data]
    let rtpTimestamp: UInt32
    let rtpHeaderExtensions: [Data]
    let videoMetadata: VideoMetadataV2?

    init(
        nalUnits: [Data],
        rtpTimestamp: UInt32,
        rtpHeaderExtensions: [Data],
        videoMetadata: VideoMetadataV2? = nil
    ) {
        self.nalUnits = nalUnits
        self.rtpTimestamp = rtpTimestamp
        self.rtpHeaderExtensions = rtpHeaderExtensions
        self.videoMetadata = videoMetadata
    }
}

final class RTPH264Receiver {
    var onAccessUnit: ((H264AccessUnit) -> Void)?
    /// Called on the receiver queue for every completed access unit, before the
    /// live-preview path coalesces frames under UI pressure.
    var onCompleteAccessUnit: ((H264AccessUnit) -> Void)?
    var onStats: ((RTPVideoStats) -> Void)?
    var onDebug: ((String) -> Void)?

    private let queue = DispatchQueue(label: "parrotlab.rtp-h264")
    private let deliveryLock = NSLock()
    private var listener: NWListener?
    private var senderConnection: NWConnection?
    private var assembler = H264RTPAssembler()
    private var stats = RTPVideoStats()
    private var previousSequence: UInt16?
    private var recentSequences = Set<UInt16>()
    private var recentSequenceOrder: [UInt16] = []
    private var recentSequenceHead = 0
    private var lastCompletedTimestamp: UInt32?
    private var previousTransit: Double?
    private var jitterSeconds = 0.0
    private var bytesInWindow = 0
    private var completedAUTimestampsInWindow = Set<UInt32>()
    private var vclTimestampsInWindow = Set<UInt32>()
    private var windowStarted = Date()
    private var pendingAccessUnit: H264AccessUnit?
    private var accessUnitDeliveryScheduled = false

    func start(port: UInt16) throws {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "ParrotLab.RTP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid UDP port"])
        }
        let listener = try NWListener(using: .udp, on: endpointPort)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.debug("Listening for H.264/RTP on UDP \(port)")
            case .failed(let error): self?.debug("RTP listener failed: \(error.localizedDescription)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.senderConnection?.cancel()
            self.senderConnection = connection
            self.assembler.reset()
            self.previousSequence = nil
            self.recentSequences.removeAll(keepingCapacity: true)
            self.recentSequenceOrder.removeAll(keepingCapacity: true)
            self.recentSequenceHead = 0
            self.lastCompletedTimestamp = nil
            self.debug("RTP sender connected: \(connection.endpoint)")
            connection.start(queue: self.queue)
            self.receive(on: connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        senderConnection?.cancel()
        senderConnection = nil
        assembler.reset()
        stats = RTPVideoStats()
        previousSequence = nil
        recentSequences.removeAll(keepingCapacity: false)
        recentSequenceOrder.removeAll(keepingCapacity: false)
        recentSequenceHead = 0
        lastCompletedTimestamp = nil
        previousTransit = nil
        jitterSeconds = 0
        bytesInWindow = 0
        completedAUTimestampsInWindow.removeAll(keepingCapacity: false)
        vclTimestampsInWindow.removeAll(keepingCapacity: false)
        windowStarted = Date()
        deliveryLock.lock()
        pendingAccessUnit = nil
        deliveryLock.unlock()
    }

    private func receive(on connection: NWConnection) {
        connection.receiveMessage { [weak self, weak connection] data, _, _, error in
            guard let self, let connection, self.senderConnection === connection else { return }
            if let data { self.consume(packetData: data) }
            if let error {
                self.debug("RTP receive error: \(error.localizedDescription)")
                return
            }
            self.receive(on: connection)
        }
    }

    private func consume(packetData: Data) {
        guard let packet = RTPPacket(data: packetData), packet.payloadType == 96 else { return }
        stats.packets += 1
        bytesInWindow += packetData.count
        guard remember(sequence: packet.sequence) else {
            stats.duplicatePackets += 1
            return
        }
        if Self.payloadContainsVCL(packet.payload) {
            vclTimestampsInWindow.insert(packet.timestamp)
        }

        if let previousSequence {
            let expected = previousSequence &+ 1
            if packet.sequence != expected {
                let forwardGap = packet.sequence &- expected
                if forwardGap < 0x8000 { stats.packetsLost += UInt64(forwardGap) }
            }
        }
        previousSequence = packet.sequence

        let arrival = Date().timeIntervalSince1970
        let transit = arrival - Double(packet.timestamp) / 90_000.0
        if let previousTransit {
            let delta = abs(transit - previousTransit)
            jitterSeconds += (delta - jitterSeconds) / 16.0
        }
        previousTransit = transit
        stats.jitterMs = jitterSeconds * 1_000.0

        for accessUnit in assembler.consume(packet: packet) {
            // ARStream2 may retransmit a completed timestamp after its marker
            // packet. Never submit the same coded picture twice.
            guard accessUnit.rtpTimestamp != lastCompletedTimestamp else { continue }
            lastCompletedTimestamp = accessUnit.rtpTimestamp
            if accessUnit.nalUnits.contains(where: { nalUnit in
                guard let firstByte = nalUnit.first else { return false }
                return (1...5).contains(Int(firstByte & 0x1f))
            }) {
                completedAUTimestampsInWindow.insert(accessUnit.rtpTimestamp)
            }
            onCompleteAccessUnit?(accessUnit)
            enqueueLatestAccessUnit(accessUnit)
        }

        let elapsed = Date().timeIntervalSince(windowStarted)
        if elapsed >= 1.0 {
            stats.bitrateKbps = Int((Double(bytesInWindow) * 8.0 / 1_000.0 / elapsed).rounded())
            stats.encodedAUFPS = Double(completedAUTimestampsInWindow.count) / elapsed
            stats.uniqueTimestampFPS = Double(vclTimestampsInWindow.count) / elapsed
            bytesInWindow = 0
            completedAUTimestampsInWindow.removeAll(keepingCapacity: true)
            vclTimestampsInWindow.removeAll(keepingCapacity: true)
            windowStarted = Date()
            let current = stats
            DispatchQueue.main.async { [weak self] in self?.onStats?(current) }
        }
    }

    private func remember(sequence: UInt16) -> Bool {
        guard recentSequences.insert(sequence).inserted else { return false }
        recentSequenceOrder.append(sequence)
        let maximumRememberedSequences = 4_096
        if recentSequenceOrder.count - recentSequenceHead > maximumRememberedSequences {
            recentSequences.remove(recentSequenceOrder[recentSequenceHead])
            recentSequenceHead += 1
            if recentSequenceHead >= maximumRememberedSequences {
                recentSequenceOrder.removeFirst(recentSequenceHead)
                recentSequenceHead = 0
            }
        }
        return true
    }

    private func debug(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onDebug?(message) }
    }

    private static func payloadContainsVCL(_ payload: Data) -> Bool {
        guard let firstByte = payload.first else { return false }
        let nalType = Int(firstByte & 0x1f)
        if (1...5).contains(nalType) { return true }

        let bytes = [UInt8](payload)
        if nalType == 28, bytes.count >= 2 { // FU-A
            return (1...5).contains(Int(bytes[1] & 0x1f))
        }
        if nalType == 24 { // STAP-A
            var offset = 1
            while offset + 2 <= bytes.count {
                let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
                offset += 2
                guard length > 0, offset + length <= bytes.count else { return false }
                if (1...5).contains(Int(bytes[offset] & 0x1f)) { return true }
                offset += length
            }
        }
        return false
    }

    // A live view should never accumulate stale compressed frames while the UI
    // thread is busy. Keep the newest complete access unit and let cyclic intra
    // refresh repair any frame skipped under pressure.
    private func enqueueLatestAccessUnit(_ accessUnit: H264AccessUnit) {
        deliveryLock.lock()
        pendingAccessUnit = accessUnit
        let shouldSchedule = !accessUnitDeliveryScheduled
        if shouldSchedule { accessUnitDeliveryScheduled = true }
        deliveryLock.unlock()

        if shouldSchedule {
            DispatchQueue.main.async { [weak self] in self?.deliverLatestAccessUnit() }
        }
    }

    private func deliverLatestAccessUnit() {
        deliveryLock.lock()
        let accessUnit = pendingAccessUnit
        pendingAccessUnit = nil
        deliveryLock.unlock()

        if let accessUnit { onAccessUnit?(accessUnit) }

        deliveryLock.lock()
        let shouldContinue = pendingAccessUnit != nil
        if !shouldContinue { accessUnitDeliveryScheduled = false }
        deliveryLock.unlock()
        if shouldContinue {
            DispatchQueue.main.async { [weak self] in self?.deliverLatestAccessUnit() }
        }
    }

    static func assemblySelfTest() -> Bool {
        guard payloadContainsVCL(Data([0x61, 0x01])),
              !payloadContainsVCL(Data([0x06, 0x05])),
              payloadContainsVCL(Data([0x7c, 0x81, 0xaa])),
              payloadContainsVCL(Data([0x78, 0x00, 0x01, 0x06, 0x00, 0x01, 0x61])) else {
            return false
        }
        var assembler = H264RTPAssembler()
        guard let single = RTPPacket(data: makeTestPacket(sequence: 1, timestamp: 90_000, marker: true, payload: Data([0x65, 0x11, 0x22]))),
              assembler.consume(packet: single) == [H264AccessUnit(
                nalUnits: [Data([0x65, 0x11, 0x22])],
                rtpTimestamp: 90_000,
                rtpHeaderExtensions: []
              )] else { return false }

        guard let start = RTPPacket(data: makeTestPacket(sequence: 2, timestamp: 180_000, marker: false, payload: Data([0x7c, 0x85, 0xaa, 0xbb]))),
              let end = RTPPacket(data: makeTestPacket(sequence: 3, timestamp: 180_000, marker: true, payload: Data([0x7c, 0x45, 0xcc]))) else { return false }
        guard assembler.consume(packet: start).isEmpty,
              assembler.consume(packet: end).first?.nalUnits == [Data([0x65, 0xaa, 0xbb, 0xcc])] else { return false }

        // ARStream2 restreams may omit the RTP marker bit. In that case a
        // timestamp transition must close the preceding access unit.
        guard let unmarked = RTPPacket(data: makeTestPacket(sequence: 4, timestamp: 270_000, marker: false, payload: Data([0x61, 0x33]))),
              let nextFrame = RTPPacket(data: makeTestPacket(sequence: 5, timestamp: 273_000, marker: false, payload: Data([0x61, 0x44]))) else { return false }
        guard assembler.consume(packet: unmarked).isEmpty,
              assembler.consume(packet: nextFrame).first == H264AccessUnit(
                nalUnits: [Data([0x61, 0x33])],
                rtpTimestamp: 270_000,
                rtpHeaderExtensions: []
              ) else { return false }

        assembler.reset()
        let extensionPayload = Data([0xaa, 0xbb, 0xcc, 0xdd])
        guard let extended = RTPPacket(data: makeTestPacket(
            sequence: 6,
            timestamp: 360_000,
            marker: true,
            payload: Data([0x61, 0x55]),
            extensionPayload: extensionPayload
        )) else { return false }
        let expectedExtension = Data([0xbe, 0xde, 0x00, 0x01]) + extensionPayload
        guard assembler.consume(packet: extended).first?.rtpHeaderExtensions == [expectedExtension] else { return false }

        // A relay can retransmit the same slice under a new sequence number.
        assembler.reset()
        guard let duplicateA = RTPPacket(data: makeTestPacket(
            sequence: 7,
            timestamp: 450_000,
            marker: false,
            payload: Data([0x61, 0x66])
        )), let duplicateB = RTPPacket(data: makeTestPacket(
            sequence: 8,
            timestamp: 450_000,
            marker: true,
            payload: Data([0x61, 0x66])
        )), assembler.consume(packet: duplicateA).isEmpty,
            assembler.consume(packet: duplicateB).first?.nalUnits == [Data([0x61, 0x66])] else {
            return false
        }
        return true
    }

    private static func makeTestPacket(
        sequence: UInt16,
        timestamp: UInt32,
        marker: Bool,
        payload: Data,
        extensionPayload: Data? = nil
    ) -> Data {
        var data = Data([
            extensionPayload == nil ? 0x80 : 0x90,
            marker ? 0xe0 : 0x60,
            UInt8(sequence >> 8), UInt8(sequence & 0xff),
            UInt8(timestamp >> 24), UInt8((timestamp >> 16) & 0xff), UInt8((timestamp >> 8) & 0xff), UInt8(timestamp & 0xff),
            0, 0, 0, 1
        ])
        if let extensionPayload {
            precondition(extensionPayload.count.isMultiple(of: 4))
            let wordCount = UInt16(extensionPayload.count / 4)
            data.append(contentsOf: [0xbe, 0xde, UInt8(wordCount >> 8), UInt8(wordCount & 0xff)])
            data.append(extensionPayload)
        }
        data.append(payload)
        return data
    }
}

private struct RTPPacket {
    let marker: Bool
    let payloadType: UInt8
    let sequence: UInt16
    let timestamp: UInt32
    let headerExtension: Data?
    let payload: Data

    init?(data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0] >> 6 == 2 else { return nil }
        let hasPadding = bytes[0] & 0x20 != 0
        let hasExtension = bytes[0] & 0x10 != 0
        let csrcCount = Int(bytes[0] & 0x0f)
        marker = bytes[1] & 0x80 != 0
        payloadType = bytes[1] & 0x7f
        sequence = UInt16(bytes[2]) << 8 | UInt16(bytes[3])
        timestamp = UInt32(bytes[4]) << 24 | UInt32(bytes[5]) << 16 | UInt32(bytes[6]) << 8 | UInt32(bytes[7])

        var offset = 12 + csrcCount * 4
        guard offset <= bytes.count else { return nil }
        if hasExtension {
            guard offset + 4 <= bytes.count else { return nil }
            let wordCount = Int(UInt16(bytes[offset + 2]) << 8 | UInt16(bytes[offset + 3]))
            let extensionEnd = offset + 4 + wordCount * 4
            guard extensionEnd <= bytes.count else { return nil }
            headerExtension = data.subdata(in: offset..<extensionEnd)
            offset = extensionEnd
        } else {
            headerExtension = nil
        }
        var end = bytes.count
        if hasPadding {
            let padding = Int(bytes.last ?? 0)
            guard padding > 0, padding <= end - offset else { return nil }
            end -= padding
        }
        guard end > offset else { return nil }
        payload = data.subdata(in: offset..<end)
    }
}

private struct H264RTPAssembler {
    private var timestamp: UInt32?
    private var nalUnits: [Data] = []
    private var seenNALUnits = Set<Data>()
    private var fragmentedNAL: Data?
    private var headerExtensions: [Data] = []
    private var headerExtensionBytes = 0

    mutating func reset() {
        timestamp = nil
        nalUnits.removeAll(keepingCapacity: false)
        seenNALUnits.removeAll(keepingCapacity: false)
        fragmentedNAL = nil
        headerExtensions.removeAll(keepingCapacity: false)
        headerExtensionBytes = 0
    }

    mutating func consume(packet: RTPPacket) -> [H264AccessUnit] {
        var completed: [H264AccessUnit] = []
        if timestamp != nil, timestamp != packet.timestamp {
            if let accessUnit = finishAccessUnit() { completed.append(accessUnit) }
        }
        timestamp = packet.timestamp

        if let extensionData = packet.headerExtension,
           headerExtensionBytes + extensionData.count <= 64 * 1_024,
           headerExtensions.count < 64 {
            headerExtensions.append(extensionData)
            headerExtensionBytes += extensionData.count
        }

        let bytes = [UInt8](packet.payload)
        guard let first = bytes.first else { return completed }
        let type = first & 0x1f

        switch type {
        case 1...23:
            appendNALIfNew(packet.payload)
        case 24:
            var offset = 1
            while offset + 2 <= bytes.count {
                let length = Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
                offset += 2
                guard length > 0, offset + length <= bytes.count else { break }
                appendNALIfNew(packet.payload.subdata(in: offset..<(offset + length)))
                offset += length
            }
        case 28:
            guard bytes.count >= 2 else { return completed }
            let start = bytes[1] & 0x80 != 0
            let end = bytes[1] & 0x40 != 0
            let reconstructedHeader = (bytes[0] & 0xe0) | (bytes[1] & 0x1f)
            if start {
                fragmentedNAL = Data([reconstructedHeader])
                fragmentedNAL?.append(packet.payload.dropFirst(2))
            } else {
                fragmentedNAL?.append(packet.payload.dropFirst(2))
            }
            if end, let complete = fragmentedNAL {
                appendNALIfNew(complete)
                fragmentedNAL = nil
            }
        default:
            break
        }

        if packet.marker, !nalUnits.isEmpty {
            if let accessUnit = finishAccessUnit() { completed.append(accessUnit) }
        }
        return completed
    }

    private mutating func appendNALIfNew(_ nalUnit: Data) {
        guard seenNALUnits.insert(nalUnit).inserted else { return }
        nalUnits.append(nalUnit)
    }

    private mutating func finishAccessUnit() -> H264AccessUnit? {
        guard let timestamp, !nalUnits.isEmpty else {
            nalUnits.removeAll(keepingCapacity: true)
            seenNALUnits.removeAll(keepingCapacity: true)
            fragmentedNAL = nil
            headerExtensions.removeAll(keepingCapacity: true)
            headerExtensionBytes = 0
            self.timestamp = nil
            return nil
        }
        let output = H264AccessUnit(
            nalUnits: nalUnits,
            rtpTimestamp: timestamp,
            rtpHeaderExtensions: headerExtensions,
            videoMetadata: headerExtensions.lazy.compactMap {
                VideoMetadataV2.decode($0, rtpTimestamp: timestamp)
            }.first
        )
        nalUnits.removeAll(keepingCapacity: true)
        seenNALUnits.removeAll(keepingCapacity: true)
        fragmentedNAL = nil
        headerExtensions.removeAll(keepingCapacity: true)
        headerExtensionBytes = 0
        self.timestamp = nil
        return output
    }
}
