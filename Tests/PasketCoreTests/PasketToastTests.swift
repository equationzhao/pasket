import Foundation
import Testing
@testable import PasketCore

@Suite @MainActor
struct PasketToastTests {
    @Test func completionDoesNotLoseAnUnresolvedStorageError() throws {
        let center = PasketToastCenter()
        center.showSaveFailure(from: .storage)
        let storage = try #require(center.current)
        center.show("Files removed.", source: .notice, title: "Cleanup Complete", style: .success)
        let completion = try #require(center.current)
        #expect(completion.duration == .seconds(1))
        #expect(center.current == completion)
        center.dismiss(id: completion.id)
        #expect(center.current == storage)
        #expect(center.current?.duration == nil)
    }

    @Test func aNewBriefSuccessReplacesThePreviousOneAcrossSources() throws {
        let center = PasketToastCenter()
        center.show("Files removed.", source: .notice, title: "Cleanup Complete", style: .success)
        let cleanup = try #require(center.current)
        center.show("Ready to paste.", source: .copy, title: "Copied to Clipboard", style: .success)
        let copied = try #require(center.current)
        #expect(copied.source == .copy)
        center.dismiss(id: cleanup.id)
        #expect(center.current == copied)
        center.dismiss(id: copied.id)
        #expect(center.current == nil)
    }

    @Test func fileExportShowsItsFinderActionOnOneLine() throws {
        let center = PasketToastCenter()
        let url = URL(fileURLWithPath: "/tmp/Example.txt")
        center.showFileSaved(at: url, tagsApplied: true)
        let exported = try #require(center.current)
        #expect(exported.title == "File Saved")
        #expect(exported.message == nil)
        #expect(exported.action == .showInFinder(url))
        #expect(exported.duration == .seconds(8))
    }

    @Test func failedTagsKeepTheSavedFileAndFinderAction() throws {
        let center = PasketToastCenter()
        let url = URL(fileURLWithPath: "/tmp/Example.txt")
        center.showFileSaved(at: url, tagsApplied: false)
        let exported = try #require(center.current)
        #expect(exported.title == "File Saved")
        #expect(exported.message == "Failed to apply tags.")
        #expect(exported.action == .showInFinder(url))
        #expect(exported.style == .warning)
        #expect(exported.duration == nil)
    }

    @Test func saveFailuresShareOnePresentationAndDismissTogether() throws {
        let center = PasketToastCenter()
        for source in [PasketToast.Source.storage, .retention, .fileExport] {
            center.showSaveFailure(from: source)
            let failure = try #require(center.current)
            #expect(failure.title == "Save Failed")
            #expect(failure.style == .error)
            #expect(failure.message == nil)
            #expect(failure.action == nil)
        }
        let failure = try #require(center.current)
        center.dismiss(id: failure.id)
        #expect(center.current == nil)
    }

    @Test func repeatedMessagesRestartPresentationAndIgnoreAnOldTimeout() throws {
        let center = PasketToastCenter()
        center.show("Files removed.", source: .notice, title: "Cleanup Complete", style: .success)
        let previous = try #require(center.current)
        center.show("Files removed.", source: .notice, title: "Cleanup Complete", style: .success)
        let repeated = try #require(center.current)
        #expect(previous.id != repeated.id)
        #expect(center.messages.count == 1)
        center.dismiss(id: previous.id)
        #expect(center.current == repeated)
    }

    @Test func resolvingAQueuedProblemLeavesTheCurrentNotificationVisible() throws {
        let center = PasketToastCenter()
        center.showSaveFailure(from: .storage)
        center.show("Files removed.", source: .notice, title: "Cleanup Complete", style: .success)
        let completion = try #require(center.current)
        center.showSaveFailure(from: .storage, isActive: false)
        #expect(center.current == completion)
        center.dismiss(id: completion.id)
        #expect(center.current == nil)
    }

    @Test func closingHistoryClearsTransientMessagesAndKeepsSaveFailures() {
        let center = PasketToastCenter()
        center.showSaveFailure(from: .storage)
        center.show("Files removed.", source: .notice, title: "Cleanup Complete", style: .success)
        center.dismissTransient()
        #expect(center.messages.count == 1)
        #expect(center.current?.isSaveFailure == true)
    }
}
