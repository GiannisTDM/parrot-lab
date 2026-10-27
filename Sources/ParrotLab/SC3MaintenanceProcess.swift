import Foundation
import Darwin

/// JSONL reader with one owned process per phase. A storage/reboot timeout
/// reports UNKNOWN and keeps collecting evidence; it never kills remote work.
final class SC3MaintenanceProcess {
    private final class Context {
        let process = Process(), output = Pipe(), errors = Pipe()
        let operation: SC3MaintenanceOperation
        var transcript: SC3MaintenanceTranscript
        var outSource: DispatchSourceRead?, errSource: DispatchSourceRead?, deadline: DispatchSourceTimer?
        var pending = Data(), stderrBytes = 0, bytes = 0
        var outEOF = false, errEOF = false, exit: Int32?, failure: String?, finished = false
        var selectedStock = "", selectedFastboot = ""
        let event: (SC3MaintenanceEvent) -> Void
        let warning: (String) -> Void
        let completion: (Result<SC3MaintenanceTranscript, Error>) -> Void
        init(_ op: SC3MaintenanceOperation, event: @escaping (SC3MaintenanceEvent) -> Void,
             warning: @escaping (String) -> Void, completion: @escaping (Result<SC3MaintenanceTranscript, Error>) -> Void) {
            operation = op; transcript = SC3MaintenanceTranscript(operation: op)
            self.event = event; self.warning = warning; self.completion = completion
        }
    }
    private let queue = DispatchQueue(label: "parrotlab.sc3.maintenance.process", qos: .utility)
    private let lock = NSLock()
    private var claimed = false, current: Context?
    var isBusy: Bool { lock.withLock { claimed } }
    var isCritical: Bool { lock.withLock { current?.operation.critical == true && claimed } }

