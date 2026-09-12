import CoreBluetooth
import Foundation

/// CoreBluetooth adapter for the isolated MiniDrone ARNetwork link. All state is
/// confined to the main queue, including delegates, inputs and the 20 Hz timer.
final class MiniDroneBLEClient: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    struct Device {
        let id: UUID
        let name: String
        let signal: Int
    }
    enum Connection: Equatable {
        case idle, scanning, connecting, subscribing, ready, disconnecting, failed(String)
        var title: String {
            switch self {
            case .idle: return "Disconnected"
            case .scanning: return "Searching nearby"
            case .connecting: return "Connecting"
            case .subscribing: return "Preparing controls"
            case .ready: return "Connected over Bluetooth"
            case .disconnecting: return "Disconnecting"
            case .failed(let message): return message
            }
        }
    }

    var onChange: (() -> Void)?
    var onLog: ((String) -> Void)?
    private(set) var connection = Connection.idle
    private(set) var devices: [Device] = []
    private(set) var telemetry = MiniDroneTelemetry()
    private(set) var connectedName = "Mambo"
    var ready: Bool { connection == .ready }
    var canTakeOff: Bool { ready && telemetry.flightState == .landed && !emergencyLatched }
    var controlsEnabled = false {
        didSet { if !controlsEnabled { input = .neutral } }
    }
    var input = BebopPilotingInput.neutral

    private var central: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var active: CBPeripheral?
    private var characteristics: [MiniDroneChannel: CBCharacteristic] = [:]
    private var handshakeCharacteristics: [CBUUID: CBCharacteristic] = [:]
    private var pendingNotifications: Set<CBUUID> = []
    private var pendingServices: Set<CBUUID> = []
    private var subscriptions = MiniDroneSubscriptions()
    private var link = MiniDroneLink()
    private var timer: Timer?
    private var deadline: TimeInterval?
    private var connectedAt: TimeInterval = 0
    private var wantsScan = false
    private var writeInFlight = false
    private var lastAcceptedWrite: TimeInterval = 0
    private var emergencyLatched = false
    private var accessoryBusyUntil: TimeInterval = 0
    private var nextStateRequestAt: TimeInterval?
    private var stateRequestAttempts = 0
    private var receivedDataPackets = 0
    private var receivedHeaderSamples: [String] = []
    private var terminalFailure: String?
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var elapsedMilliseconds: UInt32 {
        UInt32(truncatingIfNeeded: UInt64(max(0, now - connectedAt) * 1_000))
    }

    func scan() {
        guard active == nil else { return }
        wantsScan = true
        terminalFailure = nil
        if central == nil {
            central = CBCentralManager(delegate: self, queue: .main)
        } else { beginScanIfPoweredOn() }
    }

    private func beginScanIfPoweredOn() {
        guard let central, central.state == .poweredOn, wantsScan, active == nil else { return }
        devices.removeAll()
        peripherals.removeAll()
        // Some MiniDrones advertise manufacturer/name data without service UUIDs.
        central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        deadline = now + 15
        setConnection(.scanning)
        startTimer()
    }

    func connect(id: UUID) {
        guard active == nil, let peripheral = peripherals[id], central?.state == .poweredOn else { return }
        central?.stopScan()
        wantsScan = false
        resetSession()
        terminalFailure = nil
        active = peripheral
        connectedName = devices.first(where: { $0.id == id })?.name ?? "Mambo"
        peripheral.delegate = self
        deadline = now + 15
        setConnection(.connecting)
        central?.connect(peripheral, options: nil)
        startTimer()
    }

    func disconnect() {
        if ready {
            let neutral = MiniDroneCommand.pcmd(roll: 0, pitch: 0, yaw: 0, gaz: 0, milliseconds: elapsedMilliseconds)
            _ = write(link.pilotingPacket(neutral))
        }
        wantsScan = false
        central?.stopScan()
        deadline = nil
        timer?.invalidate()
        timer = nil
        resetSession()
        if let active {
            setConnection(.disconnecting)
            central?.cancelPeripheralConnection(active)
        } else { setConnection(terminalFailure.map(Connection.failed) ?? .idle) }
    }

    private func resetSession() {
        controlsEnabled = false
        input = .neutral
        telemetry = MiniDroneTelemetry()
        link = MiniDroneLink()
        subscriptions = MiniDroneSubscriptions()
        characteristics.removeAll()
        handshakeCharacteristics.removeAll()
        pendingNotifications.removeAll()
        pendingServices.removeAll()
        writeInFlight = false
        accessoryBusyUntil = 0
        nextStateRequestAt = nil
        stateRequestAttempts = 0
        receivedDataPackets = 0
        receivedHeaderSamples.removeAll()
        emergencyLatched = false
    }

    private func fail(_ message: String) {
        terminalFailure = message
        onLog?(message)
        disconnect()
    }

    private func setConnection(_ value: Connection) {
        connection = value
        onChange?()
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in self?.tick() }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }

    private func tick() {
        if let deadline, now >= deadline {
            self.deadline = nil
            if connection == .scanning {
                central?.stopScan()
                wantsScan = false
                timer?.invalidate()
                timer = nil
                setConnection(.idle)
            } else { fail("Bluetooth connection timed out. Try connecting again.") }
            return
        }
        guard ready else { return }
        guard now - lastAcceptedWrite < 3 else {
            fail("Bluetooth stopped accepting commands. Reconnect to resume.")
            return
        }
        let axes = controlsEnabled && !emergencyLatched ? input : .neutral
        if telemetry.flightState == nil, let requestAt = nextStateRequestAt,
           now >= requestAt, link.pendingCount == 0 {
            if stateRequestAttempts >= 4 {
                nextStateRequestAt = nil
                onLog?("No flight state received after 4 requests (\(receivedDataPackets) data packets)")
                if !receivedHeaderSamples.isEmpty {
                    onLog?("RX: " + receivedHeaderSamples.joined(separator: " · "))
                }
            } else if link.enqueue(MiniDroneCommand.allStates) {
                stateRequestAttempts += 1
                nextStateRequestAt = now + 2
                if stateRequestAttempts == 1 { onLog?("Requesting MiniDrone flight state") }
            }
        }
        let pcmd = MiniDroneCommand.pcmd(roll: axes.roll, pitch: axes.pitch, yaw: axes.yaw,
                                         gaz: axes.gaz, milliseconds: elapsedMilliseconds)
        link.tick(now: now, pcmd: pcmd) { [weak self] in self?.write($0) == true }
        if let failure = link.failure { fail(failure) }
    }

    private func write(_ packet: MiniDroneLink.Write) -> Bool {
        guard let active, let characteristic = characteristics[packet.channel], !writeInFlight else { return false }
        if characteristic.properties.contains(.writeWithoutResponse) {
            guard active.canSendWriteWithoutResponse else { return false }
            active.writeValue(packet.data, for: characteristic, type: .withoutResponse)
        } else if characteristic.properties.contains(.write) {
            writeInFlight = true
            active.writeValue(packet.data, for: characteristic, type: .withResponse)
        } else { return false }
        lastAcceptedWrite = now
        return true
    }

    @discardableResult
    private func send(_ data: Data, title: String, emergency: Bool = false) -> Bool {
        guard ready else { return false }
        guard emergency || !emergencyLatched else {
            onLog?("Reconnect after an emergency stop before sending more commands.")
            return false
        }
        guard link.enqueue(data, emergency: emergency) else {
            onLog?("Command queue is full. Wait for the drone to respond.")
            return false
        }
        onLog?(title)
        return true
    }

    func flatTrim() {
        guard telemetry.flightState == .landed else { return }
        _ = send(MiniDroneCommand.flatTrim, title: "Flat trim requested")
    }
    func takeOff() {
        guard canTakeOff else { return }
        input = .neutral
        _ = send(MiniDroneCommand.takeOff, title: "Takeoff requested")
    }
    func land() {
        input = .neutral
        _ = send(MiniDroneCommand.landing, title: "Landing requested")
    }
    func emergency() {
        input = .neutral
        controlsEnabled = false
        if send(MiniDroneCommand.emergency, title: "Emergency motor cut-out requested", emergency: true) {
            emergencyLatched = true
            onChange?()
        }
    }
    func takeOffOrLand() {
        guard let state = telemetry.flightState else { return }
        if state == .landed { takeOff() }
        else if state != .emergency && state != .initializing { land() }
    }
    func grabber(id: UInt8?, close: Bool) {
        guard let id, telemetry.canUseGrabber(id), now >= accessoryBusyUntil else {
            onLog?("No ready grabber selected.")
            return
        }
        if send(MiniDroneCommand.grabber(id: id, close: close), title: close ? "Grabber close requested" : "Grabber open requested") {
            accessoryBusyUntil = now + 0.75
        }
    }
    func cannon(id: UInt8?) {
        guard let id, telemetry.canFireCannon(id), now >= accessoryBusyUntil else {
            onLog?("No ready cannon selected.")
            return
        }
        if send(MiniDroneCommand.cannon(id: id), title: "Cannon fire requested") { accessoryBusyUntil = now + 0.75 }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: beginScanIfPoweredOn()
        case .unknown: break
        case .resetting:
            if active != nil { fail("Bluetooth restarted. Reconnect to resume.") }
        case .unauthorized: fail("Allow Bluetooth access in System Settings → Privacy & Security.")
        case .poweredOff: fail("Turn on Bluetooth to find your MiniDrone.")
        case .unsupported: fail("Bluetooth Low Energy is unavailable on this Mac.")
        @unknown default: fail("Bluetooth is unavailable.")
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard connection == .scanning else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name ?? "Parrot MiniDrone"
        let manufacturer = [UInt8](advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data())
        let parrot = manufacturer.count >= 2 && manufacturer[0] == 0x43 && manufacturer[1] == 0
        let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let family = services.contains { $0.uuidString.lowercased().hasPrefix("9a66fa") }
        guard name.localizedCaseInsensitiveContains("mambo") || parrot || family else { return }
        peripherals[peripheral.identifier] = peripheral
        let device = Device(id: peripheral.identifier, name: name, signal: RSSI.intValue)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else { devices.append(device) }
        onChange?()
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === active, connection == .connecting else { return }
        connectedAt = now
        deadline = now + 15
        setConnection(.subscribing)
        peripheral.discoverServices(nil)
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === active else { return }
        active = nil
        fail(error?.localizedDescription ?? "Could not connect. Wake the drone and try again.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === active else { return }
        peripheral.delegate = nil
        active = nil
        if let error { terminalFailure = error.localizedDescription }
        else if connection != .disconnecting { terminalFailure = "Bluetooth link lost. Reconnect to resume." }
        disconnect()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard peripheral === active, connection == .subscribing else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            fail(error?.localizedDescription ?? "No MiniDrone services found.")
            return
        }
        pendingServices = Set(services.map(\.uuid))
        for service in services { peripheral.discoverCharacteristics(nil, for: service) }
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard peripheral === active, connection == .subscribing else { return }
        guard error == nil else { fail(error!.localizedDescription); return }
        for characteristic in service.characteristics ?? [] {
            if let channel = MiniDroneChannel.allCases.first(where: { CBUUID(string: $0.uuid) == characteristic.uuid }) {
                characteristics[channel] = characteristic
            }
            if MiniDroneBLEClient.handshakeUUIDs.contains(characteristic.uuid),
               characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) {
                handshakeCharacteristics[characteristic.uuid] = characteristic
            }
        }
        pendingServices.remove(service.uuid)
        guard pendingServices.isEmpty else { return }
        guard Set(characteristics.keys) == Set(MiniDroneChannel.allCases),
              MiniDroneChannel.outputs.allSatisfy({
                  let properties = characteristics[$0]!.properties
                  return properties.contains(.writeWithoutResponse) || properties.contains(.write)
              }), MiniDroneChannel.notifications.allSatisfy({
                  let properties = characteristics[$0]!.properties
                  return properties.contains(.notify) || properties.contains(.indicate)
              }) else {
            fail("This device does not expose the required MiniDrone BLE channels.")
            return
        }
        // Legacy MiniDrone firmware expects notification descriptors on both the
        // ARCommands and FTP receive families to be enabled before commands begin.
        pendingNotifications = Set(handshakeCharacteristics.keys)
        for characteristic in handshakeCharacteristics.values {
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === active, connection == .subscribing || ready else { return }
        guard error == nil, characteristic.isNotifying else {
            fail(error?.localizedDescription ?? "The drone stopped sending Bluetooth notifications.")
            return
        }
        pendingNotifications.remove(characteristic.uuid)
        if let channel = channel(for: characteristic), MiniDroneChannel.notifications.contains(channel) {
            subscriptions.subscribed(channel)
        }
        if subscriptions.ready, pendingNotifications.isEmpty, !ready {
            deadline = nil
            lastAcceptedWrite = now
            // Let the drone finish its GATT setup before asking for the state dump.
            nextStateRequestAt = now + 0.35
            setConnection(.ready)
            onLog?("MiniDrone Bluetooth handshake complete")
        }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === active, connection == .subscribing || ready,
              let channel = channel(for: characteristic) else { return }
        guard error == nil else { fail(error!.localizedDescription); return }
        if let value = characteristic.value, MiniDroneChannel.notifications.contains(channel) {
            if channel == .state || channel == .telemetry {
                receivedDataPackets += 1
                let bytes = [UInt8](value)
                if bytes.count >= 6, receivedHeaderSamples.count < 6 {
                    let header = bytes.prefix(6).map { String(format: "%02X", $0) }.joined()
                    let sample = "\(channel.rawValue.uppercased()):\(header)/\(bytes.count)"
                    if !receivedHeaderSamples.contains(sample) { receivedHeaderSamples.append(sample) }
                }
            }
            guard let payload = link.receive(value, on: channel) else { return }
            let previousState = telemetry.flightState
            telemetry.consume(payload)
            if previousState == nil, let state = telemetry.flightState {
                nextStateRequestAt = nil
                onLog?("Flight state ready: \(state.title)")
            }
            onChange?()
        }
    }
    private func channel(for characteristic: CBCharacteristic) -> MiniDroneChannel? {
        characteristics.first { $0.value === characteristic }?.key
    }

    private static let handshakeUUIDs: Set<CBUUID> = Set(
        ["fb0e", "fb0f", "fb1b", "fb1c", "fd22", "fd23", "fd24", "fd52", "fd53", "fd54"]
            .map { CBUUID(string: "9a66\($0)-0800-9191-11e4-012d1540cb8e") }
    )
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard peripheral === active, ready else { return }
        writeInFlight = false
        if let error { fail(error.localizedDescription) }
    }

    /// Exercises adapter-owned state without creating a CBCentralManager.
    static func offlineSelfTest() -> Bool {
        let client = MiniDroneBLEClient()
        client.takeOff()
        client.emergency()
        guard client.link.pendingCount == 0, client.central == nil else { return false }
        client.connection = .ready
        client.telemetry.consume(Data([2, 3, 1, 0, 0, 0, 0, 0]))
        client.telemetry.consume(Data([2, 15, 2, 0, 93, 0, 0, 0, 0, 3]))
        client.cannon(id: nil)
        client.cannon(id: 0)
        guard client.link.pendingCount == 0, client.canTakeOff else { return false }
        client.cannon(id: 93)
        var writes: [MiniDroneLink.Write] = []
        client.link.tick(now: 0, pcmd: nil) { writes.append($0); return true }
        guard writes.count == 1, writes[0].channel == .command,
              Data(writes[0].data.dropFirst(2)) == MiniDroneCommand.cannon(id: 93) else { return false }
        client.controlsEnabled = true
        client.input = BebopPilotingInput(roll: 20, pitch: -30, yaw: 40, gaz: 50)
        client.emergency()
        guard client.emergencyLatched, !client.canTakeOff, client.input == .neutral,
              client.link.pendingCount == 1 else { return false }
        client.takeOff()
        guard client.link.pendingCount == 1 else { return false }
        client.disconnect()
        return client.connection == .idle && client.link.pendingCount == 0 &&
            client.input == .neutral && !client.controlsEnabled && !client.emergencyLatched &&
            client.telemetry.cannons.isEmpty && client.telemetry.flightState == nil &&
            !client.subscriptions.ready && client.central == nil
    }

}
