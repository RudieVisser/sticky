import AppKit

/// Floating, non-activating panel for one note.
@MainActor
final class NotePanel: NSPanel {

    /// Borderless, both free and tucked: without a titlebar the standard window buttons do
    /// not exist, the SwiftUI content reaches into the top edge and the styleMask never has
    /// to mutate. Resizing is done by `NoteContainerView` itself, including the right cursors.
    static let freeStyle: NSWindow.StyleMask = [.nonactivatingPanel, .borderless]
    static let tuckedStyle: NSWindow.StyleMask = [.nonactivatingPanel, .borderless]

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: NotePanel.freeStyle,
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        // The panel only becomes key when it really needs to (a text field) or when we make
        // it key ourselves. The click handlers (`WindowDragHandle.mouseDown`,
        // `NoteContainerView.mouseDown`) call `makeKeyAndOrderFront` for that, so a click on
        // the header or the edge still activates. If every click made the panel key, then Esc
        // (`cancelOperation` -> orderOut) would hand the key status to *another* note panel
        // instead of to the previous app.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        worksWhenModal = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = false
        acceptsMouseMovedEvents = true
        hideStandardButtons()

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        minSize = Note.minSize
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Cmd-Z inside this panel. The app has no Edit menu, so there is no other taker for
    /// this key combination; we catch it here for the one-shot cleanup undo.
    var onUndo: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           event.charactersIgnoringModifiers?.lowercased() == "z",
           let onUndo {
            onUndo()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// AppKit re-creates the red/yellow/green buttons as soon as a titlebar comes into play
    /// (styleMask mutation, contentView swap). This helper structurally removes them and is
    /// called after *every* such change, even though the style is borderless by now.
    func hideStandardButtons() {
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = standardWindowButton(kind) else { continue }
            button.isHidden = true
            button.removeFromSuperview()
        }
    }

    override var styleMask: NSWindow.StyleMask {
        didSet { hideStandardButtons() }
    }

    override var contentView: NSView? {
        didSet { hideStandardButtons() }
    }

    /// Esc hands the keyboard back to the previous app.
    ///
    /// You are not allowed to call `resignKey()` yourself, and `NSApp.deactivate()` does
    /// nothing for an accessory app that was never activated. Actually taking the panel out
    /// of the window list for a moment lets the system pass the key status on to the window
    /// underneath; after that we put the panel back without making it key, so it stays visible.
    override func cancelOperation(_ sender: Any?) {
        makeFirstResponder(nil)
        guard isKeyWindow else { return }
        orderOut(nil)
        orderFrontRegardless()
    }
}
