import AppKit
import Foundation
import SwiftUI

enum NoteColor: String, Codable, CaseIterable, Sendable {
    case yellow, pink, blue, green, purple, gray

    /// Background color of the note, with its own variant for dark mode.
    func background(_ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch self {
        case .yellow: return dark ? Color(hex: 0x6A5D22) : Color(hex: 0xFFF2B2)
        case .pink:   return dark ? Color(hex: 0x6B3A48) : Color(hex: 0xFFD7E2)
        case .blue:   return dark ? Color(hex: 0x274960) : Color(hex: 0xCFE7FF)
        case .green:  return dark ? Color(hex: 0x2D5535) : Color(hex: 0xD3F4CE)
        case .purple: return dark ? Color(hex: 0x453764) : Color(hex: 0xE5DAFF)
        case .gray:   return dark ? Color(hex: 0x3B3B40) : Color(hex: 0xE9E9EC)
        }
    }

    /// Slightly stronger variant for the color dot and the header.
    func accent(_ scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch self {
        case .yellow: return dark ? Color(hex: 0xE8D46A) : Color(hex: 0xE9C93F)
        case .pink:   return dark ? Color(hex: 0xE79FB4) : Color(hex: 0xE87CA0)
        case .blue:   return dark ? Color(hex: 0x83BEEA) : Color(hex: 0x5AA7E0)
        case .green:  return dark ? Color(hex: 0x8FD693) : Color(hex: 0x5FBF6B)
        case .purple: return dark ? Color(hex: 0xB6A2E8) : Color(hex: 0x9B7FE0)
        case .gray:   return dark ? Color(hex: 0xA8A8AE) : Color(hex: 0x9B9BA1)
        }
    }

    var label: String {
        switch self {
        case .yellow: return "Yellow"
        case .pink:   return "Pink"
        case .blue:   return "Blue"
        case .green:  return "Green"
        case .purple: return "Purple"
        case .gray:   return "Gray"
        }
    }

    /// NSColor variant for the menu bar dot.
    var nsAccent: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let scheme: ColorScheme = dark ? .dark : .light
            return NSColor(self.accent(scheme))
        }
    }
}

enum TuckEdge: String, Codable, Sendable {
    case left, right
}

/// Kind of line. Replaces the separate bools; `isChecklist` from older files is
/// converted to `.checklist` while decoding.
enum LineKind: String, Codable, CaseIterable, Sendable {
    case text, checklist, heading, separator, mono
}

/// Text size per note. The line views scale along with it.
enum TextSize: String, Codable, CaseIterable, Sendable {
    case small, medium, large

    var label: String {
        switch self {
        case .small:  return "S"
        case .medium: return "M"
        case .large:  return "L"
        }
    }

    var textSize: CGFloat {
        switch self {
        case .small:  return 11
        case .medium: return 12
        case .large:  return 14
        }
    }

    var headingSize: CGFloat {
        switch self {
        case .small:  return 13
        case .medium: return 14.5
        case .large:  return 17
        }
    }

    var checkboxSize: CGFloat {
        switch self {
        case .small:  return 11
        case .medium: return 12
        case .large:  return 14
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .small:  return 9
        case .medium: return 10
        case .large:  return 11
        }
    }
}

struct NoteLine: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var text: String = ""
    var kind: LineKind = .text
    var isDone: Bool = false

    var isChecklist: Bool { kind == .checklist }
    /// A separator has no text field and can therefore never take focus.
    var isEditable: Bool { kind != .separator }

    init(id: UUID = UUID(), text: String = "", kind: LineKind = .text, isDone: Bool = false) {
        self.id = id
        self.text = text
        self.kind = kind
        self.isDone = isDone
    }

    private enum CodingKeys: String, CodingKey {
        case id, text, kind, isDone, isChecklist
    }

    /// Reads both the new `kind` and the old `isChecklist`, so an existing
    /// `notes.json` simply keeps loading.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        if let decodedKind = try container.decodeIfPresent(LineKind.self, forKey: .kind) {
            kind = decodedKind
        } else if try container.decodeIfPresent(Bool.self, forKey: .isChecklist) == true {
            kind = .checklist
        } else {
            kind = .text
        }
        isDone = try container.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(text, forKey: .text)
        try container.encode(kind, forKey: .kind)
        try container.encode(isDone, forKey: .isDone)
    }
}

