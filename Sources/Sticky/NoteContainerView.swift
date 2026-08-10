import AppKit

/// Transparent surface that lies over the note content during a peek: every mouse click ends up
/// here instead of at the text fields underneath, and a click untucks the note.
@MainActor
final class PeekCatcherView: NSView {
    var onClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}

/// Edge or corner where the panel can be resized.
enum ResizeRegion: CaseIterable {
    case left, right, bottom, top
    case bottomLeft, bottomRight, topLeft, topRight

    var affectsLeft: Bool { self == .left || self == .bottomLeft || self == .topLeft }
    var affectsRight: Bool { self == .right || self == .bottomRight || self == .topRight }
    var affectsBottom: Bool { self == .bottom || self == .bottomLeft || self == .bottomRight }
    var affectsTop: Bool { self == .top || self == .topLeft || self == .topRight }
}

/// Host view for the SwiftUI content of a note.
///
/// It does three things that SwiftUI itself does not do reliably on a borderless panel:
/// - pin the hosting view to the full panel surface (no more titlebar inset),
/// - report hover so the panel can temporarily become fully opaque,
/// - handle resizing at the edges, including the right mouse cursor.
@MainActor
final class NoteContainerView: NSView {

    /// Width of the grip edge. Stays below the horizontal padding of the content (10 pt), so the
    /// text fields do not overlap with it.
    static let resizeMargin: CGFloat = 6

    var isResizable = true {
        didSet { window?.invalidateCursorRects(for: self) }
    }

    /// The note is activated (the panel is key). The tracking area is set to `.activeAlways`, so
    /// we get mouse-moved even without key status; whether we show a cursor for that depends on
    /// this flag. That way the cursor feedback disappears as soon as you click in another app.
    var isActivated = false {
        didSet {
            guard isActivated != oldValue else { return }
            if !isActivated, showingResizeCursor {
                showingResizeCursor = false
                NSCursor.arrow.set()
            }
            window?.invalidateCursorRects(for: self)
        }
    }

    var onHoverChange: ((Bool) -> Void)?
    var onResizeBegan: (() -> Void)?
    var onResizeEnded: (() -> Void)?

    private var trackingArea: NSTrackingArea?
    private var showingResizeCursor = false

    // MARK: - The dangling buddy

    /// The knob on the bottom edge. Only on a free note; a tab or a peek does not have one (and a
    /// peek cannot be touched anyway).
    private var knob: BuddyKnobView?

    var showsKnob = false {
        didSet {
            guard showsKnob != oldValue else { return }
            updateKnob()
        }
    }

    var knobColor: NoteColor = .yellow {
        didSet { knob?.color = knobColor }
    }

    /// There is already a rope hanging from this knob.
    var isKnobEngaged = false {
        didSet { knob?.isEngaged = isKnobEngaged }
    }

    var onKnobClick: (() -> Void)?

    private func updateKnob() {
        guard showsKnob else {
            knob?.removeFromSuperview()
            knob = nil
            return
        }
        let view = knob ?? BuddyKnobView(frame: .zero)
        view.color = knobColor
        view.isEngaged = isKnobEngaged
        view.onClick = { [weak self] in self?.onKnobClick?() }
        if view.superview !== self {
            addSubview(view)
        }
        knob = view
        layoutKnob()
    }

    private func layoutKnob() {
        guard let knob else { return }
        let size = BuddyKnobView.viewSize
        knob.frame = NSRect(
            x: (bounds.width - size.width) / 2,
            y: 0,
            width: size.width,
            height: size.height
        )
    }

    /// Is the point (in own coordinates) on the knob?
    private func isOnKnob(_ point: NSPoint) -> Bool {
        guard let knob else { return false }
        let local = convert(point, to: knob)
        let c = knob.centre
        return hypot(local.x - c.x, local.y - c.y) <= BuddyKnobView.hitRadius
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutKnob()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutKnob()
    }

    // MARK: - Content

    /// Sets the content of the panel. With `clickCatcher` an invisible surface is placed on top
    /// that catches every single mouse click; that is what a peek needs, because the note can
    /// then only be viewed, not edited, and a click brings it back completely.
    func setContent(_ view: NSView, clickCatcher: (() -> Void)? = nil) {
        subviews.forEach { $0.removeFromSuperview() }
        knob = nil
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)

