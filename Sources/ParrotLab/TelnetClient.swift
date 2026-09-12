import Foundation
import Network

final class TelnetClient {
    enum State: Equatable {
        case idle
        case connecting
        case ready
        case failed(String)
        case stopped
    }

    var onState: ((State) -> Void)?
    var onLine: ((String) -> Void)?
    var onDebug: ((String) -> Void)?

    private let queue = DispatchQueue(label: "parrotlab.telnet")
    private var connection: NWConnection?
    private var connectionID: UUID?
    private var lineBuffer = Data()
    private var bridgeChallenge: String?
    private var bridgeStartupCommand: String?
    private var state: State = .idle {
        didSet {
            let reportedState = state
            DispatchQueue.main.async { [weak self] in self?.onState?(reportedState) }
        }
    }

    func connect(host: String, port: UInt16 = 23, startupCommand: String = "ulogcat", viaSC2 bridgeHost: String? = nil) {
        stop()
        let bridgeCommand = bridgeHost == nil ? nil : Self.bridgeHopCommand(host: host, port: port)
        if bridgeHost != nil, bridgeCommand == nil {
            state = .failed("Invalid downstream Telnet IPv4 address")
            return
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            state = .failed("Invalid Telnet port")
            return
        }

        state = .connecting
        let connection = NWConnection(host: NWEndpoint.Host(bridgeHost ?? host), port: bridgeHost == nil ? endpointPort : 23, using: .tcp)
        let connectionID = UUID()
        self.connection = connection
        self.connectionID = connectionID
        if bridgeHost != nil {
            bridgeChallenge = "__PARROTLAB_BRIDGE_\(UUID().uuidString)__"
            bridgeStartupCommand = startupCommand
        }
        connection.stateUpdateHandler = { [weak self, weak connection] newState in
            guard let self, let connection, self.connectionID == connectionID else { return }
            switch newState {
            case .ready:
                if bridgeHost == nil { self.state = .ready }
                self.onDebugMain(bridgeHost.map { "SC2 Telnet connected to \($0):23; opening tunnel to \(host):\(port)" } ?? "Telnet connected to \(host):\(port)")
                self.receive(on: connection)
                self.queue.asyncAfter(deadline: .now() + 0.15) {
                    self.send("\r\n", on: connection)
                }
                self.queue.asyncAfter(deadline: .now() + 0.45) {
                    guard self.connectionID == connectionID else { return }
                    // exec is essential: a failed tunnel must close the SC2 shell,
                    // never allow a downstream command to run on the controller.
                    // Use SC2's Telnet client, matching the working manual hop.
                    // Raw nc leaves downstream Telnet negotiation nested inside
                    // the outer session, which this client must not interpret.
                    let firstCommand = bridgeCommand ?? startupCommand
                    self.send(
                        "export TERM=dumb; export PATH=/usr/bin:/bin:/usr/sbin:/sbin; \(firstCommand)\r\n",
                        on: connection
                    )
                }
                if bridgeHost != nil {
                    self.probeBridge(on: connection, id: connectionID, attempts: 12)
                }
            case .failed(let error):
                self.state = .failed(error.localizedDescription)
                self.onDebugMain("Telnet failed: \(error.localizedDescription)")
            case .cancelled:
                if self.state != .stopped { self.state = .stopped }
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func sendCommand(_ command: String) {
        guard let connection else { return }
        send(command + "\r\n", on: connection)
    }

    func stop() {
        connectionID = nil
        connection?.cancel()
        connection = nil
        lineBuffer.removeAll(keepingCapacity: false)
        bridgeChallenge = nil
        bridgeStartupCommand = nil
        state = .stopped
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self, weak connection] data, _, complete, error in
            guard let self, let connection, self.connection === connection else { return }
            if let data, !data.isEmpty {
                let payload = self.processTelnet(data, on: connection)
                self.consumeText(payload)
            }
            if let error {
                self.state = .failed(error.localizedDescription)
                self.onDebugMain("Telnet receive error: \(error.localizedDescription)")
                return
            }
            if complete {
                if self.bridgeChallenge != nil {
                    self.bridgeChallenge = nil
                    self.bridgeStartupCommand = nil
                    self.state = .failed("SC2 Telnet hop closed before the downstream shell was confirmed. Check the nested Telnet session and Sumo address.")
                } else {
                    self.state = .stopped
                }
                self.onDebugMain("Telnet connection closed")
                return
            }
            self.receive(on: connection)
        }
    }

    private func processTelnet(_ data: Data, on connection: NWConnection) -> Data {
        let bytes = [UInt8](data)
        var output = Data()
        var index = 0
        while index < bytes.count {
            if bytes[index] == 255, index + 1 < bytes.count {
                let command = bytes[index + 1]
                if [251, 252, 253, 254].contains(command), index + 2 < bytes.count {
                    let option = bytes[index + 2]
                    let response: UInt8 = (command == 253 || command == 254) ? 252 : 254
                    connection.send(content: Data([255, response, option]), completion: .contentProcessed { _ in })
                    index += 3
                    continue
                }
                if command == 255 {
                    output.append(255)
                    index += 2
                    continue
                }
                index += 2
                continue
            }
            output.append(bytes[index])
            index += 1
        }
        return output
    }

    private func consumeText(_ data: Data) {
        lineBuffer.append(data)
        while let newline = lineBuffer.firstIndex(of: 10) {
            let lineData = lineBuffer.prefix(upTo: newline)
            lineBuffer.removeSubrange(...newline)
            guard var line = String(data: lineData, encoding: .utf8) else { continue }
            line = line.trimmingCharacters(in: .newlines)
            if line.last == "\r" { line.removeLast() }
            if let challenge = bridgeChallenge,
               line.trimmingCharacters(in: .whitespacesAndNewlines) == challenge,
               let command = bridgeStartupCommand, let connection {
                bridgeChallenge = nil
                bridgeStartupCommand = nil
                state = .ready
                onDebugMain("Downstream Sumo shell confirmed through SC2")
                send("export TERM=dumb; export PATH=/usr/bin:/bin:/usr/sbin:/sbin; \(command)\r\n", on: connection)
                continue
            }
            DispatchQueue.main.async { [weak self] in self?.onLine?(line) }
        }
    }

    private func send(_ text: String, on connection: NWConnection) {
        connection.send(content: text.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            if let error { self?.onDebugMain("Telnet send error: \(error.localizedDescription)") }
        })
    }

