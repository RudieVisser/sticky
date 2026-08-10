import AppKit
import Combine
import ServiceManagement
import SwiftUI

/// The menu bar icon with its menu.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {

    private let store: NoteStore
    private let manager: NoteWindowManager
    private let quickCapture: QuickCaptureController
    private let search: NoteSearchController
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(
        store: NoteStore,
        manager: NoteWindowManager,
        quickCapture: QuickCaptureController,
        search: NoteSearchController
    ) {
        self.store = store
        self.manager = manager
        self.quickCapture = quickCapture
        self.search = search
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Sticky")
            button.image?.isTemplate = true
            button.toolTip = "Sticky"
        }

        // Without this, AppKit decides the enabled state itself (based on the responder chain)
        // and the manual `isEnabled` below does nothing at all.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        let newItem = NSMenuItem(title: "New Note", action: #selector(newNote), keyEquivalent: "n")
        newItem.target = self
        menu.addItem(newItem)

        let captureItem = NSMenuItem(
            title: "Quick Capture…",
            action: #selector(quickCaptureAction),
            keyEquivalent: "n"
        )
        captureItem.keyEquivalentModifierMask = [.option, .command]
        captureItem.target = self
        menu.addItem(captureItem)

        let clipboardItem = NSMenuItem(
            title: "Note from Clipboard",
            action: #selector(noteFromClipboard),
            keyEquivalent: "v"
        )
        clipboardItem.keyEquivalentModifierMask = [.option, .command]
        clipboardItem.target = self
        menu.addItem(clipboardItem)

        // ⌘F works as long as this menu is open, and it opens the floating search panel.
        let searchItem = NSMenuItem(
            title: "Find Note…",
            action: #selector(searchNotes),
            keyEquivalent: "f"
        )
        searchItem.keyEquivalentModifierMask = [.command]
        searchItem.target = self
        searchItem.isEnabled = !store.notes.isEmpty
        menu.addItem(searchItem)

        let cleanupItem = NSMenuItem(
            title: "Clean Up Checked Lines",
            action: #selector(cleanupDone),
            keyEquivalent: ""
        )
        cleanupItem.target = self
        cleanupItem.isEnabled = store.notes.contains { note in
            note.lines.contains { $0.kind == .checklist && $0.isDone }
        }
        menu.addItem(cleanupItem)

        if store.canUndoCleanup {
            let undoItem = NSMenuItem(
                title: "Undo Cleanup",
                action: #selector(undoCleanup),
                keyEquivalent: ""
            )
            undoItem.target = self
            menu.addItem(undoItem)
        }

        let toggleItem = NSMenuItem(
            title: store.allHidden ? "Show All" : "Hide All",
            action: #selector(toggleHidden),
            keyEquivalent: "s"
        )
        toggleItem.keyEquivalentModifierMask = [.option, .command]
        toggleItem.target = self
        menu.addItem(toggleItem)

        menu.addItem(.separator())

        if store.notes.isEmpty {
            let empty = NSMenuItem(title: "No notes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for note in store.notes {
                let item = NSMenuItem(title: note.menuTitle, action: #selector(revealNote(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = note.id.uuidString
                item.image = StatusBarController.dotImage(for: note.color)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let ticketItem = NSMenuItem(
            title: "Set Ticket URL…",
            action: #selector(editTicketURL),
            keyEquivalent: ""
        )
        ticketItem.target = self
        menu.addItem(ticketItem)

        let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)

        let quitItem = NSMenuItem(title: "Quit Sticky", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private static func dotImage(for color: NoteColor) -> NSImage {
        let size = NSSize(width: 10, height: 10)
        let image = NSImage(size: size)
        image.lockFocus()
        color.nsAccent.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    // MARK: - Actions

    @objc private func newNote() {
        manager.newNote()
    }

    @objc private func toggleHidden() {
        manager.toggleAllHidden()
    }

    @objc private func quickCaptureAction() {
        quickCapture.present()
    }

    @objc private func searchNotes() {
        search.present()
    }

    @objc private func noteFromClipboard() {
        if NoteTransfer.makeNoteFromClipboard(store: store, manager: manager) == nil {
            NSSound.beep()
        }
    }

    @objc private func cleanupDone() {
        store.cleanupDoneLinesEverywhere()
    }

    @objc private func undoCleanup() {
        store.undoLastCleanup()
    }

    @objc private func revealNote(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let id = UUID(uuidString: raw) else { return }
        manager.reveal(id)
    }

    /// Small input panel for the base URL that ticket codes are appended to.
    @objc private func editTicketURL() {
        let alert = NSAlert()
        alert.messageText = "Set Ticket URL"
        alert.informativeText = """
            Cmd-click on a ticket code such as ABC-123 opens this URL with the code appended.
            For example https://yourcompany.atlassian.net/browse/
            Leave the field empty to make ticket codes non-clickable.
            """

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.stringValue = store.ticketBaseURL
        field.placeholderString = "https://yourcompany.atlassian.net/browse/"
        alert.accessoryView = field

        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field

        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            store.ticketBaseURL = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @objc private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
        } catch {
            NSLog("Sticky: could not change Launch at Login: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Launch at Login could not be changed"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        rebuildMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
