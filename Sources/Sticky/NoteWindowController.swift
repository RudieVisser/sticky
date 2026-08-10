import AppKit
import Combine
import SwiftUI

/// Manages the panel of a single note: position, size, tuck behaviour.
@MainActor
final class NoteWindowController: NSObject, NSWindowDelegate {

    let noteID: UUID
    let panel: NotePanel

    private unowned let store: NoteStore
    private weak var manager: NoteWindowManager?

    private var dragWatcher: Timer?

    /// A counter instead of a Bool: overlapping animations do not release each other too early.
    private var animationCount = 0
    private var isAnimating: Bool { animationCount > 0 }

    /// Guards whether the panel is supposed to be visible; a fade-out must not overtake a `show()`.
    private var wantsVisible = false
    private var visibilityGeneration = 0

    /// Last known edge, still valid even when the note has already disappeared from the store.
    private(set) var lastKnownEdge: TuckEdge?

    /// Mouse over the note: it is then always fully readable, regardless of the configured opacity.
    private var isHovering = false

    /// During our own resize drag, `windowDidMove` is not a drag gesture.
    private var isResizing = false

    /// A real drag with the mouse button held down is in progress. Only then may `finishDrag()`
    /// write the panel position into the model; system moves (unplugging a screen, a resolution
    /// change) shift the panel without a mouse button and should stay out of it.
    private var isDragging = false

    /// Window state for the SwiftUI content (activation, edge glow). Independent of the model.
    private let chrome = NoteChrome()

    /// The container view of the current panel; it receives the activation state.
    private weak var container: NoteContainerView?

    /// During the last drag the mouse touched this screen edge.
    private var mouseEdge: TuckEdge?

    /// The note is temporarily half in view because the mouse is resting on the tab. Purely
    /// visual: `tuckedEdge` simply stays put, nothing changes in the model.
    private(set) var isPeeking = false

    /// Where the panel comes from during a peek and slides back to (just off screen).
    private var peekHiddenFrame: CGRect = .zero

    /// Deferred start or retraction of a peek.
    private var peekWork: DispatchWorkItem?

    /// Watches during a peek whether the mouse is still over the panel. The mouse-exit of the
    /// tracking area alone is not enough: the panel slides out from under the mouse.
    private var peekWatcher: Timer?
    private var peekOutsideSince: Date?

    /// The dangling buddy: the rope window below the note. Nil as long as there is only a knob.
    private var buddy: DanglingBuddyController?

    init(noteID: UUID, store: NoteStore, manager: NoteWindowManager) {
        self.noteID = noteID
        self.store = store
        self.manager = manager

        let note = store.note(with: noteID) ?? NoteStore.placeholder
        self.lastKnownEdge = note.tuckedEdge
        let startFrame = note.tuckedEdge == nil
            ? NoteStore.clampToScreens(note.frame)
            : NoteWindowController.tabFrame(for: note)
        self.panel = NotePanel(contentRect: startFrame)

        super.init()

        panel.delegate = self
        // The store keeps no reference back to the panel, so this is not a cycle.
        let store = self.store
        // ⌘Z inside *this* panel only undoes the cleanup action of *this same* note.
        let id = noteID
        panel.onUndo = {
            store.undoLastCleanup(for: id)
        }
        applyContent(note.tuckedEdge != nil ? .tab : .free)
        if note.tuckedEdge != nil {
            panel.styleMask = NotePanel.tuckedStyle
            panel.minSize = Note.tabSize
        }
        panel.alphaValue = effectiveAlpha
    }

    private var note: Note {
        store.note(with: noteID) ?? NoteStore.placeholder
    }

    // MARK: - Content

    /// What the panel shows. `.peek` shows the same note content as `.free`, but untouchable:
    /// there is a click catcher on top of it that untucks the note.
    private enum ContentMode {
        case free, tab, peek
    }

