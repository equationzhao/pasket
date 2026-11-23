import Foundation

nonisolated struct ClipboardSearch {
    enum Level: Int, Sendable {
        case literal, initials, fuzzy
        var next: Self? { Self(rawValue: rawValue + 1) }
    }

    let query: String
    let level: Level
    private let tokens: [Token]
    var isEmpty: Bool { query.isEmpty }

    init(_ query: String, level: Level = .fuzzy) {
        self.level = level
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen: Set<String> = []
        tokens = self.query.split(whereSeparator: \.isWhitespace).compactMap { part in
            let text = String(part)
            return seen.insert(text).inserted ? Token(text) : nil
        }
    }

    // Zero excludes a record; higher ranks precede lower ranks before pagination.
    func rank(fields: [String]) -> Double {
        guard !isEmpty else { return 3 }
        // Every field uses the same boundaries, including bodies containing several file paths.
        let fields = fields.flatMap { $0.components(separatedBy: .newlines) }
        if fields.contains(where: { $0.localizedStandardContains(query) }) { return 3 }
        var usesInitials = false
        var usesSubsequence = false
        var totalGap = 0
        var preparedFields: [SearchField]?
        var foldedInitials: [Character: String] = [:]
        for token in tokens {
            // The whole-query check already ruled out the identical single token.
            if token.text != query && fields.contains(where: { $0.localizedStandardContains(token.text) }) { continue }
            guard level != .literal else { return 0 }
            let prepared = preparedFields ?? fields.map { SearchField($0, foldedInitials: &foldedInitials) }
            preparedFields = prepared
            if prepared.contains(where: { token.minimumGap(in: $0.initials, initials: true) != nil }) {
                usesInitials = true
                continue
            }
            guard level == .fuzzy,
                  let gap = prepared.compactMap({ token.minimumGap(in: $0.text) }).min() else { return 0 }
            usesSubsequence = true
            totalGap += gap
        }
        // Keep every accepted ordinary subsequence below initials.
        // Smaller total gaps yield higher scores; equal scores retain recency order.
        if usesSubsequence { return 1 / (Double(totalGap) + 2) }
        return usesInitials ? 1 : 2
    }

    func rank(_ item: ClipboardItem) -> Double {
        rank(fields: [item.title, item.content, item.source.name, item.source.bundleIdentifier ?? ""])
    }

    func imageTextRank(_ text: String) -> Double {
        guard !isEmpty, !text.isEmpty else { return 0 }
        if text.localizedStandardContains(query) { return 3 }
        return tokens.allSatisfy { text.localizedStandardContains($0.text) } ? 2 : 0
    }

    func imageTextSnippet(_ text: String) -> String? {
        guard imageTextRank(text) > 0 else { return nil }
        let match = text.localizedStandardRange(of: query)
            ?? tokens.lazy.compactMap { text.localizedStandardRange(of: $0.text) }.first
        guard let match else { return nil }
        let line = text.lineRange(for: match)
        let start = text.index(match.lowerBound, offsetBy: -10, limitedBy: line.lowerBound) ?? line.lowerBound
        let end = text.index(start, offsetBy: 110, limitedBy: line.upperBound) ?? line.upperBound
        return (start > line.lowerBound ? "…" : "")
            + text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
            + (end < line.upperBound ? "…" : "")
    }

    func imageTextHighlight(in snippet: String) -> Range<String.Index>? {
        snippet.localizedStandardRange(of: query)
            ?? tokens.lazy.compactMap { snippet.localizedStandardRange(of: $0.text) }.first
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .precomposedStringWithCanonicalMapping
    }

    private struct SearchField {
        let text: [(character: Character, offset: Int)]
        let initials: [(character: Character, offset: Int)]

        init(_ text: String, foldedInitials: inout [Character: String]) {
            self.text = Array(ClipboardSearch.fold(text)).enumerated().map { ($0.element, $0.offset) }
            let characters = Array(text)
            var initials: [(character: Character, offset: Int)] = []
            var afterSeparator = true
            for index in characters.indices {
                let character = characters[index]
                // Inside a word these ASCII characters can never start a new initial.
                if !afterSeparator, let ascii = character.asciiValue,
                   (97...122).contains(ascii) || (48...57).contains(ascii) { continue }
                guard character.isLetter || character.isNumber else {
                    afterSeparator = true
                    continue
                }
                if !afterSeparator {
                    guard character.isUppercase else { continue }
                    let previous = characters[index - 1]
                    let acronymBoundary = previous.isUppercase && index + 1 < characters.count
                        && characters[index + 1].isLowercase
                    guard previous.isLowercase || previous.isNumber || acronymBoundary else { continue }
                }
                afterSeparator = false
                let folded = foldedInitials[character] ?? ClipboardSearch.fold(String(character))
                // Bound transient storage on diverse text; keep serving existing initials at capacity.
                // 64 slots can hold the full ASCII alphanumeric alphabet or initials from any script.
                if foldedInitials.count < 64 { foldedInitials[character] = folded }
                initials.append(contentsOf: folded.map { ($0, index) })
            }
            self.initials = initials
        }
    }

    private struct Token {
        let text: String
        let length: Int
        let positions: [Character: [Int]]

        init(_ text: String) {
            self.text = text
            let characters = Array(ClipboardSearch.fold(text))
            length = characters.count
            var positions: [Character: [Int]] = [:]
            for index in characters.indices.reversed() {
                positions[characters[index], default: []].append(index)
            }
            self.positions = positions
        }

        func minimumGap(in text: [(character: Character, offset: Int)], initials: Bool = false) -> Int? {
            guard length > 0 else { return nil }
            // Fuzzy matches must be at least half query characters, with at most three
            // skipped characters per step. Initials allow ordinary word lengths, but
            // still measure the original text rather than an artificially compact acronym.
            let maximumGap = initials ? length * 12 : length
            let maximumStep = initials ? 24 : 3
            struct Window { let start: Int; let end: Int }
            var windows = [[Window]](repeating: [], count: length)
            var bestGap: Int?
            for (character, offset) in text {
                // Descending positions prevent one character from matching twice.
                // The latest start of each reachable prefix gives the tightest window at this end.
                for index in positions[character] ?? [] {
                    windows[index].removeAll { offset - $0.end - 1 > maximumStep }
                    let start: Int
                    if index == 0 { start = offset }
                    else {
                        guard let latest = windows[index - 1].filter({
                            offset - $0.end - 1 <= maximumStep && offset - $0.start - index <= maximumGap
                        }).max(by: { $0.start < $1.start }) else { continue }
                        start = latest.start
                    }
                    windows[index].append(Window(start: start, end: offset))
                    guard index == length - 1 else { continue }
                    // Count skipped grapheme clusters after folding, not bytes or code units.
                    let gap = offset - start + 1 - length
                    guard gap <= maximumGap else { continue }
                    if gap == 0 { return 0 }
                    bestGap = min(bestGap ?? gap, gap)
                }
            }
            return bestGap
        }
    }
}
