import AppKit
import Foundation
import SwiftUI

/// Recognises URLs, email addresses and ticket codes in the text of a line and turns them
/// into an `AttributedString` with link attributes.
///
/// Everything here is main-actor-isolated: the regular expressions are shared, stored
/// values and the only callers are SwiftUI views.
@MainActor
enum LineMarkup {

    struct Span: Equatable {
        let range: NSRange
        let url: URL
    }

    private static let urlRegex = try? NSRegularExpression(pattern: "https?://[^\\s<>\"']+")
    private static let ticketRegex = try? NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9]+-[0-9]+\\b")

    /// Above this line length we skip link detection. A pasted token of thousands of
    /// characters is not text you expect links in, and scanning it stalled the note.
    private static let maxScanLength = 2000

    /// Spans found per (text, ticket base). Every render asks for them at least twice
    /// (`hasLinks` and `attributed`), and SwiftUI re-renders a line on every keystroke.
    private struct CacheKey: Hashable {
        let text: String
        let base: String
    }

    private static var cache: [CacheKey: [Span]] = [:]
    private static let cacheLimit = 512

    /// Text colour for a recognised link. Calm, but clearly different from ordinary text.
    static func tint(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0xA9CDF5) : Color(hex: 0x1B5FA6)
    }

    /// All recognised pieces, from left to right and without overlap.
    /// An empty `ticketBaseURL` switches ticket codes off.
    static func spans(in text: String, ticketBaseURL: String) -> [Span] {
        guard !text.isEmpty, text.utf16.count <= maxScanLength else { return [] }

        let key = CacheKey(text: text, base: ticketBaseURL)
        if let cached = cache[key] { return cached }

        let found = computeSpans(in: text, ticketBaseURL: ticketBaseURL)
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        cache[key] = found
        return found
    }

    private static func computeSpans(in text: String, ticketBaseURL: String) -> [Span] {
        let full = NSRange(text.startIndex..<text.endIndex, in: text)
        var result: [Span] = []

        func add(_ range: NSRange, _ url: URL?) {
            guard let url else { return }
            guard !result.contains(where: { NSIntersectionRange($0.range, range).length > 0 }) else { return }
            result.append(Span(range: range, url: url))
        }

        // The order is deliberate: a URL wins over an email address or ticket code inside it.
        urlRegex?.enumerateMatches(in: text, range: full) { match, _, _ in
            guard let match else { return }
            let trimmed = trimTrailingPunctuation(match.range, in: text)
            guard let raw = substring(trimmed, in: text) else { return }
            add(trimmed, URL(string: raw))
        }

        for range in mailRanges(in: text) {
            guard let raw = substring(range, in: text) else { continue }
            add(range, URL(string: "mailto:\(raw)"))
        }

        let base = ticketBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !base.isEmpty {
            ticketRegex?.enumerateMatches(in: text, range: full) { match, _, _ in
                guard let match, let raw = substring(match.range, in: text) else { return }
                add(match.range, ticketURL(base: base, code: raw))
            }
        }

        return result.sorted { $0.range.location < $1.range.location }
    }

    static func hasLinks(in text: String, ticketBaseURL: String) -> Bool {
        !spans(in: text, ticketBaseURL: ticketBaseURL).isEmpty
    }

    /// The line text with link attributes on the recognised pieces.
    static func attributed(_ text: String, ticketBaseURL: String, tint color: Color) -> AttributedString {
        var attributed = AttributedString(text)
        for span in spans(in: text, ticketBaseURL: ticketBaseURL) {
            guard let stringRange = Range(span.range, in: text),
                  let attributedRange = Range(stringRange, in: attributed) else { continue }
            attributed[attributedRange].link = span.url
            attributed[attributedRange].foregroundColor = color
        }
        return attributed
    }

    /// Sticks the ticket code onto the base URL, with exactly one slash in between.
    static func ticketURL(base: String, code: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let joined = (trimmed.hasSuffix("/") || trimmed.hasSuffix("=")) ? trimmed + code : trimmed + "/" + code
        return URL(string: joined)
    }

    // MARK: - Email addresses

    /// Manual, linear scan for email addresses.
    ///
    /// Deliberately not a regular expression: the obvious pattern
    /// (`[..]+@[..]+\.[A-Za-z]{2,}`) backtracks quadratically and made a note of a few
    /// thousand characters with an at-sign in it hang for seconds. This scan walks the text
    /// once: at every at-sign the local part is extended to the left and the domain to the right.
    private static func mailRanges(in text: String) -> [NSRange] {
        let units = Array(text.utf16)
        var result: [NSRange] = []
        var index = 0

        while index < units.count {
            guard units[index] == UInt16(UnicodeScalar("@").value) else {
                index += 1
                continue
            }

            var start = index
            while start > 0, isLocalPart(units[start - 1]) { start -= 1 }
            // A local part does not start with a dot.
            while start < index, units[start] == dot { start += 1 }

            var end = index + 1
            while end < units.count, isDomainPart(units[end]) { end += 1 }
            // Trailing dots belong to the sentence, not to the address.
            while end > index + 1, units[end - 1] == dot { end -= 1 }

            if start < index, let tld = lastDot(in: units, from: index + 1, to: end),
               end - tld - 1 >= 2,
               (tld + 1..<end).allSatisfy({ isLetter(units[$0]) }) {
                result.append(NSRange(location: start, length: end - start))
                index = end
            } else {
                index += 1
            }
        }
        return result
    }

    private static let dot = UInt16(UnicodeScalar(".").value)

    private static func isLetter(_ unit: UInt16) -> Bool {
        (unit >= 65 && unit <= 90) || (unit >= 97 && unit <= 122)
    }

    private static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 48 && unit <= 57
    }

    /// Characters that are allowed in the part before the at-sign.
    private static func isLocalPart(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit) || "._%+-".utf16.contains(unit)
    }

    /// Characters that are allowed in the domain.
    private static func isDomainPart(_ unit: UInt16) -> Bool {
        isLetter(unit) || isDigit(unit) || unit == dot || unit == UInt16(UnicodeScalar("-").value)
    }

    private static func lastDot(in units: [UInt16], from: Int, to: Int) -> Int? {
        var index = to - 1
        while index >= from {
            if units[index] == dot { return index }
            index -= 1
        }
        return nil
    }

    // MARK: - Helpers

    private static func substring(_ range: NSRange, in text: String) -> String? {
        guard let stringRange = Range(range, in: text) else { return nil }
        return String(text[stringRange])
    }

    /// Punctuation and closing brackets at the end almost never belong to the URL.
    private static func trimTrailingPunctuation(_ range: NSRange, in text: String) -> NSRange {
        guard var raw = substring(range, in: text) else { return range }
        let strip: Set<Character> = [".", ",", ";", ":", "!", "?", ")", "]", "}", "'", "\""]
        var dropped = 0
        while let last = raw.last, strip.contains(last), raw.count > 1 {
            raw.removeLast()
            dropped += 1
        }
        guard dropped > 0 else { return range }
        return NSRange(location: range.location, length: range.length - dropped)
    }
}
