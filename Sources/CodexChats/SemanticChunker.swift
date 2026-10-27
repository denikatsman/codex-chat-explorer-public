import Foundation

/// Derived passage boundaries. Original payload bytes are retained separately by SemanticIndexStore.
enum SemanticChunker {
    static let maximumCharacters = 1_400
    static let maximumContextCharacters = 1_200
    static let maximumUTF8Bytes = 3_500
    static let maximumContextUTF8Bytes = 2_000

    static func chunks(_ text: String, maximum: Int = maximumCharacters) -> [String] {
        guard maximum > 0 else { return [] }
        // Prefer grapheme, paragraph/newline/word boundaries; the byte cap can split at a Unicode
        // scalar boundary while preserving the exact concatenated text.
        // very long identifiers are split explicitly rather than being dropped or truncated.
        var remaining = text[...]
        var result = [String]()
        while !remaining.isEmpty {
            let characterEnd = remaining.index(remaining.startIndex, offsetBy: maximum, limitedBy: remaining.endIndex) ?? remaining.endIndex
            let bounded = byteBoundedPrefix(remaining[..<characterEnd], maximumBytes:maximumUTF8Bytes)
            let end = bounded.endIndex
            var split = end
            if end < remaining.endIndex {
                let window = remaining[..<end]
                let lower = window.index(window.startIndex, offsetBy: window.count / 2)
                let tail = window[lower...]
                if let paragraph = tail.range(of: "\n\n", options: .backwards) { split = paragraph.upperBound }
                else if let newline = tail.lastIndex(of: "\n") { split = remaining.index(after: newline) }
                else if let space = tail.lastIndex(where: { $0.isWhitespace }) { split = remaining.index(after: space) }
            }
            let piece = String(remaining[..<split])
            if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.append(piece) }
            remaining = remaining[split...]
        }
        return result
    }

    private static func byteBoundedPrefix(_ text: Substring, maximumBytes: Int) -> Substring {
        var bytes = 0, end = text.startIndex
        for scalar in text.unicodeScalars {
            let count = scalar.utf8.count
            if bytes + count > maximumBytes { break }
            bytes += count
            end = text.unicodeScalars.index(after:end)
        }
        return text[..<end]
    }

    static func questionContext(_ text: String) -> String {
        String(byteBoundedPrefix(text.prefix(maximumContextCharacters),maximumBytes:maximumContextUTF8Bytes))
    }

    static func context(question: String?, role: String, text: String) -> String {
        guard role != "USER", let question, !question.isEmpty else { return "\(role): \(text)" }
        let prefix = questionContext(question)
        return "USER (same recorded turn, preceding question; bounded context): \(prefix)\n\(role): \(text)"
    }
}