    private func probeBridge(on connection: NWConnection, id: UUID, attempts: Int) {
        queue.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self, self.connectionID == id, let challenge = self.bridgeChallenge else { return }
            guard attempts > 0 else {
                self.bridgeChallenge = nil
                self.bridgeStartupCommand = nil
                self.state = .failed("SC2 Telnet hop did not confirm the Sumo shell within 9 seconds. No device command was issued; this does not prove Sumo is unreachable.")
                connection.cancel()
                return
            }
            // Read-only handshake; no upload/launch is sent until its exact echo
            // response arrives from the shell behind the exec'd Telnet client.
            self.send("printf '\\n\(challenge)\\n'\r\n", on: connection)
            self.probeBridge(on: connection, id: id, attempts: attempts - 1)
        }
    }

    private func onDebugMain(_ message: String) {
        DispatchQueue.main.async { [weak self] in self?.onDebug?(message) }
    }

    static func bridgeHopCommand(host: String, port: UInt16 = 23) -> String? {
        guard IPv4Address(host) != nil, port > 0 else { return nil }
        return "exec /usr/bin/telnet \(host)" + (port == 23 ? "" : " \(port)")
    }

    static func bridgeSelfTest() -> Bool {
        bridgeHopCommand(host: "192.168.2.1") == "exec /usr/bin/telnet 192.168.2.1" &&
            bridgeHopCommand(host: "192.168.2.1", port: 2323) == "exec /usr/bin/telnet 192.168.2.1 2323" &&
            bridgeHopCommand(host: "192.168.2.1; reboot") == nil &&
            bridgeHopCommand(host: "192.168.2.1", port: 0) == nil
    }
}
