import Foundation
import Vision
import CoreML

/// Assign only devices that this particular request/revision advertises. The
/// optical tracker may support different hardware from the learned recognizer.
enum SumoVisionCompute {
    @discardableResult
    static func configure(_ request: VNRequest) -> String {
        guard #available(macOS 14, *) else { return "Vision automatic" }
        guard let devices = try? request.supportedComputeStageDevices,
              let main = devices[.main], !main.isEmpty else { return "Vision automatic" }
        guard let chosen = preferred(main) else { return "Vision automatic" }
        request.setComputeDevice(chosen, for: .main)
        return "\(name(chosen)) requested"
    }

    @available(macOS 14, *)
    private static func preferred(_ devices: [MLComputeDevice]) -> MLComputeDevice? {
        devices.first { if case .neuralEngine = $0 { return true }; return false } ??
            devices.first { if case .gpu = $0 { return true }; return false } ?? devices.first
    }
    @available(macOS 14, *)
    private static func name(_ device: MLComputeDevice) -> String {
        switch device {
        case .neuralEngine: return "Neural Engine"
        case .gpu: return "GPU"
        case .cpu: return "CPU"
        @unknown default: return "Vision device"
        }
    }

    /// An OS/runtime assignment rejection must not disable recognition. Other
    /// inference failures remain errors rather than being retried indiscriminately.
    static func perform(_ request: VNRequest, with handler: VNImageRequestHandler) throws {
        do { try handler.perform([request]) }
        catch {
            guard #available(macOS 14, *), shouldRetryAutomatically(error) else { throw error }
            request.setComputeDevice(nil, for: .main)
            try handler.perform([request])
        }
    }
    private static func shouldRetryAutomatically(_ error: Error) -> Bool {
        guard #available(macOS 14, *) else { return false }
        let error = error as NSError
        return error.domain == VNErrorDomain &&
            [VNErrorCode.unsupportedComputeDevice.rawValue, VNErrorCode.unsupportedComputeStage.rawValue].contains(error.code)
    }

    static func selfTest() -> Bool {
        if #available(macOS 14, *) {
            let requests: [VNRequest] = [VNRecognizeAnimalsRequest(), VNDetectHumanRectanglesRequest(),
                                         VNDetectHumanBodyPoseRequest(), VNGenerateImageFeaturePrintRequest()]
            for request in requests {
                let summary = configure(request)
                if let supported = try? request.supportedComputeStageDevices,
                   let main = supported[.main], let expected = preferred(main) {
                    guard request.computeDevice(for: .main) == expected,
                          summary == "\(name(expected)) requested" else { return false }
                } else if summary != "Vision automatic" { return false }
            }
            guard shouldRetryAutomatically(NSError(domain: VNErrorDomain, code: VNErrorCode.unsupportedComputeDevice.rawValue)),
                  !shouldRetryAutomatically(NSError(domain: VNErrorDomain, code: VNErrorCode.operationFailed.rawValue)),
                  !shouldRetryAutomatically(NSError(domain: NSCocoaErrorDomain, code: 22)) else { return false }
        }
        return true
    }

    static var summary: String {
        let requests: [(String, VNRequest)] = [("Cat detector", VNRecognizeAnimalsRequest()),
                                              ("Appearance matching", VNGenerateImageFeaturePrintRequest()),
                                              ("Body pose", VNDetectHumanBodyPoseRequest())]
        return requests.map { "\($0.0): \(configure($0.1))" }.joined(separator: "\n")
    }
}
