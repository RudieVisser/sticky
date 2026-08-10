import AppKit
import Combine
import Foundation
import SwiftUI

/// Persistent state and settings that are stored separately from the notes themselves.
/// Every field is read with `decodeIfPresent`, so an older `state.json` keeps loading.
private struct AppState: Codable {
    var allHidden: Bool = false
    /// Base URL that a ticket code gets appended to. Empty means ticket codes are not clickable.
    var ticketBaseURL: String = ""

    init(allHidden: Bool = false, ticketBaseURL: String = "") {
        self.allHidden = allHidden
        self.ticketBaseURL = ticketBaseURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        allHidden = try container.decodeIfPresent(Bool.self, forKey: .allHidden) ?? false
        ticketBaseURL = try container.decodeIfPresent(String.self, forKey: .ticketBaseURL) ?? ""
    }
}

@MainActor
final class NoteStore: ObservableObject {
    static let shared = NoteStore()

    @Published var notes: [Note] = [] {
        didSet {
            pruneCleanupBuffers()
            scheduleSave()
        }
    }

    @Published var allHidden: Bool = false {
        didSet { scheduleSave() }
    }

    /// Base URL for ticket codes, for example "https://company.atlassian.net/browse/".
    @Published var ticketBaseURL: String = "" {
        didSet { scheduleSave() }
    }

    private var saveWorkItem: DispatchWorkItem?

    // MARK: - Paths

