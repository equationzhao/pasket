import AppKit

nonisolated enum ClipboardFileAccess {
    static func capture(_ url: URL) -> ClipboardFile {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let scopedBookmark = try? url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                                 includingResourceValuesForKeys: nil, relativeTo: nil)
        let bookmark = scopedBookmark ?? (try? url.bookmarkData(options: [.minimalBookmark, .withoutImplicitSecurityScope],
                                                              includingResourceValuesForKeys: nil, relativeTo: nil))
        // Bookmark resolution uses canonical paths; keep recopying consistent with that identity.
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
        return ClipboardFile(path: canonical.path, name: canonical.lastPathComponent,
                             bookmark: bookmark,
                             byteCount: (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
                             isSecurityScoped: scopedBookmark != nil)
    }

    final class ResolvedFiles {
        private(set) var urls: [URL] = []
        private(set) var updatedFiles: [ClipboardFile] = []
        private var accessedURLs: [URL] = []

        init(_ files: [ClipboardFile]) throws {
            for file in files {
                var stale = false
                let options: URL.BookmarkResolutionOptions = file.isSecurityScoped == true
                    ? [.withSecurityScope, .withoutUI, .withoutMounting] : [.withoutUI, .withoutMounting]
                let bookmarked = file.bookmark.flatMap {
                    try? URL(resolvingBookmarkData: $0, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
                }
                let url = bookmarked ?? URL(fileURLWithPath: file.path)
                if url.startAccessingSecurityScopedResource() { accessedURLs.append(url) }
                guard FileManager.default.isReadableFile(atPath: url.path) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                urls.append(url)
                // Upgrade legacy bookmarks while the file remains accessible.
                updatedFiles.append(stale || url.path != file.path || file.isSecurityScoped != true ? capture(url) : file)
            }
        }

        deinit { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
    }

    static func withResolvedFiles<T>(_ files: [ClipboardFile], body: ([URL], [ClipboardFile]) throws -> T) throws -> T {
        let resolved = try ResolvedFiles(files)
        return try withExtendedLifetime(resolved) { try body(resolved.urls, resolved.updatedFiles) }
    }

    static func areAvailable(_ files: [ClipboardFile]) -> Bool {
        (try? withResolvedFiles(files) { _, _ in true }) ?? false
    }
}
