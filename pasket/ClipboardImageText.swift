import Foundation
import Vision

nonisolated enum ClipboardImageText {
    static func recognizeText(in data: Data) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
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
