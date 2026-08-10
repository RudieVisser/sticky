import AppKit

/// Small floating input panel for ⌥⌘N. Type one line and file it away immediately.
@MainActor
final class QuickCapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Manages the quick capture panel.
///
/// - Enter adds the line to the inbox note (the oldest note; if there is none, a new note
///   "Inbox" is created).
/// - Shift-Enter makes an entirely new note with that text.
/// - Esc or a click outside closes it without doing anything.
@MainActor
final class QuickCaptureController: NSObject, NSTextFieldDelegate, NSWindowDelegate {

    private let store: NoteStore
    private weak var manager: NoteWindowManager?

    private var panel: QuickCapturePanel?
    private var field: NSTextField?
    private var clickMonitor: Any?
    private var isClosing = false

    private static let panelSize = CGSize(width: 460, height: 48)

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
        let size = QuickCaptureController.panelSize
        let rect = CGRect(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2,
            width: size.width,
            height: size.height
        )

        let panel = QuickCapturePanel(
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

        let effect = NSVisualEffectView(frame: CGRect(origin: .zero, size: size))
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 10
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true

        let field = NSTextField(frame: CGRect(x: 14, y: 12, width: size.width - 28, height: 24))
        field.autoresizingMask = [.width]
        field.placeholderString = "Quick capture…"
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

        // Without activating, a panel of a background app gets no keyboard focus. The app is
        // an accessory (no Dock icon), so this is visually invisible.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)

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
        if let panel {
            panel.delegate = nil
            panel.orderOut(nil)
            panel.close()
        }
        panel = nil
    }

    /// Short flash as confirmation, then close.
    private func flashAndClose() {
        guard let panel else {
            close()
            return
        }
        isClosing = true
        field?.isEditable = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            panel.animator().alphaValue = 0.25
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                self?.close()
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        guard !isClosing else { return }
        close()
    }

    // MARK: - Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            commit(asNewNote: false)
            return true
        case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
            // Shift-Enter.
            commit(asNewNote: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        default:
            return false
        }
    }

    // MARK: - Filing away

    private func commit(asNewNote: Bool) {
        // Mark as closing right away, because filing away can make another panel key (a new
        // note, for instance), and then `windowDidResignKey` would close this panel before
        // the flash.
        isClosing = true
        let text = (field?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            close()
            return
        }

        if store.allHidden {
            manager?.setAllHidden(false)
        }

        if asNewNote {
            NoteTransfer.makeNote(from: text, store: store, manager: manager)
        } else {
            append(text)
        }
        flashAndClose()
    }

    /// Puts the line at the bottom of the inbox note. An empty last line is reused.
    private func append(_ text: String) {
        let line = NoteTransfer.line(from: text)
        let id = inboxNoteID()
        store.update(id) { note in
            if let last = note.lines.last,
               last.kind == .text,
               last.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                note.lines[note.lines.count - 1] = line
            } else {
                note.lines.append(line)
            }
        }
        manager?.reveal(id)
    }

    /// The first note created. If there is none, a new note "Inbox" is created.
    private func inboxNoteID() -> UUID {
        if let oldest = store.notes.min(by: { $0.createdAt < $1.createdAt }) {
            return oldest.id
        }
        let note = store.addNote()
        store.update(note.id) {
            $0.title = "Inbox"
            $0.lines = [NoteLine()]
        }
        return note.id
    }
}
