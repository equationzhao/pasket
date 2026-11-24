import Foundation
import Vision

nonisolated enum ClipboardImageText {
    enum Mode: String, CaseIterable, Sendable {
        case accurate, fast

        var title: String { self == .accurate ? "Accurate" : "Fast" }
    }

    typealias Recognizer = @Sendable (Data, Mode) async throws -> String

    @Sendable
    static func recognizeText(in data: Data, mode: Mode) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = mode == .accurate ? .accurate : .fast
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false
        let supported = request.supportedRecognitionLanguages
        request.recognitionLanguages = [Locale.Language(identifier: "en"), Locale.Language(identifier: "zh-Hans"),
                                        Locale.Language(identifier: "zh-Hant")].filter { language in
            supported.contains { $0.minimalIdentifier == language.minimalIdentifier }
        }
        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: data)
        } catch {
            try Task.checkCancellation()
            if case VisionError.requestCancelled = error { throw error }
            guard mode == .accurate else { throw error }
            // Vision can select an accelerator that fails at runtime on a virtual Mac.
            var hasCPUStage = false
            for (stage, devices) in request.supportedComputeStageDevices {
                let cpu = devices.first { device in
                    if case .cpu = device { return true }
                    return false
                }
                guard let cpu else { continue }
                request.setComputeDevice(cpu, for: stage)
                hasCPUStage = true
            }
            guard hasCPUStage else { throw error }
            observations = try await request.perform(on: data)
        }
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
