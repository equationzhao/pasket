import Foundation
import Observation

struct PasketToast: Identifiable, Equatable {
    enum Source { case notice, copy, paste, storage, retention, pasteOrderHint, imageText, fileExport, pin, deletion }
    enum Style { case success, information, warning, error }
    enum Action: Equatable {
        case showInFinder(URL)
    }

    let id = UUID()
    let source: Source
    let title: String
    let message: String?
    let style: Style
    let action: Action?

    var isBriefSuccess: Bool { style == .success && action == nil }
    var isSaveFailure: Bool { style == .error && message == nil }

    var duration: Duration? {
        if isBriefSuccess { return .seconds(1) }
        if isSaveFailure || (style == .warning && action != nil) { return nil }
        if source == .imageText && style == .information && message == nil { return .milliseconds(3500) }
        return source == .pasteOrderHint ? .seconds(4) : .seconds(8)
    }
}

@MainActor @Observable
final class PasketToastCenter {
    private(set) var messages: [PasketToast] = []
    var current: PasketToast? { messages.last }

    func show(_ message: String?, source: PasketToast.Source, title: String,
              style: PasketToast.Style, action: PasketToast.Action? = nil) {
        guard let message else { dismiss(source: source); return }
        enqueue(PasketToast(source: source, title: title, message: message, style: style, action: action))
    }

    func showSaveFailure(from source: PasketToast.Source, isActive: Bool = true) {
        guard isActive else { dismiss(source: source); return }
        enqueue(PasketToast(source: source, title: "Save Failed", message: nil, style: .error, action: nil))
    }

    func showSuccess(_ title: String, source: PasketToast.Source) {
        enqueue(PasketToast(source: source, title: title, message: nil, style: .success, action: nil))
    }

    func showNoImageText() {
        enqueue(PasketToast(source: .imageText, title: "No Text Found", message: nil, style: .information, action: nil))
    }

    func showFileSaved(at url: URL, tagsApplied: Bool) {
        enqueue(PasketToast(source: .fileExport, title: "File Saved",
                            message: tagsApplied ? nil : "Failed to apply tags.",
                            style: tagsApplied ? .success : .warning, action: .showInFinder(url)))
    }

    private func enqueue(_ toast: PasketToast) {
        messages.removeAll { $0.source == toast.source || $0.isBriefSuccess }
        messages.append(toast)
    }

    func dismiss(id: UUID) {
        guard let toast = messages.first(where: { $0.id == id }) else { return }
        messages.removeAll { $0.id == id || (toast.isSaveFailure && $0.isSaveFailure) }
    }

    func dismiss(source: PasketToast.Source) {
        messages.removeAll { $0.source == source }
    }

    func dismissTransient() {
        messages.removeAll { $0.duration != nil }
    }

    func dismissAll() { messages.removeAll() }
}
