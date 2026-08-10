import AppKit

/// Floating little search panel: typing filters the notes live, Enter brings the top hit into view.
@MainActor
final class NoteSearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// One row in the hit list: color dot, title and the line the hit is in.
@MainActor
private final class NoteSearchRow: NSView {

    var onClick: (() -> Void)?

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            needsDisplay = true
            applyColors()
        }
    }

    private let dot = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    static let height: CGFloat = 34

    init(width: CGFloat, color: NoteColor, title: String, detail: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: NoteSearchRow.height))
        autoresizingMask = [.width]

        dot.image = NoteSearchRow.dotImage(for: color)
        dot.frame = NSRect(x: 16, y: (NoteSearchRow.height - 10) / 2, width: 10, height: 10)
        addSubview(dot)

        titleLabel.stringValue = title
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.frame = NSRect(x: 34, y: 16, width: width - 48, height: 16)
        titleLabel.autoresizingMask = [.width]
        addSubview(titleLabel)

        detailLabel.stringValue = detail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.frame = NSRect(x: 34, y: 2, width: width - 48, height: 14)
        detailLabel.autoresizingMask = [.width]
        addSubview(detailLabel)

        applyColors()
    }

    required init?(coder: NSCoder) { nil }

    private func applyColors() {
        titleLabel.textColor = isSelected ? .white : .labelColor
        detailLabel.textColor = isSelected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 8, dy: 1), xRadius: 6, yRadius: 6).fill()
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    private static func dotImage(for color: NoteColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.nsAccent.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}

/// Searching through all notes from the menu bar.
///
/// Deliberately its own floating little panel (like `QuickCaptureController`) and not a search
/// field inside the NSMenu: an `NSMenu` runs its own event loop while it is open and swallows
/// key presses for its type-select, which makes an `NSSearchField` in a menu item hold focus
/// unreliably in an accessory app. The little panel simply gets key status and can therefore
/// also handle the arrow keys and Esc neatly.
@MainActor
final class NoteSearchController: NSObject, NSTextFieldDelegate, NSWindowDelegate {

    private let store: NoteStore
    private weak var manager: NoteWindowManager?

    private var panel: NoteSearchPanel?
    private var field: NSTextField?
    private var listView: NSView?
    private var rows: [NoteSearchRow] = []
    private var results: [Note] = []
    private var selection = 0
    private var clickMonitor: Any?
    private var isClosing = false

    private static let panelWidth: CGFloat = 420
    private static let fieldHeight: CGFloat = 44
    private static let maxRows = 7

    init(store: NoteStore, manager: NoteWindowManager) {
        self.store = store
        self.manager = manager
        super.init()
    }

    // MARK: - Showing and closing

    func toggle() {
        if panel != nil {
            close()
        } else {
            present()
        }
    }

    func present() {
        close()
        isClosing = false

        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NoteStore.fallbackScreenBounds
        let width = NoteSearchController.panelWidth
        let height = NoteSearchController.fieldHeight
        let rect = CGRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )

        let panel = NoteSearchPanel(
            contentRect: rect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.delegate = self

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: rect.size))
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let list = NSView(frame: CGRect(x: 0, y: 0, width: width, height: 0))
        list.autoresizingMask = [.width]
        effect.addSubview(list)

        let field = NSTextField(frame: NSRect(x: 14, y: 10, width: width - 28, height: 24))
        field.autoresizingMask = [.width, .minYMargin]
        field.placeholderString = "Search notes…"
        field.font = .systemFont(ofSize: 15)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        effect.addSubview(field)

        panel.contentView = effect
        self.panel = panel
        self.field = field
        self.listView = list

        // Without activating, a panel of a background app gets no keyboard focus.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

        updateResults(for: "")

        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.close()
            }
        }
    }

    func close() {
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        field?.delegate = nil
        field = nil
        listView = nil
        rows = []
        results = []
        selection = 0
        if let panel {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing else { return }
        close()
    }

    // MARK: - Keys

    func controlTextDidChange(_ obj: Notification) {
        updateResults(for: field?.stringValue ?? "")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            reveal(at: selection)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(-1)
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    private func moveSelection(_ delta: Int) {
        // Never past the rows on screen: otherwise the highlight moves out of view and
        // Enter opens a hit you cannot see.
        let last = min(results.count, NoteSearchController.maxRows) - 1
        guard last >= 0 else { return }
        selection = min(max(selection + delta, 0), last)
        for (index, row) in rows.enumerated() {
            row.isSelected = index == selection
        }
    }

    private func reveal(at index: Int) {
        guard index >= 0, index < results.count else {
            NSSound.beep()
            return
        }
        let id = results[index].id
        isClosing = true
        close()
        manager?.reveal(id)
    }

    // MARK: - Filtering

    /// Case and accent insensitive comparison.
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func matches(_ note: Note, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if NoteSearchController.fold(note.title).contains(query) { return true }
        return note.lines.contains { NoteSearchController.fold($0.text).contains(query) }
    }

    /// The line the hit is in. If the hit is only in the title (or there is no search
    /// term), we show the first filled line instead of an empty detail line.
    private func detail(for note: Note, query: String) -> String {
        func firstFilled(_ extra: (NoteLine) -> Bool) -> NoteLine? {
            note.lines.first {
                !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && extra($0)
            }
        }
        let match = query.isEmpty
            ? firstFilled { _ in true }
            : firstFilled { NoteSearchController.fold($0.text).contains(query) } ?? firstFilled { _ in true }
        let text = match?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(text.prefix(70))
    }

    private func updateResults(for rawQuery: String) {
        let query = NoteSearchController.fold(rawQuery.trimmingCharacters(in: .whitespacesAndNewlines))
        results = store.notes.filter { matches($0, query: query) }
        selection = results.isEmpty ? -1 : 0
        rebuildRows(query: query)
    }

    private func rebuildRows(query: String) {
        guard let panel, let list = listView else { return }

        rows.forEach { $0.removeFromSuperview() }
        rows = []

        let width = NoteSearchController.panelWidth
        let shown = Array(results.prefix(NoteSearchController.maxRows))
        let rowHeight = NoteSearchRow.height
        let listHeight = shown.isEmpty ? 0 : CGFloat(shown.count) * rowHeight + 6

        // Rows from top to bottom; the list itself sits below the search field.
        for (index, note) in shown.enumerated() {
            let row = NoteSearchRow(
                width: width,
                color: note.color,
                title: note.menuTitle,
                detail: detail(for: note, query: query)
            )
            row.frame.origin = CGPoint(
                x: 0,
                y: listHeight - 3 - CGFloat(index + 1) * rowHeight
            )
            row.isSelected = index == selection
            row.onClick = { [weak self] in
                self?.reveal(at: index)
            }
            list.addSubview(row)
            rows.append(row)
        }

        let height = NoteSearchController.fieldHeight + listHeight
        list.frame = CGRect(x: 0, y: 0, width: width, height: listHeight)

        var frame = panel.frame
        // The top edge stays put; the list grows downward.
        frame.origin.y += frame.height - height
        frame.size.height = height
        panel.setFrame(frame, display: true)
    }
}
