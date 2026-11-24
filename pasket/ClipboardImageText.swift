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
        do {
            return try await performRecognition(in: data, mode: mode)
        } catch {
            try Task.checkCancellation()
            let recognitionError = error as NSError
            // Accurate OCR can fail in the system image reader on virtual Macs.
            guard mode == .accurate, recognitionError.domain == "TextRecognition.CRImageReaderError",
                  recognitionError.code == 9 else { throw error }
            return try await performRecognition(in: data, mode: .fast)
        }
    }

    private static func performRecognition(in data: Data, mode: Mode) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = mode == .accurate ? .accurate : .fast
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = false
        let supported = request.supportedRecognitionLanguages
        request.recognitionLanguages = [Locale.Language(identifier: "en"), Locale.Language(identifier: "zh-Hans"),
                                        Locale.Language(identifier: "zh-Hant")].filter { language in
            supported.contains { $0.minimalIdentifier == language.minimalIdentifier }
        }
        let observations = try await request.perform(on: data)
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