    private func applyContent(_ mode: ContentMode) {
        let hosting: NSView
        if mode == .tab {
            hosting = NSHostingView(
                rootView: TuckTabView(store: store, noteID: noteID) { [weak self] in
                    self?.untuck()
                }
            )
        } else {
            hosting = NSHostingView(
                rootView: NoteView(store: store, chrome: chrome, noteID: noteID) { [weak panel = self.panel] in
                    // A popover refuses to open from a window that is not key; on a
                    // nonactivating panel we therefore have to force that ourselves.
                    panel?.makeKeyAndOrderFront(nil)
                }
            )
        }

        // The old container may no longer report hover: its mouse-exit arrives *after* the
        // switch and would immediately break off a peek that just started.
        container?.onHoverChange = nil

        // The hosting view fills the whole panel: no more titlebar inset, so no empty strip
        // above the header.
        let container = NoteContainerView(frame: CGRect(origin: .zero, size: panel.frame.size))
        container.autoresizingMask = [.width, .height]
        container.isResizable = (mode == .free)
        container.onHoverChange = { [weak self] hovering in
            self?.setHovering(hovering)
        }
        container.onResizeBegan = { [weak self] in
            self?.isResizing = true
        }
        container.onResizeEnded = { [weak self] in
            guard let self else { return }
            self.isResizing = false
            self.store.update(self.noteID) { $0.frame = self.panel.frame }
        }
        container.isActivated = panel.isKeyWindow
        // Only a free note carries the knob: a tab is too small for it, and during a peek the
        // note cannot be touched anyway.
        container.showsKnob = (mode == .free)
        container.knobColor = note.color
        container.isKnobEngaged = (buddy != nil)
        container.onKnobClick = { [weak self] in
            self?.toggleBuddy()
        }
        if mode == .peek {
            container.setContent(hosting) { [weak self] in
                self?.untuck()
            }
        } else {
            container.setContent(hosting)
        }

        panel.contentView = container
        self.container = container
        panel.hideStandardButtons()
        panel.invalidateShadow()
    }

    // MARK: - Dangling buddy

    /// Click on the knob: roll out the rope, or roll the hanging rope back up.
    private func toggleBuddy() {
        if let buddy {
            buddy.retract()
            return
        }
        guard note.tuckedEdge == nil, !isPeeking, wantsVisible, panel.isVisible else { return }
        let controller = DanglingBuddyController(panel: panel, color: note.color)
        controller.onFinish = { [weak self] in
            guard let self else { return }
            self.buddy = nil
            self.container?.isKnobEngaged = false
        }
        buddy = controller
        container?.isKnobEngaged = true
    }

    /// Gone right away: tucking, hiding, deleting, quitting.
    private func dismissBuddy() {
        guard let buddy else { return }
        self.buddy = nil
        buddy.onFinish = nil
        buddy.dismiss()
        container?.isKnobEngaged = false
    }

    // MARK: - Activation

    /// A click anywhere on the note makes the panel key; *that* is the activation. Only then do
    /// we show hover cursors. Clicking in another app makes the panel resign key and resets
    /// everything.
    private func setActivated(_ activated: Bool) {
        chrome.isActivated = activated
        container?.isActivated = activated
        panel.invalidateShadow()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        setActivated(true)
    }

    func windowDidResignKey(_ notification: Notification) {
        setActivated(false)
    }

    // MARK: - Opacity

    /// The alpha the panel should have when it is simply visible.
    private var effectiveAlpha: CGFloat {
        // If the mouse touches a screen edge during a drag, the note becomes slightly
        // transparent: that is the announcement that releasing will tuck it.
        if chrome.isEdgeHighlighted { return 0.55 }
        return isHovering ? CGFloat(Note.maxOpacity) : CGFloat(Note.clampOpacity(note.opacity))
    }

