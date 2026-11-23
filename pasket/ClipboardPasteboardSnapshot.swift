import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers
import libxml2

nonisolated enum ClipboardPasteFormat: String, Codable, CaseIterable, Sendable {
    case plainText, html, rtf, url, png

    var title: String {
        switch self {
        case .plainText: "Plain Text"
        case .html: "HTML"
        case .rtf: "RTF"
        case .url: "URL"
        case .png: "PNG"
        }
    }
}

nonisolated struct ClipboardSnapshotInfo: Codable, Sendable {
    var formats: [ClipboardPasteFormat]
    var textBytes: Int
    var imageBytes: Int
    var imageCount: Int
}

nonisolated struct ClipboardPasteboardSnapshot: Codable, Sendable {
    struct Representation: Codable, Sendable {
        var type: String
        var data: Data?

        init(_ type: NSPasteboard.PasteboardType, data: Data) {
            self.type = type.rawValue
            self.data = data
        }

        var pasteboardType: NSPasteboard.PasteboardType { .init(type) }
        var isImage: Bool { UTType(type)?.conforms(to: .image) == true }

        static func supports(_ type: NSPasteboard.PasteboardType) -> Bool {
            plainTextTypes.contains(type) || [.html, .rtf, .URL, urlName].contains(type)
                || UTType(type.rawValue)?.conforms(to: .image) == true
        }
    }

    private static let plainTextTypes: [NSPasteboard.PasteboardType] = [
        .string, .init("public.utf16-external-plain-text"), .init("public.utf16-plain-text")
    ]
    static let urlName = NSPasteboard.PasteboardType("public.url-name")
    static let fingerprintPrefix = "snapshot:"
    var items: [[Representation]]

    func fingerprint(primaryImageName: String?) -> String {
        var hasher = SHA256()
        func appendCount(_ count: Int) {
            var value = UInt64(count).bigEndian
            withUnsafeBytes(of: &value) { hasher.update(bufferPointer: $0) }
        }
        func appendBytes(_ data: Data) {
            appendCount(data.count)
            hasher.update(data: data)
        }
        appendCount(items.count)
        for item in items {
            appendCount(item.count)
            for representation in item {
                appendBytes(Data(representation.type.utf8))
                appendBytes(representation.data ?? Data())
            }
        }
        appendBytes(Data((primaryImageName ?? "").utf8))
        let hash = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return Self.fingerprintPrefix + hash
    }

    static func storageName(for fingerprint: String) -> String? {
        guard fingerprint.hasPrefix(fingerprintPrefix) else { return nil }
        let hash = fingerprint.dropFirst(fingerprintPrefix.count)
        guard hash.range(of: #"\A[a-f0-9]{64}\z"#, options: .regularExpression) != nil else { return nil }
        return hash + ".pasteboard"
    }

    static func readString(_ type: NSPasteboard.PasteboardType, in item: [Representation]) -> String? {
        guard let data = item.first(where: { $0.pasteboardType == type })?.data else { return nil }
        let encoding: String.Encoding = Self.plainTextTypes.dropFirst().contains(type) ? .utf16 : .utf8
        return String(data: data, encoding: encoding)
    }

    static func readURL(in item: [Representation]) -> String? {
        guard let value = readString(.URL, in: item), let url = URL(string: value),
              url.scheme != nil, !url.isFileURL else { return nil }
        return value
    }

    static func readPlainText(in item: [Representation]) -> String? {
        for type in plainTextTypes {
            if let text = readString(type, in: item) { return text }
        }
        if let url = readURL(in: item) { return url }
        if let data = item.first(where: { $0.pasteboardType == .rtf })?.data,
           let text = NSAttributedString(rtf: data, documentAttributes: nil)?.string { return text }
        if let data = item.first(where: { $0.pasteboardType == .html })?.data {
            return readHTMLText(data)
        }
        return nil
    }

    func availableFormats(plainText: [String?]) -> [ClipboardPasteFormat] {
        ClipboardPasteFormat.allCases.filter { format in
            switch format {
            case .plainText:
                plainText.allSatisfy { $0 != nil }
                    && items.contains { $0.contains { !Self.plainTextTypes.contains($0.pasteboardType) } }
            case .html: items.allSatisfy { $0.contains { $0.pasteboardType == .html } }
            case .rtf: items.allSatisfy { $0.contains { $0.pasteboardType == .rtf } }
            case .url: items.allSatisfy { Self.readURL(in: $0) != nil }
            case .png: items.allSatisfy { $0.filter(\.isImage).map(\.pasteboardType) == [.tiff] }
            }
        }
    }

    private static func readHTMLText(_ data: Data) -> String? {
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        let encoding = String(data: data, encoding: .utf8) != nil ? "UTF-8" : nil
        let document = data.withUnsafeBytes { bytes in
            htmlReadMemory(bytes.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count), nil, encoding, Int32(options))
        }
        guard let document else { return nil }
        defer { xmlFreeDoc(document) }
        let blocks: Set<String> = ["article", "blockquote", "br", "div", "h1", "h2", "h3", "h4", "h5", "h6",
                                   "li", "p", "pre", "section", "tr"]
        var text = ""
        func appendLineBreak() {
            if !text.isEmpty, text.last?.isNewline == false { text.append("\n") }
        }
        func appendText(from first: xmlNodePtr?) {
            var current = first
            while let node = current {
                current = node.pointee.next
                let name = node.pointee.name.map { String(cString: $0) }
                if name == "head" || name == "script" || name == "style" { continue }
                if node.pointee.type == XML_TEXT_NODE || node.pointee.type == XML_CDATA_SECTION_NODE {
                    if let content = node.pointee.content { text += String(cString: content) }
                } else if node.pointee.type == XML_ELEMENT_NODE {
                    let isBlock = name.map(blocks.contains) ?? false
                    if isBlock { appendLineBreak() }
                    appendText(from: node.pointee.children)
                    if isBlock { appendLineBreak() }
                }
            }
        }
        appendText(from: xmlDocGetRootElement(document))
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