    private let directory: URL
    private let notesURL: URL
    private let stateURL: URL
    private let layoutsURL: URL

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Sticky", isDirectory: true)
        self.directory = base
        self.notesURL = base.appendingPathComponent("notes.json")
        self.stateURL = base.appendingPathComponent("state.json")
        self.layoutsURL = base.appendingPathComponent("layouts.json")
        load()
    }

    // MARK: - Loading and saving

    private func load() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // The welcome note only comes back when the file is missing or broken. A list
        // that was deliberately emptied stays empty.
        var loaded: [Note] = []
        if FileManager.default.fileExists(atPath: notesURL.path) {
            do {
                let data = try Data(contentsOf: notesURL)
                loaded = try decoder.decode([Note].self, from: data)
            } catch {
                NSLog("Sticky: could not read notes.json (\(error.localizedDescription)); kept as .bak")
                backupCorruptNotes()
                loaded = [NoteStore.welcomeNote()]
            }
        } else {
            loaded = [NoteStore.welcomeNote()]
        }

        if let data = try? Data(contentsOf: stateURL),
           let state = try? decoder.decode(AppState.self, from: data) {
            allHidden = state.allHidden
            ticketBaseURL = state.ticketBaseURL
        }

        if let data = try? Data(contentsOf: layoutsURL),
           let stored = try? decoder.decode([String: [String: NoteLayoutEntry]].self, from: data) {
            layouts = stored.reduce(into: [:]) { result, pair in
                var perNote: [UUID: NoteLayoutEntry] = [:]
                for (rawID, entry) in pair.value {
                    guard let id = UUID(uuidString: rawID) else { continue }
                    perNote[id] = entry
                }
                if !perNote.isEmpty { result[pair.key] = perNote }
            }
        }

        notes = loaded.map { NoteStore.normalize($0) }
        pruneLayouts()
        saveWorkItem?.cancel()
        saveWorkItem = nil
    }

    /// Sets an unreadable notes file aside so it does not get overwritten right away.
    private func backupCorruptNotes() {
        let backupURL = notesURL.appendingPathExtension("bak")
        try? FileManager.default.removeItem(at: backupURL)
        try? FileManager.default.moveItem(at: notesURL, to: backupURL)
    }

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
    }

    /// Writes synchronously, for example when the app quits.
    func saveNow() {
        saveWorkItem?.cancel()
        saveWorkItem = nil

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = try? encoder.encode(notes) {
            try? data.write(to: notesURL, options: .atomic)
        }
        if let data = try? encoder.encode(AppState(allHidden: allHidden, ticketBaseURL: ticketBaseURL)) {
            try? data.write(to: stateURL, options: .atomic)
        }

        let encodable = layouts.reduce(into: [String: [String: NoteLayoutEntry]]()) { result, pair in
            result[pair.key] = pair.value.reduce(into: [:]) { inner, entry in
                inner[entry.key.uuidString] = entry.value
            }
        }
        if let data = try? encoder.encode(encodable) {
            try? data.write(to: layoutsURL, options: .atomic)
        }
    }

    // MARK: - Layouts per screen configuration

    /// The place of every note, per configuration key. Deliberately not `@Published`, because
    /// updating this table is a consequence of a position change, not a reason for another
    /// sync round of the windows.
    private var layouts: [String: [UUID: NoteLayoutEntry]] = [:]

    func layout(for key: String) -> [UUID: NoteLayoutEntry]? {
        layouts[key]
    }

    /// Records the complete layout of a single configuration.
    func storeLayout(_ entries: [UUID: NoteLayoutEntry], for key: String) {
        guard layouts[key] != entries else { return }
        layouts[key] = entries
        scheduleSave()
    }

    /// Removes a note from all stored layouts, called when deleting.
    func removeFromLayouts(_ id: UUID) {
        var changed = false
        for key in layouts.keys where layouts[key]?[id] != nil {
            layouts[key]?.removeValue(forKey: id)
            if layouts[key]?.isEmpty == true { layouts.removeValue(forKey: key) }
            changed = true
        }
        if changed { scheduleSave() }
    }

    /// Throws away references to notes that no longer exist (deleted while another
    /// configuration was active, for instance).
    private func pruneLayouts() {
        let known = Set(notes.map(\.id))
        var changed = false
        for (key, entries) in layouts {
            let kept = entries.filter { known.contains($0.key) }
            guard kept.count != entries.count else { continue }
            changed = true
            if kept.isEmpty {
                layouts.removeValue(forKey: key)
            } else {
                layouts[key] = kept
            }
        }
        if changed { scheduleSave() }
    }

    // MARK: - Access

    /// Fixed stand-in note for an id that does not (yet) exist. One stable identity,
    /// so a read after deletion does not keep producing new UUIDs.
    static let placeholder = Note(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000000") ?? UUID(),
        lines: [NoteLine(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID())]
    )

    func note(with id: UUID) -> Note? {
        notes.first { $0.id == id }
    }

    func binding(for id: UUID) -> Binding<Note> {
        Binding(
            get: { [weak self] in
                self?.notes.first { $0.id == id } ?? NoteStore.placeholder
            },
            set: { [weak self] newValue in
                guard let self else { return }
                if let index = self.notes.firstIndex(where: { $0.id == id }) {
                    self.notes[index] = newValue
                }
            }
        )
    }

    func update(_ id: UUID, _ mutate: (inout Note) -> Void) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        var copy = notes[index]
        mutate(&copy)
        if copy != notes[index] {
            notes[index] = copy
        }
    }

    @discardableResult
    func addNote(at center: CGPoint? = nil) -> Note {
        var note = Note()
        note.color = NoteColor.allCases.randomElement() ?? .yellow
        let size = Note.defaultSize
        let point = center ?? NoteStore.screenCenter()
        note.frame = CGRect(
            x: point.x - size.width / 2,
            y: point.y - size.height / 2,
            width: size.width,
            height: size.height
        )
        note.frame = NoteStore.clampToScreens(note.frame)
        notes.append(note)
        return note
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        cleanupUndo.removeValue(forKey: id)
        cleanupPost.removeValue(forKey: id)
        removeFromLayouts(id)
    }

    // MARK: - Cleaning up checked lines

    /// One-shot undo buffer holding the previous `lines` of the notes involved in the last
    /// cleanup. Deliberately not a full undo stack; a second cleanup overwrites the buffer
    /// and `undoLastCleanup()` empties it.
    @Published private(set) var cleanupUndo: [UUID: [NoteLine]] = [:]

    /// The state right after the cleanup. If `lines` differs from it, someone has typed in the
    /// meantime and restoring would destroy that work, so the buffer for that note is dropped.
    private var cleanupPost: [UUID: [NoteLine]] = [:]

    var canUndoCleanup: Bool { !cleanupUndo.isEmpty }

    /// Whether ⌘Z within a single note still has something to restore.
    func canUndoCleanup(for id: UUID) -> Bool {
        cleanupUndo[id] != nil
    }

    /// Throws buffers away as soon as the note has changed since the cleanup. Runs on every
    /// mutation of `notes`, so also after typing a single letter.
    private func pruneCleanupBuffers() {
        guard !cleanupUndo.isEmpty else { return }
        let stale = cleanupUndo.keys.filter { id in
            guard let post = cleanupPost[id], let note = note(with: id) else { return true }
            return note.lines != post
        }
        guard !stale.isEmpty else { return }
        for id in stale {
            cleanupUndo.removeValue(forKey: id)
            cleanupPost.removeValue(forKey: id)
        }
    }

    func hasDoneLines(_ id: UUID) -> Bool {
        note(with: id)?.lines.contains { $0.kind == .checklist && $0.isDone } ?? false
    }

    /// Removes all checked checklist lines from one note. Returns how many were removed.
    @discardableResult
    func cleanupDoneLines(in id: UUID) -> Int {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return 0 }
        let previous = notes[index].lines
        let remaining = previous.filter { !($0.kind == .checklist && $0.isDone) }
        guard remaining.count != previous.count else { return 0 }

        let newLines = remaining.isEmpty ? [NoteLine()] : remaining
        // Set before the mutation, because the `didSet` of `notes` checks the buffer right away.
        cleanupUndo = [id: previous]
        cleanupPost = [id: newLines]
        notes[index].lines = newLines
        return previous.count - remaining.count
    }

    /// The same, but for all notes at once.
    @discardableResult
    func cleanupDoneLinesEverywhere() -> Int {
        var buffer: [UUID: [NoteLine]] = [:]
        var post: [UUID: [NoteLine]] = [:]
        var removed = 0

        for index in notes.indices {
            let previous = notes[index].lines
            let remaining = previous.filter { !($0.kind == .checklist && $0.isDone) }
            guard remaining.count != previous.count else { continue }
            let newLines = remaining.isEmpty ? [NoteLine()] : remaining
            buffer[notes[index].id] = previous
            post[notes[index].id] = newLines
            notes[index].lines = newLines
            removed += previous.count - remaining.count
        }

        // Set after the mutations, because every mutation above clears the buffers.
        if !buffer.isEmpty {
            cleanupUndo = buffer
            cleanupPost = post
        }
        return removed
    }

    /// Restores the last cleanup. Works once, after that the buffer is empty.
    ///
    /// With an `id` it is limited to that one note, because ⌘Z inside a panel should never
    /// restore a cleanup of another note. Without an `id` (the menu bar menu) all notes that
    /// have not changed since the cleanup are included.
    func undoLastCleanup(for id: UUID? = nil) {
        let ids = id.map { [$0] } ?? Array(cleanupUndo.keys)
        for noteID in ids {
            guard let lines = cleanupUndo[noteID],
                  let index = notes.firstIndex(where: { $0.id == noteID }) else { continue }
            notes[index].lines = lines
            cleanupUndo.removeValue(forKey: noteID)
            cleanupPost.removeValue(forKey: noteID)
        }
    }

    // MARK: - Helpers

    private static func screenCenter() -> CGPoint {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? fallbackScreenBounds
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    /// Makes sure a note has at least one line and falls within a visible screen.
    private static func normalize(_ note: Note) -> Note {
        var copy = note
        if copy.lines.isEmpty {
            copy.lines = [NoteLine()]
        }
        copy.opacity = Note.clampOpacity(copy.opacity)
        var frame = copy.frame
        if frame.width < Note.minSize.width { frame.size.width = Note.defaultSize.width }
        if frame.height < Note.minSize.height { frame.size.height = Note.defaultSize.height }
        copy.frame = clampToScreens(frame)
        if copy.tuckedEdge != nil {
            let bounds = screenBounds(for: copy.frame)
            copy.tuckedY = min(max(copy.tuckedY, bounds.minY), bounds.maxY - Note.tabSize.height)
        }
        return copy
    }

    /// Clamps a frame within the visible area of the nearest screen.
    static func clampToScreens(_ frame: CGRect) -> CGRect {
        let bounds = screenBounds(for: frame)
        var result = frame
        result.size.width = min(result.width, bounds.width)
        result.size.height = min(result.height, bounds.height)
        result.origin.x = min(max(result.origin.x, bounds.minX), bounds.maxX - result.width)
        result.origin.y = min(max(result.origin.y, bounds.minY), bounds.maxY - result.height)
        return result
    }

    /// Last resort for when no screen at all is reported (temporarily).
    static let fallbackScreenBounds = CGRect(x: 0, y: 0, width: 1440, height: 900)

    /// The visible area of the screen that overlaps this frame the most.
    static func screenBounds(for frame: CGRect) -> CGRect {
        screen(for: frame)?.visibleFrame ?? fallbackScreenBounds
    }

    /// The screen that overlaps this frame the most. Without any overlap, the screen
    /// whose visible area lies closest to the center point of the frame.
    /// `nil` if there is no screen at all (which can happen during a display switch).
    static func screen(for frame: CGRect) -> NSScreen? {
        let candidates = NSScreen.screens
        guard !candidates.isEmpty else { return nil }

        var best: NSScreen?
        var bestArea: CGFloat = 0
        for screen in candidates {
            let intersection = screen.frame.intersection(frame)
            let area = intersection.isNull ? 0 : intersection.width * intersection.height
            if area > bestArea {
                bestArea = area
                best = screen
            }
        }
        if let best { return best }

        let center = CGPoint(x: frame.midX, y: frame.midY)
        return candidates.min { squaredDistance(from: center, to: $0.frame) < squaredDistance(from: center, to: $1.frame) }
    }

    private static func squaredDistance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let x = min(max(point.x, rect.minX), rect.maxX)
        let y = min(max(point.y, rect.minY), rect.maxY)
        let dx = point.x - x
        let dy = point.y - y
        return dx * dx + dy * dy
    }

    private static func welcomeNote() -> Note {
        var note = Note()
        note.title = "Welcome to Sticky"
        note.color = .yellow
        note.lines = [
            NoteLine(text: "Drag the header to move the note."),
            NoteLine(text: "Drag it to the left or right screen edge to tuck it away."),
            NoteLine(text: "Click the tab to bring it back."),
            NoteLine(text: "Enter starts a new line."),
            NoteLine(text: "Type # for a heading, ` for code, --- for a separator."),
            NoteLine(text: "Option-arrows move a line up or down."),
            NoteLine(text: "Type [] at the start for a checkbox.", kind: .checklist),
            NoteLine(text: "Hide everything with option-command-S.", kind: .checklist)
        ]
        let size = Note.defaultSize
        let center = screenCenter()
        note.frame = clampToScreens(
            CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        )
        return note
    }
}