    @discardableResult
    func start(_ operation: SC3MaintenanceOperation, config: SC3MaintenanceConfiguration, session: URL?, consent: Bool,
               resources: SC3MaintenanceResources? = nil, event: @escaping (SC3MaintenanceEvent) -> Void,
               warning: @escaping (String) -> Void, completion: @escaping (Result<SC3MaintenanceTranscript, Error>) -> Void) -> Bool {
        guard lock.withLock({ if claimed { return false }; claimed = true; return true }) else { return false }
        let context = Context(operation, event: event, warning: warning, completion: completion)
        context.selectedStock = config.stockSerial; context.selectedFastboot = config.fastbootSerial
        lock.withLock { current = context }
        queue.async { [self] in
            do {
                let resource = try resources ?? SC3MaintenanceResources()
                let arguments = try config.arguments(operation, session: session, consent: consent)
                guard [config.python, config.adb, config.fastboot].allSatisfy({ FileManager.default.isExecutableFile(atPath: $0) }) else { throw SC3RFError("Python/platform-tools are missing or not executable. Choose explicit installed runtimes; nothing is downloaded.") }
                context.process.executableURL = URL(fileURLWithPath: config.python)
                context.process.arguments = ["-I", "-B", "-u", resource.directory.appendingPathComponent("entry.py").path] + arguments
                context.process.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "PYTHONDONTWRITEBYTECODE": "1", "NO_COLOR": "1"]
                context.process.standardInput = FileHandle.nullDevice
                context.process.standardOutput = context.output; context.process.standardError = context.errors
                context.process.terminationHandler = { [weak self, weak context] process in
                    guard let self, let context else { return }
                    self.queue.async { context.exit = process.terminationStatus; self.finish(context) }
                }
                try context.process.run()
                try? context.output.fileHandleForWriting.close(); try? context.errors.fileHandleForWriting.close()
                context.outSource = source(context.output.fileHandleForReading, context: context, stderr: false)
                context.errSource = source(context.errors.fileHandleForReading, context: context, stderr: true)
                let timer = DispatchSource.makeTimerSource(queue: queue)
                timer.schedule(deadline: .now() + operation.deadline)
                timer.setEventHandler { [weak self, weak context] in
                    guard let self, let context, !context.finished else { return }
                    self.fail(context, "STOP / unknown outcome: deadline exceeded. Preserve the private session and request a checkpoint. No mutation is retried.")
                }
                context.deadline = timer; timer.resume()
            } catch {
                context.failure = error.localizedDescription; context.exit = 1; context.outEOF = true; context.errEOF = true
                finish(context)
            }
        }
        return true
    }
    func cancelReadOnly() {
        queue.async { [self] in
            guard let context = lock.withLock({ current }), !context.operation.critical else { return }
            fail(context, "Read-only operation cancelled; preserve any session evidence/lock and verify a checkpoint before continuing.")
        }
    }
    private func stopReadOnly(_ context: Context) {
        guard !context.operation.critical else { return }
        if context.process.isRunning { context.process.terminate() }
        queue.asyncAfter(deadline: .now() + 2) {
            if !context.finished, context.process.isRunning { kill(context.process.processIdentifier, SIGKILL) }
        }
    }
    private func source(_ file: FileHandle, context: Context, stderr: Bool) -> DispatchSourceRead {
        let fd = file.fileDescriptor
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { try? file.close() }
        source.setEventHandler { [weak self, weak context] in
            guard let self, let context, !context.finished else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count < 0, errno == EINTR { continue }
                if count < 0, errno == EAGAIN || errno == EWOULDBLOCK { return }
                if count <= 0 {
                    if stderr { context.errEOF = true; context.errSource?.cancel() } else {
                        context.outEOF = true; context.outSource?.cancel()
                        if !context.pending.isEmpty { self.fail(context, "Truncated maintenance JSON line; STOP / unknown outcome.") }
                    }
                    self.finish(context); return
                }
                let data = Data(buffer.prefix(count))
                if stderr {
                    context.stderrBytes = min(65_537, context.stderrBytes + count)
                    if context.stderrBytes > 65_536 { self.fail(context, "Maintenance stderr exceeded its bound; preserve evidence.") }
                } else { self.consume(data, context) }
            }
        }
        source.resume(); return source
    }
    private func consume(_ data: Data, _ context: Context) {
        guard context.failure == nil else { return }
        context.bytes += data.count
        guard context.bytes <= 1_048_576 else { fail(context, "Maintenance JSON output exceeded its bound; STOP."); return }
        context.pending.append(data)
        while let newline = context.pending.firstIndex(of: 10) {
            let line = Data(context.pending[..<newline]); context.pending.removeSubrange(...newline)
            do {
                let event = try SC3MaintenanceEvent(line)
                if ["prepared", "root_verified", "debug_verified"].contains(event.name), !context.selectedStock.isEmpty,
                   event.fields["stock_serial"] as? String != context.selectedStock { throw SC3RFError("Controller changed during this session; STOP.") }
                if event.name == "fastboot_ready", !context.selectedFastboot.isEmpty,
                   event.fields["serial"] as? String != context.selectedFastboot { throw SC3RFError("Fastboot controller changed during this session; STOP.") }
                try context.transcript.accept(event)
                DispatchQueue.main.async { context.event(event) }
            } catch { fail(context, error.localizedDescription); return }
        }
        if context.pending.count > 65_536 { fail(context, "Maintenance JSON line exceeded its bound; STOP.") }
    }
    private func fail(_ context: Context, _ message: String) {
        guard context.failure == nil else { return }; context.failure = message
        DispatchQueue.main.async { context.warning(message) }
        if !context.operation.critical { stopReadOnly(context) }
    }
    private func finish(_ context: Context) {
        guard !context.finished, let exit = context.exit, context.outEOF, context.errEOF else { return }
        context.finished = true; context.deadline?.cancel(); context.process.terminationHandler = nil
        context.outSource?.cancel(); context.errSource?.cancel()
        let result: Result<SC3MaintenanceTranscript, Error>
        do {
            if let failure = context.failure { throw SC3RFError(failure) }
            try context.transcript.validateExit(exit); result = .success(context.transcript)
        } catch { result = .failure(error) }
        lock.withLock { if current === context { current = nil; claimed = false } }
        DispatchQueue.main.async { context.completion(result) }
    }
    func triggerDeadlineForSelfTest() {
        queue.async { [self] in
            guard let context = lock.withLock({ current }), !context.finished else { return }
            fail(context, "STOP / unknown outcome: fixture deadline; preserve evidence.")
        }
    }
}
