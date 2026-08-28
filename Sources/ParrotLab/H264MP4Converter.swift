import AppKit
import Foundation

enum BundledFFmpeg {
    static func executableURL() -> URL? {
        let candidates: [URL?] = [
            Bundle.main.resourceURL?.appendingPathComponent("ffmpeg-parrotlab"),
            ProcessInfo.processInfo.environment["PARROTLAB_FFMPEG"]
                .map { URL(fileURLWithPath: $0) },
            URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"),
            URL(fileURLWithPath: "/usr/local/bin/ffmpeg")
        ]
        return candidates.compactMap { $0 }.first {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }
}

struct MP4ConversionQuality: Equatable {
    static let minimum = 70
    static let maximum = 100
    static let original = MP4ConversionQuality(percent: 100)

    let percent: Int

    init(percent: Int) {
        self.percent = min(Self.maximum, max(Self.minimum, percent))
    }

    var copiesOriginalStream: Bool { percent == Self.maximum }

    var crf: Int {
        // Quality 70...99 maps to x264 CRF 24...14. The top position is
        // deliberately reserved for a byte-for-byte H.264 stream copy.
        let normalized = Double(percent - Self.minimum) / Double(99 - Self.minimum)
        return Int((24.0 - normalized * 10.0).rounded())
    }

    var displayLabel: String {
        if copiesOriginalStream { return "100% · Processed recording stream (no re-encode)" }
        return "\(percent)% · High-quality re-encode (CRF \(crf))"
    }
}

struct H264MP4ConversionResult {
    let outputURL: URL
    let quality: MP4ConversionQuality
}

final class H264MP4Converter {
    var onCompletion: ((Result<H264MP4ConversionResult, Error>) -> Void)?

    private let stateLock = NSLock()
    private var process: Process?
    private var cancellationRequested = false
    private var diagnosticData = Data()
    private let maximumDiagnosticBytes = 128 * 1_024

    var isConverting: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return process != nil
    }

    func convert(inputURL: URL, outputURL: URL, quality: MP4ConversionQuality) {
        guard let executable = BundledFFmpeg.executableURL() else {
            finish(.failure(conversionError("The bundled FFmpeg executable is unavailable.")))
            return
        }
        let newProcess = Process()
        let errorPipe = Pipe()
        newProcess.executableURL = executable
        newProcess.arguments = Self.arguments(
            inputURL: inputURL,
            outputURL: outputURL,
            quality: quality
        )
        newProcess.standardInput = FileHandle.nullDevice
        newProcess.standardOutput = FileHandle.nullDevice
        newProcess.standardError = errorPipe

        stateLock.lock()
        guard process == nil else {
            stateLock.unlock()
            finish(.failure(conversionError("Another video conversion is already running.")))
            return
        }
        process = newProcess
        cancellationRequested = false
        diagnosticData.removeAll(keepingCapacity: true)
        stateLock.unlock()

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            self?.appendDiagnostics(data)
        }
        newProcess.terminationHandler = { [weak self] process in
            errorPipe.fileHandleForReading.readabilityHandler = nil
            if let remainder = try? errorPipe.fileHandleForReading.readToEnd(),
               !remainder.isEmpty {
                self?.appendDiagnostics(remainder)
            }
            try? errorPipe.fileHandleForReading.close()
            self?.processTerminated(
                status: process.terminationStatus,
                outputURL: outputURL,
                quality: quality
            )
        }