    private func setHovering(_ hovering: Bool) {
        guard isHovering != hovering else { return }
        isHovering = hovering
        if note.tuckedEdge != nil {
            if hovering {
                schedulePeek()
            } else if isPeeking {
                schedulePeekRetract()
            } else {
                cancelPeekWork()
            }
        }
        guard wantsVisible, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = effectiveAlpha
        }
    }

    /// Follows a changed `opacity` in the store.
    func refreshOpacity() {
        // Runs along with every model change, so a new note colour lands here as well.
        buddy?.color = note.color
        container?.knobColor = note.color
        guard wantsVisible, panel.isVisible else { return }
        let target = effectiveAlpha
        guard abs(panel.alphaValue - target) > 0.001 else { return }
        panel.alphaValue = target
    }

    // MARK: - Peek

    /// How long the mouse has to rest on the tab before the note appears. Long enough that a
    /// mouse flying past does not trigger it.
    private static let peekDelay: TimeInterval = 0.4
    /// How long after the mouse leaves the note slides away again.
    private static let peekRetractDelay: TimeInterval = 0.2
    /// Never wider than this in view, not even for a wide note.
    private static let peekMaxWidth: CGFloat = 180

    private func schedulePeek() {
        cancelPeekWork()
        guard !isPeeking, note.tuckedEdge != nil, wantsVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.beginPeek() }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + NoteWindowController.peekDelay, execute: work)
    }

    private func schedulePeekRetract() {
        cancelPeekWork()
        guard isPeeking else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.endPeek(animated: true) }
        }
        peekWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NoteWindowController.peekRetractDelay,
            execute: work
        )
    }

    private func cancelPeekWork() {
        peekWork?.cancel()
        peekWork = nil
    }

    private func beginPeek() {
        peekWork = nil
        guard !isPeeking, wantsVisible, panel.isVisible else { return }
        guard let edge = note.tuckedEdge else { return }
        // A running animation or a pressed mouse button (in which case this is a drag of the
        // tab) is a temporary blockade: as long as the mouse keeps hovering we try again,
        // otherwise the peek would be off the table for good until you left the tab again.
        guard !isAnimating, NSEvent.pressedMouseButtons & 0x1 == 0 else {
            if isHovering { schedulePeek() }
            return
        }

        let current = note
        var size = current.frame.size
        size.width = max(size.width, Note.minSize.width)
        size.height = max(size.height, Note.minSize.height)

        let visible = NoteStore.screenBounds(for: panel.frame)
        let tab = panel.frame
        var y = tab.midY - size.height / 2
        y = min(max(y, visible.minY), max(visible.minY, visible.maxY - size.height))

        let shownWidth = min(size.width * 0.5, NoteWindowController.peekMaxWidth)
        peekHiddenFrame = CGRect(
            x: edge == .left ? visible.minX - size.width : visible.maxX,
            y: y,
            width: size.width,
            height: size.height
        )
        let target = CGRect(
            x: edge == .left ? visible.minX + shownWidth - size.width : visible.maxX - shownWidth,
            y: y,
            width: size.width,
            height: size.height
        )

        isPeeking = true
        peekOutsideSince = nil
        applyContent(.peek)

        // First put it in place invisibly (off screen), then slide it inwards.
        setFrameNow(peekHiddenFrame, display: false)
        panel.hideStandardButtons()
        animate(to: target, completion: nil)
        startPeekWatcher()
    }

    /// Puts the peek back to the tab. Does not touch the model.
    private func endPeek(animated: Bool) {
        cancelPeekWork()
        stopPeekWatcher()
        guard isPeeking else { return }
        isPeeking = false

        // Untuck has taken over: it puts the note in its free spot itself.
        guard let edge = note.tuckedEdge else { return }

        let restore: () -> Void = { [weak self] in
            guard let self, self.note.tuckedEdge != nil else { return }
            self.applyContent(.tab)
            self.setFrameNow(NoteWindowController.tabFrame(for: self.note))
            self.panel.hideStandardButtons()
            self.manager?.relayoutTucked(edge: edge, animated: false)
            // The panel just changed size; determine the hover state again, otherwise the note
            // stays fully opaque while the mouse has long gone.
            self.syncHoverWithMouse()
        }

        if animated {
            animate(to: peekHiddenFrame, duration: 0.2) { restore() }
        } else {
            restore()
        }
    }

    private func startPeekWatcher() {
        stopPeekWatcher()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isPeeking else { return }
                // A drag breaks off the peek immediately.
                if NSEvent.pressedMouseButtons & 0x1 != 0 {
                    self.endPeek(animated: true)
                    return
                }
                if self.panel.frame.contains(NSEvent.mouseLocation) {
                    self.peekOutsideSince = nil
                    return
                }
                let since = self.peekOutsideSince ?? Date()
                self.peekOutsideSince = since
                if Date().timeIntervalSince(since) >= NoteWindowController.peekRetractDelay {
                    self.endPeek(animated: true)
                }
            }
        }
        peekWatcher = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func syncHoverWithMouse() {
        // A panel that is not supposed to be visible is by definition not hovering: otherwise
        // it comes back after "Show All" at alpha 1.0 instead of its own opacity.
        guard wantsVisible else {
            isHovering = false
            return
        }
        setHovering(panel.frame.contains(NSEvent.mouseLocation))
    }

    private func stopPeekWatcher() {
        peekWatcher?.invalidate()
        peekWatcher = nil
        peekOutsideSince = nil
    }

    // MARK: - Showing and hiding

    func show(animated: Bool = false) {
        wantsVisible = true
        visibilityGeneration &+= 1
        let target = effectiveAlpha

        if animated {
            // If the panel was already visible (for example halfway through a fade-out), we
            // fade further upwards from the current alpha instead of first hard-setting it to 0.
            if !panel.isVisible {
                panel.alphaValue = 0
            }
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = target
            }
        } else {
            panel.alphaValue = target
            panel.orderFrontRegardless()
        }
        panel.hideStandardButtons()
    }

    func hide(animated: Bool = true) {
        wantsVisible = false
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        dismissBuddy()
        // End the peek first, and only then clear the hover: `endPeek` re-checks the hover
        // state against the mouse position and would otherwise set it back to true.
        // The panel goes orderOut afterwards, so no mouseExited comes along to fix that.
        endPeek(animated: false)
        isHovering = false

        guard panel.isVisible else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                panel.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // If there has been a show() since the fade started, we leave the panel
                    // alone; otherwise it disappears while allHidden is false.
                    guard generation == self.visibilityGeneration, !self.wantsVisible else { return }
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = self.effectiveAlpha
                }
            }
        } else {
            panel.orderOut(nil)
            panel.alphaValue = effectiveAlpha
        }
    }

    func close() {
        dismissBuddy()
        dragWatcher?.invalidate()
        dragWatcher = nil
        isDragging = false
        cancelPeekWork()
        stopPeekWatcher()
        isPeeking = false
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    /// A short flash so you can see which note is meant.
    func flash() {
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 0.35
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.12
                    self.panel.animator().alphaValue = self.effectiveAlpha
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard !isAnimating, !isResizing, !isPeeking else { return }
        // A screen change is being handled: the system moves panels around itself. Those
        // positions do not belong in the model, and certainly not under the old layout key.
        guard manager?.isScreenChangePending != true else { return }
        // Without a pressed mouse button this is not a drag gesture but a system move.
        guard NSEvent.pressedMouseButtons & 0x1 != 0 else { return }
        startDragWatcher()
    }

    func windowDidResize(_ notification: Notification) {
        guard !isAnimating, !isPeeking, note.tuckedEdge == nil else { return }
        guard manager?.isScreenChangePending != true else { return }
        store.update(noteID) { $0.frame = panel.frame }
    }

    private func startDragWatcher() {
        isDragging = true
        guard dragWatcher == nil else { return }
        // The timer is not captured in its own closure (that is a data race under strict
        // concurrency); we work via self.dragWatcher inside the MainActor.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard NSEvent.pressedMouseButtons & 0x1 == 0 else {
                    // Still dragging: the edge glow follows the mouse position.
                    self.updateEdgeHighlight()
                    return
                }
                self.dragWatcher?.invalidate()
                self.dragWatcher = nil
                self.finishDrag()
            }
        }
        dragWatcher = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// While dragging: if the mouse touches a real screen edge, give feedback.
    private func updateEdgeHighlight() {
        guard note.tuckedEdge == nil else { return }
        let edge = NoteWindowController.tuckEdgeUnderMouse()
        guard edge != mouseEdge else { return }
        mouseEdge = edge
        setEdgeHighlighted(edge != nil)
    }

    private func setEdgeHighlighted(_ highlighted: Bool) {
        guard chrome.isEdgeHighlighted != highlighted else { return }
        chrome.isEdgeHighlighted = highlighted
        guard wantsVisible, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = effectiveAlpha
        }
    }

    /// Mouse released after a drag: tuck, untuck or simply save the position.
    ///
    /// Runs exclusively after a real drag. If the system moves the panel (unplugging a screen,
    /// a resolution change), `isDragging` is false and the model stays untouched: otherwise
    /// those polluted positions would land under the old layout key.
    private func finishDrag() {
        dragWatcher?.invalidate()
        dragWatcher = nil

        let wasDragging = isDragging
        isDragging = false
        guard wasDragging else { return }

        // During a peek, panel.frame is a temporary spot; that belongs nowhere in the model.
        guard !isPeeking else { return }

        // The mouse position at the moment of release is what decides the tucking.
        let releaseEdge = NoteWindowController.tuckEdgeUnderMouse()
        mouseEdge = nil
        setEdgeHighlighted(false)

        // During a tuck/untuck animation, panel.frame is an intermediate frame; that must
        // never end up in the store as a free position.
        guard !isAnimating else { return }

        let current = note
        if let edge = current.tuckedEdge {
            // Dragging the tab vertically along the edge, possibly to another screen.
            let panelFrame = panel.frame
            let oldScreen = NoteStore.screen(for: current.frame)
            let newScreen = NoteStore.screen(for: panelFrame)
            let moved = oldScreen !== newScreen

            store.update(noteID) {
                $0.tuckedY = panelFrame.origin.y
                if moved {
                    // The free frame moves along proportionally, otherwise relayoutTucked
                    // clamps the tab back to the old screen.
                    $0.frame = NoteWindowController.convertFrame(
                        $0.frame,
                        from: oldScreen?.visibleFrame ?? NoteStore.fallbackScreenBounds,
                        to: newScreen?.visibleFrame ?? NoteStore.fallbackScreenBounds
                    )
                }
            }
            manager?.relayoutTucked(edge: edge, animated: true)
            return
        }

        let frame = panel.frame
        let visible = NoteStore.screenBounds(for: frame)

        // First trigger: the mouse touches a real screen edge. Second trigger (unchanged):
        // the window centre lies beyond the edge or hangs over it by more than 40%.
        if let releaseEdge {
            tuck(to: releaseEdge)
            return
        }

        let overLeft = visible.minX - frame.minX
        let overRight = frame.maxX - visible.maxX

        if frame.midX < visible.minX || overLeft > frame.width * 0.4 {
            tuck(to: .left)
        } else if frame.midX > visible.maxX || overRight > frame.width * 0.4 {
            tuck(to: .right)
        } else {
            store.update(noteID) { $0.frame = frame }
        }
    }

    // MARK: - Screen edges

    /// How close the mouse has to be to the edge before it counts as "edge touched".
    private static let edgeThreshold: CGFloat = 2

    /// The edge the mouse is up against right *now*, or `nil`.
    ///
    /// Only a real screen edge counts: if there is an adjacent screen on that side (a seamless
    /// transition), you want to be able to move through it instead, so we do not tuck.
    static func tuckEdgeUnderMouse() -> TuckEdge? {
        let location = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(location) })
            ?? NSScreen.screens.min(by: {
                abs($0.frame.midX - location.x) < abs($1.frame.midX - location.x)
            }) else { return nil }

        let frame = screen.frame
        let threshold = edgeThreshold

        if location.x <= frame.minX + threshold,
           !hasNeighbour(at: CGPoint(x: frame.minX - 2, y: location.y), excluding: screen) {
            return .left
        }
        if location.x >= frame.maxX - threshold,
           !hasNeighbour(at: CGPoint(x: frame.maxX + 1, y: location.y), excluding: screen) {
            return .right
        }
        return nil
    }

    private static func hasNeighbour(at point: CGPoint, excluding screen: NSScreen) -> Bool {
        NSScreen.screens.contains { $0 !== screen && $0.frame.contains(point) }
    }

    // MARK: - Tuck

    /// Moves a frame proportionally from one visible screen area to another.
    static func convertFrame(_ frame: CGRect, from source: CGRect, to target: CGRect) -> CGRect {
        guard source.width > 0, source.height > 0 else { return NoteStore.clampToScreens(frame) }
        let relX = (frame.minX - source.minX) / source.width
        let relY = (frame.minY - source.minY) / source.height
        var result = frame
        result.size.width = min(frame.width, target.width)
        result.size.height = min(frame.height, target.height)
        result.origin.x = target.minX + relX * target.width
        result.origin.y = target.minY + relY * target.height
        return NoteStore.clampToScreens(result)
    }

    static func tabFrame(for note: Note) -> CGRect {
        let visible = NoteStore.screenBounds(for: note.frame)
        let size = Note.tabSize
        let x: CGFloat = (note.tuckedEdge == .right)
            ? visible.maxX - size.width
            : visible.minX
        let y = min(max(note.tuckedY, visible.minY), visible.maxY - size.height)
        return CGRect(x: x, y: y, width: size.width, height: size.height)
    }

    func tuck(to edge: TuckEdge) {
        dismissBuddy()
        dragWatcher?.invalidate()
        dragWatcher = nil
        isDragging = false
        cancelPeekWork()
        stopPeekWatcher()
        isPeeking = false

        let freeFrame = panel.frame
        let visible = NoteStore.screenBounds(for: freeFrame)
        let desiredY = min(max(freeFrame.midY - Note.tabSize.height / 2, visible.minY), visible.maxY - Note.tabSize.height)

        store.update(noteID) {
            $0.frame = NoteStore.clampToScreens(freeFrame)
            $0.tuckedEdge = edge
            $0.tuckedY = desiredY
        }
        lastKnownEdge = edge

        panel.styleMask = NotePanel.tuckedStyle
        panel.minSize = Note.tabSize
        applyContent(.tab)
        // The hover state of the big note says nothing about the small tab any more; determine
        // it again once the tab is in place, otherwise a mouse that is already over the new tab
        // does not count as hover and so no peek follows either.
        isHovering = false

        let target = CGRect(
            x: edge == .left ? visible.minX : visible.maxX - Note.tabSize.width,
            y: desiredY,
            width: Note.tabSize.width,
            height: Note.tabSize.height
        )
        animate(to: target) { [weak self] in
            guard let self else { return }
            self.manager?.relayoutTucked(edge: edge, animated: true)
            self.syncHoverWithMouse()
        }
    }

    func untuck() {
        guard let edge = note.tuckedEdge else { return }
        dragWatcher?.invalidate()
        dragWatcher = nil
        isDragging = false
        // A running peek simply hands the panel over: the note slides on to its free spot
        // instead of gliding back first.
        cancelPeekWork()
        stopPeekWatcher()
        isPeeking = false

        let target = NoteStore.clampToScreens(note.frame)

        store.update(noteID) {
            $0.tuckedEdge = nil
            $0.frame = target
        }
        lastKnownEdge = nil

        panel.styleMask = NotePanel.freeStyle
        panel.minSize = Note.minSize
        applyContent(.free)
        animate(to: target) { [weak self] in
            guard let self else { return }
            self.panel.orderFrontRegardless()
            self.panel.hideStandardButtons()
            self.manager?.relayoutTucked(edge: edge, animated: true)
        }
    }

    /// Moves the tab without changing the tuck state.
    func setTabFrame(_ frame: CGRect, animated: Bool) {
        guard note.tuckedEdge != nil, !isPeeking else { return }
        guard panel.frame != frame else { return }
        if animated {
            animate(to: frame, duration: 0.15, completion: nil)
        } else {
            setFrameNow(frame)
        }
    }

    // MARK: - Layout per screen configuration

    /// Puts the note in the spot that belongs to the new screen configuration. The model
    /// follows immediately (it is the source for the active configuration), the panel slides
    /// over to it.
    func applyLayout(_ entry: NoteLayoutEntry, animated: Bool) {
        // A screen change moves everything at once; the rope simply goes away then.
        dismissBuddy()
        endPeek(animated: false)

        let wasTucked = note.tuckedEdge != nil
        let freeFrame = NoteStore.clampToScreens(entry.frame)

        store.update(noteID) {
            $0.frame = freeFrame
            $0.tuckedEdge = entry.tuckedEdge
            $0.tuckedY = entry.tuckedY
        }
        lastKnownEdge = entry.tuckedEdge

        if entry.tuckedEdge != nil {
            if !wasTucked {
                panel.styleMask = NotePanel.tuckedStyle
                panel.minSize = Note.tabSize
                applyContent(.tab)
            }
            move(to: NoteWindowController.tabFrame(for: note), animated: animated)
        } else {
            if wasTucked {
                panel.styleMask = NotePanel.freeStyle
                panel.minSize = Note.minSize
                applyContent(.free)
            }
            move(to: freeFrame, animated: animated)
        }
        panel.hideStandardButtons()
    }

    /// No stored spot for this screen configuration: just clamp back into the visible area.
    func clampToVisibleScreens(animated: Bool) {
        endPeek(animated: false)

        let clamped = NoteStore.clampToScreens(note.frame)
        if clamped != note.frame {
            store.update(noteID) { $0.frame = clamped }
        }
        if note.tuckedEdge == nil {
            move(to: clamped, animated: animated)
        } else {
            move(to: NoteWindowController.tabFrame(for: note), animated: animated)
        }
    }

    private func move(to frame: CGRect, animated: Bool) {
        guard panel.frame != frame else { return }
        if animated {
            animate(to: frame, completion: nil)
        } else {
            setFrameNow(frame)
        }
    }

    /// Sets the frame immediately, but through `panel.animator()` with duration 0.
    ///
    /// A bare `setFrame` lets a running `NSAnimationContext` animation on the same property
    /// simply continue; that one then writes the old target frame back (a hide during the
    /// peek slide-in animation left the panel misshapen). An animator assignment with
    /// duration 0 *does* end the running animation on that property.
    private func setFrameNow(_ frame: CGRect, display: Bool = true) {
        animationCount += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panel.animator().setFrame(frame, display: display)
        }
        animationCount -= 1
    }

    private func animate(to frame: CGRect, duration: TimeInterval = 0.25, completion: (() -> Void)?) {
        animationCount += 1
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(frame, display: true)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.animationCount = max(0, self.animationCount - 1)
                completion?()
            }
        }
    }
}