        if let clickCatcher {
            let catcher = PeekCatcherView(frame: bounds)
            catcher.autoresizingMask = [.width, .height]
            catcher.onClick = clickCatcher
            addSubview(catcher)
        }
        // The knob sits on top, also above any click catcher.
        updateKnob()
    }

    // MARK: - Tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
        window?.invalidateCursorRects(for: self)
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChange?(true)
    }

    override func mouseExited(with event: NSEvent) {
        showingResizeCursor = false
        knob?.isHovering = false
        onHoverChange?(false)
    }

    override func mouseMoved(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        applyCursor(at: convert(event.locationInWindow, from: nil))
    }

    /// The cursor rects of the hosting view can override ours; by setting it explicitly on every
    /// mouse movement the resize cursor always wins inside the edge. Once the mouse leaves the
    /// edge, we put the arrow back once and let AppKit's cursor rect handling take over again
    /// (the text cursor above a line, for example).
    private func applyCursor(at point: NSPoint) {
        // The knob sits in the middle of the bottom resize strip; there it wins.
        let onKnob = isOnKnob(point)
        knob?.isHovering = onKnob
        if onKnob {
            NSCursor.pointingHand.set()
            showingResizeCursor = true
            return
        }
        if isResizable, isActivated, let region = region(at: point) {
            NoteContainerView.cursor(for: region).set()
            showingResizeCursor = true
        } else if showingResizeCursor {
            showingResizeCursor = false
            NSCursor.arrow.set()
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard isResizable, isActivated else { return }
        let margin = NoteContainerView.resizeMargin
        guard bounds.width > margin * 2, bounds.height > margin * 2 else { return }

        let rects: [(NSRect, ResizeRegion)] = [
            (NSRect(x: 0, y: margin, width: margin, height: bounds.height - margin * 2), .left),
            (NSRect(x: bounds.maxX - margin, y: margin, width: margin, height: bounds.height - margin * 2), .right),
            (NSRect(x: margin, y: 0, width: bounds.width - margin * 2, height: margin), .bottom),
            (NSRect(x: margin, y: bounds.maxY - margin, width: bounds.width - margin * 2, height: margin), .top),
            (NSRect(x: 0, y: 0, width: margin, height: margin), .bottomLeft),
            (NSRect(x: bounds.maxX - margin, y: 0, width: margin, height: margin), .bottomRight),
            (NSRect(x: 0, y: bounds.maxY - margin, width: margin, height: margin), .topLeft),
            (NSRect(x: bounds.maxX - margin, y: bounds.maxY - margin, width: margin, height: margin), .topRight)
        ]
        for (rect, region) in rects {
            addCursorRect(rect, cursor: NoteContainerView.cursor(for: region))
        }
    }

    // MARK: - Regions

    /// Point in own coordinates (not flipped: y = 0 is the bottom edge).
    private func region(at point: NSPoint) -> ResizeRegion? {
        let margin = NoteContainerView.resizeMargin
        guard bounds.insetBy(dx: -1, dy: -1).contains(point) else { return nil }

        let left = point.x <= margin
        let right = point.x >= bounds.maxX - margin
        let bottom = point.y <= margin
        let top = point.y >= bounds.maxY - margin

        switch (left, right, bottom, top) {
        case (true, _, true, _):  return .bottomLeft
        case (true, _, _, true):  return .topLeft
        case (_, true, true, _):  return .bottomRight
        case (_, true, _, true):  return .topRight
        case (true, _, _, _):     return .left
        case (_, true, _, _):     return .right
        case (_, _, true, _):     return .bottom
        case (_, _, _, true):     return .top
        default:                  return nil
        }
    }

    private static func cursor(for region: ResizeRegion) -> NSCursor {
        if #available(macOS 15.0, *) {
            let position: NSCursor.FrameResizePosition
            switch region {
            case .left:        position = .left
            case .right:       position = .right
            case .bottom:      position = .bottom
            case .top:         position = .top
            case .bottomLeft:  position = .bottomLeft
            case .bottomRight: position = .bottomRight
            case .topLeft:     position = .topLeft
            case .topRight:    position = .topRight
            }
            return NSCursor.frameResize(position: position, directions: .all)
        }
        // macOS 14 has no public corner cursors; the axis cursors are the closest approximation.
        switch region {
        case .left, .right:   return .resizeLeftRight
        case .bottom, .top:   return .resizeUpDown
        case .bottomLeft, .topRight, .bottomRight, .topLeft: return .resizeLeftRight
        }
    }

    // MARK: - Hit-testing and resizing

    /// Only the edge strip is ours; the rest simply goes to SwiftUI.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let knobPoint = convert(point, from: superview)
        // The knob first: it sits in the middle of the bottom resize strip and takes precedence
        // there, but only within its own small circle.
        if let knob, isOnKnob(knobPoint) {
            return knob
        }
        guard isResizable else { return super.hitTest(point) }
        let local = knobPoint
        if region(at: local) != nil, bounds.contains(local) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isResizable,
              let window,
              let region = region(at: convert(event.locationInWindow, from: nil)) else {
            window?.makeKeyAndOrderFront(nil)
            super.mouseDown(with: event)
            return
        }

        // Clicking the edge activates the note as well; otherwise resizing would happen without a
        // cursor.
        window.makeKeyAndOrderFront(nil)
        onResizeBegan?()
        defer {
            onResizeEnded?()
            window.invalidateShadow()
        }

        let startFrame = window.frame
        let startMouse = NSEvent.mouseLocation
        let minSize = window.minSize
        let cursor = NoteContainerView.cursor(for: region)
        cursor.set()

        while let next = NSApp.nextEvent(
            matching: [.leftMouseDragged, .leftMouseUp],
            until: .distantFuture,
            inMode: .eventTracking,
            dequeue: true
        ) {
            if next.type == .leftMouseUp { break }

            let now = NSEvent.mouseLocation
            let dx = now.x - startMouse.x
            let dy = now.y - startMouse.y
            var frame = startFrame

            if region.affectsLeft {
                let x = min(startFrame.minX + dx, startFrame.maxX - minSize.width)
                frame.origin.x = x
                frame.size.width = startFrame.maxX - x
            }
            if region.affectsRight {
                frame.size.width = max(minSize.width, startFrame.width + dx)
            }
            if region.affectsBottom {
                let y = min(startFrame.minY + dy, startFrame.maxY - minSize.height)
                frame.origin.y = y
                frame.size.height = startFrame.maxY - y
            }
            if region.affectsTop {
                frame.size.height = max(minSize.height, startFrame.height + dy)
            }

            window.setFrame(frame, display: true)
            cursor.set()
        }
    }
}