struct Note: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String = ""
    var lines: [NoteLine] = [NoteLine()]
    var color: NoteColor = .yellow
    var frame: CGRect = Note.defaultFrame
    var tuckedEdge: TuckEdge? = nil
    var tuckedY: CGFloat = 0
    var createdAt: Date = Date()
    /// Opacity of the panel (and of the tuck tab) while the mouse is not hovering over it.
    var opacity: Double = Note.maxOpacity
    /// Text size of the lines.
    var textSize: TextSize = .medium
    /// Less vertical space between the lines.
    var isCompact: Bool = false

    static let defaultSize = CGSize(width: 260, height: 220)
    static let minSize = CGSize(width: 180, height: 120)
    static let tabSize = CGSize(width: 22, height: 64)
    static let headerHeight: CGFloat = 28
    static let minOpacity: Double = 0.35
    static let maxOpacity: Double = 1.0

    /// Manual decoder so a `notes.json` from before a new field keeps loading fine.
    /// Missing keys fall back to the default value instead of raising an error.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = Note(id: UUID())
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? fallback.id
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? fallback.title
        let decodedLines = try container.decodeIfPresent([NoteLine].self, forKey: .lines) ?? []
        lines = decodedLines.isEmpty ? [NoteLine()] : decodedLines
        color = try container.decodeIfPresent(NoteColor.self, forKey: .color) ?? fallback.color
        frame = try container.decodeIfPresent(CGRect.self, forKey: .frame) ?? fallback.frame
        tuckedEdge = try container.decodeIfPresent(TuckEdge.self, forKey: .tuckedEdge)
        tuckedY = try container.decodeIfPresent(CGFloat.self, forKey: .tuckedY) ?? fallback.tuckedY
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? fallback.createdAt
        let decodedOpacity = try container.decodeIfPresent(Double.self, forKey: .opacity) ?? Note.maxOpacity
        opacity = Note.clampOpacity(decodedOpacity)
        textSize = try container.decodeIfPresent(TextSize.self, forKey: .textSize) ?? fallback.textSize
        isCompact = try container.decodeIfPresent(Bool.self, forKey: .isCompact) ?? fallback.isCompact
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        lines: [NoteLine] = [NoteLine()],
        color: NoteColor = .yellow,
        frame: CGRect = Note.defaultFrame,
        tuckedEdge: TuckEdge? = nil,
        tuckedY: CGFloat = 0,
        createdAt: Date = Date(),
        opacity: Double = Note.maxOpacity,
        textSize: TextSize = .medium,
        isCompact: Bool = false
    ) {
        self.id = id
        self.title = title
        self.lines = lines
        self.color = color
        self.frame = frame
        self.tuckedEdge = tuckedEdge
        self.tuckedY = tuckedY
        self.createdAt = createdAt
        self.opacity = opacity
        self.textSize = textSize
        self.isCompact = isCompact
    }

    static func clampOpacity(_ value: Double) -> Double {
        guard value.isFinite else { return maxOpacity }
        return min(max(value, minOpacity), maxOpacity)
    }

    static var defaultFrame: CGRect {
        CGRect(origin: .zero, size: defaultSize)
    }

    /// Title as shown in the menu bar menu.
    var menuTitle: String {
        let raw = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return String(raw.prefix(30)) }
        let firstText = lines
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        if let firstText, !firstText.isEmpty { return String(firstText.prefix(30)) }
        return "Empty note"
    }

    var isEmpty: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && lines.allSatisfy { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}