// MARK: - Manager

/// Keeps the panels in sync with the store and distributes the tucked tabs over the edges.
@MainActor
final class NoteWindowManager {

    private let store: NoteStore
    private var controllers: [UUID: NoteWindowController] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var syncScheduled = false

    /// The screen configuration the current positions belong to.
    private(set) var activeLayoutKey = ScreenConfiguration.currentKey()

    /// macOS fires `didChangeScreenParameters` in salvos; we wait until things are quiet.
    private var screenChangeWork: DispatchWorkItem?
    private static let screenChangeDebounce: TimeInterval = 0.4

    /// A screen change has been reported that still has to be processed. While it is running
    /// the system moves panels around itself; those positions must not land in the model as a
    /// drag result, because they would be recorded under the still current (old) layout key.
    private(set) var isScreenChangePending = false

    init(store: NoteStore) {
        self.store = store

        store.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.scheduleSync()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.handleScreenChange()
                }
            }
            .store(in: &cancellables)
    }

    func start() {
        activeLayoutKey = ScreenConfiguration.currentKey()
        // Read out *before* the first sync: that one records the current (not yet converted)
        // positions under this key right away and would otherwise overwrite the stored layout.
        let stored = store.layout(for: activeLayoutKey)
        sync()
        // If this configuration has been seen before, the stored layout wins over what is in
        // notes.json (which belongs to the configuration of the previous session).
        if let stored {
            applyLayout(stored, animated: false)
        }
        captureCurrentLayout()
        relayoutAllTucked(animated: false)
    }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.syncScheduled = false
                self.sync()
            }
        }
    }

    /// Creates panels for new notes and cleans up panels of deleted notes.
    private func sync() {
        let ids = Set(store.notes.map(\.id))

        var freedEdges: Set<TuckEdge> = []
        for (id, controller) in controllers where !ids.contains(id) {
            if let edge = controller.lastKnownEdge {
                freedEdges.insert(edge)
            }
            controller.close()
            controllers.removeValue(forKey: id)
        }

        for note in store.notes where controllers[note.id] == nil {
            let controller = NoteWindowController(noteID: note.id, store: store, manager: self)
            controllers[note.id] = controller
            if !store.allHidden {
                controller.show(animated: true)
            }
        }

        // A changed opacity has to land on the panel right away.
        for controller in controllers.values {
            controller.refreshOpacity()
        }

        // A deleted tucked note leaves a gap in the stack.
        for edge in freedEdges {
            relayoutTucked(edge: edge, animated: true)
        }

        // The active layout runs along with the model: new notes are added automatically,
        // deleted ones drop out, and a moved note is immediately in the right place.
        captureCurrentLayout()
    }

    // MARK: - Actions

    func newNote() {
        if store.allHidden {
            setAllHidden(false)
        }
        let note = store.addNote(at: NSEvent.mouseLocation)
        sync()
        controllers[note.id]?.show(animated: true)
        controllers[note.id]?.panel.makeKeyAndOrderFront(nil)
    }

    /// Brings a just created note into view and makes it key. `sync()` first, because the panel
    /// is normally only created on the next runloop pass.
    func focus(_ id: UUID) {
        if store.allHidden {
            setAllHidden(false)
        }
        sync()
        guard let controller = controllers[id] else { return }
        controller.show(animated: true)
        controller.panel.makeKeyAndOrderFront(nil)
    }

    func reveal(_ id: UUID) {
        if store.allHidden {
            setAllHidden(false)
        }
        sync()
        guard let controller = controllers[id] else { return }
        if store.note(with: id)?.tuckedEdge != nil {
            controller.untuck()
        }
        controller.show()
        controller.flash()
    }

    func setAllHidden(_ hidden: Bool) {
        store.allHidden = hidden
        for controller in controllers.values {
            if hidden {
                controller.hide(animated: true)
            } else {
                controller.show(animated: true)
            }
        }
    }

    func toggleAllHidden() {
        setAllHidden(!store.allHidden)
    }

    // MARK: - Tuck-layout

    func relayoutAllTucked(animated: Bool) {
        relayoutTucked(edge: .left, animated: animated)
        relayoutTucked(edge: .right, animated: animated)
    }

    /// Stacks all tabs on one edge vertically, with 8 pt of spacing and without overlap.
    func relayoutTucked(edge: TuckEdge, animated: Bool) {
        let tucked = store.notes.filter { $0.tuckedEdge == edge }
        guard !tucked.isEmpty else { return }

        // Group per screen so notes stay on their own screen.
        let fallbackKey = ObjectIdentifier(NoteWindowManager.self)
        var perScreen: [ObjectIdentifier: [Note]] = [:]
        var boundsPerScreen: [ObjectIdentifier: CGRect] = [:]
        for note in tucked {
            let screen = NoteStore.screen(for: note.frame)
            let key = screen.map(ObjectIdentifier.init) ?? fallbackKey
            perScreen[key, default: []].append(note)
            boundsPerScreen[key] = screen?.visibleFrame ?? NoteStore.fallbackScreenBounds
        }

        let preferredSpacing: CGFloat = 8
        let minimumStep: CGFloat = 6
        let size = Note.tabSize

        for (key, group) in perScreen {
            guard let visible = boundsPerScreen[key], !group.isEmpty else { continue }
            let x = edge == .left ? visible.minX : visible.maxX - size.width

            // If the stack no longer fits along the edge, we compress the spacing (down to
            // overlap if need be) so that tabs never lie exactly on top of each other.
            let count = group.count
            var step = size.height + preferredSpacing
            if count > 1 {
                let available = (visible.height - size.height) / CGFloat(count - 1)
                step = max(minimumStep, min(step, available))
            }

            let sorted = group.sorted { $0.tuckedY > $1.tuckedY }
            var ceiling = visible.maxY

            for (index, note) in sorted.enumerated() {
                let remaining = count - index - 1
                let lowest = visible.minY + CGFloat(remaining) * step
                var y = min(note.tuckedY, ceiling - size.height)
                y = max(y, lowest)
                let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
                if note.tuckedY != y {
                    store.update(note.id) { $0.tuckedY = y }
                }
                controllers[note.id]?.setTabFrame(frame, animated: animated)
                ceiling = y - (step - size.height)
            }
        }
    }

    // MARK: - Screen configurations

    /// Records the spot of all notes under the active configuration key.
    ///
    /// Deliberately reads from the model and not from `panel.frame`: during a tuck, untuck or
    /// peek animation the panel frame is an intermediate state, while the model is already right.
    func captureCurrentLayout() {
        var entries: [UUID: NoteLayoutEntry] = [:]
        for note in store.notes {
            entries[note.id] = NoteLayoutEntry(note)
        }
        store.storeLayout(entries, for: activeLayoutKey)
    }

    private func handleScreenChange() {
        screenChangeWork?.cancel()
        isScreenChangePending = true
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.applyScreenChange() }
        }
        screenChangeWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + NoteWindowManager.screenChangeDebounce,
            execute: work
        )
    }

    private func applyScreenChange() {
        screenChangeWork = nil
        defer { isScreenChangePending = false }
        let newKey = ScreenConfiguration.currentKey()

        guard newKey != activeLayoutKey else {
            // Same configuration (for example only a menu bar that changes height): switch
            // nothing over, just make sure everything stays visible.
            for controller in controllers.values {
                controller.clampToVisibleScreens(animated: false)
            }
            relayoutAllTucked(animated: false)
            captureCurrentLayout()
            return
        }

        // First record the current spots under the *old* key, and only then switch over.
        captureCurrentLayout()
        activeLayoutKey = newKey
        applyLayout(store.layout(for: newKey) ?? [:], animated: true)
        relayoutAllTucked(animated: true)
        captureCurrentLayout()
    }

    /// Puts every note in its stored spot for this configuration. Notes without a stored spot
    /// are simply clamped into the visible area, exactly as before.
    private func applyLayout(_ layout: [UUID: NoteLayoutEntry], animated: Bool) {
        for note in store.notes {
            guard let controller = controllers[note.id] else { continue }
            if let entry = layout[note.id] {
                controller.applyLayout(entry, animated: animated)
            } else {
                controller.clampToVisibleScreens(animated: animated)
            }
        }
    }
}