        do {
            try newProcess.run()
        } catch {
            errorPipe.fileHandleForReading.readabilityHandler = nil
            stateLock.lock()
            process = nil
            stateLock.unlock()
            try? FileManager.default.removeItem(at: outputURL)
            finish(.failure(error))
        }
    }

    func cancel() {
        stateLock.lock()
        cancellationRequested = true
        let current = process
        stateLock.unlock()
        if current?.isRunning == true { current?.terminate() }
    }

    static func arguments(
        inputURL: URL,
        outputURL: URL,
        quality: MP4ConversionQuality
    ) -> [String] {
        var arguments = [
            "-hide_banner", "-nostdin", "-loglevel", "error", "-y",
            "-fflags", "+genpts", "-f", "h264", "-i", inputURL.path,
            "-map", "0:v:0", "-an", "-sn", "-dn"
        ]
        if quality.copiesOriginalStream {
            arguments += ["-c:v", "copy"]
        } else {
            arguments += [
                "-c:v", "libx264", "-preset", "slow", "-crf", "\(quality.crf)",
                "-pix_fmt", "yuv420p"
            ]
        }
        arguments += ["-movflags", "+faststart", outputURL.path]
        return arguments
    }

    static func selfTest() -> Bool {
        let input = URL(fileURLWithPath: "/tmp/input.h264")
        let output = URL(fileURLWithPath: "/tmp/output.mp4")
        let copy = arguments(inputURL: input, outputURL: output, quality: .original)
        let encoded = arguments(
            inputURL: input,
            outputURL: output,
            quality: MP4ConversionQuality(percent: 85)
        )
        return copy.contains("copy") && !copy.contains("libx264") &&
            encoded.contains("libx264") && encoded.contains("-crf") &&
            MP4ConversionQuality(percent: 101) == .original &&
            MP4ConversionQuality(percent: 50).percent == MP4ConversionQuality.minimum
    }

    private func appendDiagnostics(_ data: Data) {
        stateLock.lock()
        diagnosticData.append(data)
        if diagnosticData.count > maximumDiagnosticBytes {
            diagnosticData.removeFirst(diagnosticData.count - maximumDiagnosticBytes)
        }
        stateLock.unlock()
    }

    private func processTerminated(
        status: Int32,
        outputURL: URL,
        quality: MP4ConversionQuality
    ) {
        stateLock.lock()
        let cancelled = cancellationRequested
        let diagnostics = String(data: diagnosticData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        process = nil
        cancellationRequested = false
        diagnosticData.removeAll(keepingCapacity: false)
        stateLock.unlock()

        if status == 0,
           let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let byteCount = attributes[.size] as? NSNumber,
           byteCount.uint64Value > 0 {
            finish(.success(H264MP4ConversionResult(outputURL: outputURL, quality: quality)))
        } else {
            try? FileManager.default.removeItem(at: outputURL)
            let message: String
            if cancelled {
                message = "Video conversion was cancelled."
            } else if let diagnostics, !diagnostics.isEmpty {
                message = diagnostics
            } else {
                message = "FFmpeg exited with status \(status)."
            }
            finish(.failure(conversionError(message)))
        }
    }

    private func finish(_ result: Result<H264MP4ConversionResult, Error>) {
        DispatchQueue.main.async { [weak self] in self?.onCompletion?(result) }
    }
}

final class MP4ConversionQualityView: NSView {
    private let valueLabel = NSTextField(labelWithString: "")
    let slider = NSSlider(
        value: 100,
        minValue: Double(MP4ConversionQuality.minimum),
        maxValue: Double(MP4ConversionQuality.maximum),
        target: nil,
        action: nil
    )

    var quality: MP4ConversionQuality {
        MP4ConversionQuality(percent: slider.integerValue)
    }

    init(initialPercent: Int) {
        super.init(frame: NSRect(x: 0, y: 0, width: 390, height: 70))
        slider.integerValue = MP4ConversionQuality(percent: initialPercent).percent
        slider.isContinuous = true
        slider.numberOfTickMarks = 7
        slider.allowsTickMarkValuesOnly = false
        slider.target = self
        slider.action = #selector(valueChanged)
        slider.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        valueLabel.alignment = .center
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(slider)
        addSubview(valueLabel)
        NSLayoutConstraint.activate([
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            slider.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            valueLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            valueLabel.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 7)
        ])
        updateLabel()
    }

    required init?(coder: NSCoder) { nil }

    @objc private func valueChanged() {
        slider.integerValue = Int(slider.doubleValue.rounded())
        updateLabel()
    }

    private func updateLabel() {
        valueLabel.stringValue = quality.displayLabel
    }
}

private func conversionError(_ message: String) -> NSError {
    NSError(
        domain: "ParrotLab.H264MP4Converter",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: message]
    )
}
