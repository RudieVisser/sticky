import AppKit
import Foundation

/// Text into and out of a note. Pasting from the clipboard or from a Service (import) and
/// copying as plain text or Markdown (export).
@MainActor
enum NoteTransfer {

    // MARK: - Export

    /// Title plus lines, flat. Checklist lines get "✓ " or "· " in front of them.
    static func plainText(_ note: Note) -> String {
        var out: [String] = []
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { out.append(title) }

        for line in note.lines {
            switch line.kind {
            case .separator:
                out.append("---")
            case .checklist:
                out.append((line.isDone ? "✓ " : "· ") + line.text)
            case .heading, .mono, .text:
                out.append(line.text)
            }
        }
        return out.joined(separator: "\n")
    }

    /// Markdown variant, with the title as "## ", headings as "### ", checklists as
    /// "- [ ]"/"- [x]", mono lines between backticks and separators as "---".
    static func markdown(_ note: Note) -> String {
        var out: [String] = []
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            out.append("## " + title)
            out.append("")
        }

        for line in note.lines {
            switch line.kind {
            case .separator:
                out.append("---")
            case .checklist:
                out.append((line.isDone ? "- [x] " : "- [ ] ") + line.text)
            case .heading:
                out.append("### " + line.text)
            case .mono:
                out.append(line.text.isEmpty ? "" : "`" + line.text + "`")
            case .text:
                out.append(line.text)
            }
        }
        return out.joined(separator: "\n")
    }

    static func copyToPasteboard(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    // MARK: - Import

    /// Prefixes that turn a line into a checklist line.
    private static let openPrefixes = ["- [ ] ", "* [ ] ", "[ ] ", "[] ", "- ", "* "]
    private static let donePrefixes = ["- [x] ", "* [x] ", "[x] ", "- [X] ", "[X] "]

    /// Turns a single line of text into a `NoteLine` of the matching kind.
    /// Lines that come in as a separator can therefore never be a title either.
    private static func isSeparator(_ trimmed: String) -> Bool {
        trimmed == "---" || trimmed == "***" || trimmed == "___"
    }

    /// Strips a leading markdown heading prefix ("#", "##", …) off a candidate title.
    private static func strippedHeading(_ trimmed: String) -> String {
        let withoutHashes = trimmed.drop(while: { $0 == "#" })
        guard withoutHashes.count != trimmed.count else { return trimmed }
        return String(withoutHashes).trimmingCharacters(in: .whitespaces)
    }

    static func line(from raw: String) -> NoteLine {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)

        if isSeparator(trimmed) {
            return NoteLine(text: "", kind: .separator)
        }
        for prefix in donePrefixes where trimmed.hasPrefix(prefix) {
            return NoteLine(text: String(trimmed.dropFirst(prefix.count)), kind: .checklist, isDone: true)
        }
        for prefix in openPrefixes where trimmed.hasPrefix(prefix) {
            return NoteLine(text: String(trimmed.dropFirst(prefix.count)), kind: .checklist)
        }
        if trimmed.hasPrefix("# ") {
            return NoteLine(text: String(trimmed.dropFirst(2)), kind: .heading)
        }
        if trimmed.hasPrefix("## ") {
            return NoteLine(text: String(trimmed.dropFirst(3)), kind: .heading)
        }
        return NoteLine(text: raw)
    }

    private static func startsWithListPrefix(_ text: String) -> Bool {
        (openPrefixes + donePrefixes).contains { text.hasPrefix($0) }
    }

    /// Splits a block of text into a (possibly empty) title and the lines.
    /// A first short line (< 40 characters) followed by a blank line becomes the title.
    static func parse(_ raw: String) -> (title: String, lines: [NoteLine]) {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var rows = normalized.components(separatedBy: "\n")
        while let first = rows.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeFirst()
        }
        while let last = rows.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            rows.removeLast()
        }

        var title = ""
        if rows.count >= 2 {
            let first = rows[0].trimmingCharacters(in: .whitespaces)
            let second = rows[1].trimmingCharacters(in: .whitespaces)
            // A heading line like "## Header" becomes the title without the hashes, and a
            // dashed line ("---", "***", "___") is not a title but a separator.
            let candidate = strippedHeading(first)
            if !first.isEmpty, first.count < 40, second.isEmpty,
               !startsWithListPrefix(first), !isSeparator(first), !candidate.isEmpty {
                title = candidate
                rows.removeFirst(2)
                while let next = rows.first, next.trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.removeFirst()
                }
            }
        }

        var lines = rows.map { line(from: $0) }
        if lines.isEmpty { lines = [NoteLine()] }
        return (title, lines)
    }

    /// Makes a new note from a block of text. Empty text yields nothing.
    @discardableResult
    static func makeNote(from raw: String, store: NoteStore, manager: NoteWindowManager?) -> UUID? {
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let parsed = parse(raw)

        if store.allHidden {
            manager?.setAllHidden(false)
        }
        let note = store.addNote(at: NSEvent.mouseLocation)
        store.update(note.id) {
            $0.title = parsed.title
            $0.lines = parsed.lines
        }
        manager?.focus(note.id)
        return note.id
    }

    /// Note from the current clipboard text.
    @discardableResult
    static func makeNoteFromClipboard(store: NoteStore, manager: NoteWindowManager?) -> UUID? {
        guard let text = NSPasteboard.general.string(forType: .string) else { return nil }
        return makeNote(from: text, store: store, manager: manager)
    }
}
