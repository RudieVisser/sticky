import AppKit

// MARK: - Colors

extension NoteColor {
    /// Dark shade of the note color for the rope and the figure. Works in both light and dark
    /// mode: in the dark it is brightened a little instead, otherwise it disappears against the
    /// background.
    var nsRope: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let base = NSColor(self.accent(dark ? .dark : .light))
            let mixed = dark
                ? base.blended(withFraction: 0.30, of: .white)
                : base.blended(withFraction: 0.55, of: .black)
            return mixed ?? base
        }
    }
}

// MARK: - The knob

/// The little knob in the middle of the bottom edge of a free note. Visually it sits half over
/// the edge (its lowest point is clipped by the window edge), but it has a small, round hit
/// zone so the resize strip around it keeps working as usual.
@MainActor
final class BuddyKnobView: NSView {

    /// Diameter of the knob.
    static let diameter: CGFloat = 10
    /// Width/height of the carrying view; the hit zone is the circle inside it.
    static let hitRadius: CGFloat = 7
    static let viewSize = CGSize(width: 18, height: 12)

    var color: NoteColor = .yellow {
        didSet { needsDisplay = true }
    }

    var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            needsDisplay = true
        }
    }

    /// There is already a rope hanging from it: the knob shows that with a slightly fuller shade.
    var isEngaged = false {
        didSet {
            guard isEngaged != oldValue else { return }
            needsDisplay = true
        }
    }

    var onClick: (() -> Void)?

    /// Center of the circle in own coordinates. It sits deliberately just below the middle so
    /// the knob falls across the bottom edge of the note.
    var centre: CGPoint {
        CGPoint(x: bounds.midX, y: 3.5)
    }

    override var isFlipped: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        let c = centre
        return hypot(local.x - c.x, local.y - c.y) <= BuddyKnobView.hitRadius ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let r = BuddyKnobView.diameter / 2
        let c = centre
        let rect = NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)
        let alpha: CGFloat = isHovering ? 0.85 : (isEngaged ? 0.6 : 0.4)
        color.nsRope.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}

// MARK: - Verlet physics

/// A single mass point in the verlet simulation. An `invMass` of 0 means immovable (the anchor,
/// or the figure for as long as you are holding it).
private struct VerletPoint {
    var p: CGPoint
    var prev: CGPoint
    var invMass: CGFloat
}

/// The simulation of the rope plus the figure, in **screen coordinates**.
///
/// Deliberately not in window coordinates: the rope window is a child window and therefore moves
/// along with the note. If the points were kept in window coordinates, a drag would move both the
/// anchor and the points at the same time and nothing would swing. In screen coordinates the mass
/// simply stays where it was while the anchor walks away, and that is exactly the swing you want.
@MainActor
final class BuddySimulation {

    // Shape of the chain.
    static let segments = 19
    static let segmentLength: CGFloat = 10
    static let ropeLength = CGFloat(segments) * segmentLength   // 190 pt

    private static let iEnd = segments          // the hands: end of the rope
    private static let iTorso = segments + 1    // hip
    private static let iLegL = segments + 2
    private static let iLegR = segments + 3
    private static let pointCount = segments + 4

    // Tuning.
    private static let gravity: CGFloat = -1500      // pt/s²
    private static let ropeDamping: CGFloat = 0.992
    private static let bodyDamping: CGFloat = 0.985
    private static let iterations = 5
    /// Softer than 1 lets the chain stretch a little per frame, which makes the rope elastic.
    private static let ropeStiffness: CGFloat = 0.45
    private static let maxStep: CGFloat = 40         // safety clamp per frame
    /// The figure is heavier than a rope segment, which is what pulls the chain taut.
    private static let bodyInvMass: CGFloat = 1.0 / 3.5
    private static let limbInvMass: CGFloat = 1.0 / 1.4

    private static let torsoLength: CGFloat = 30
    private static let legLength: CGFloat = 20
    private static let legSpread: CGFloat = 15

    /// How far the rope may stretch when you pull the figure away.
    private static let maxStretch: CGFloat = 1.6
    /// For the window size: how much longer than its rest length the whole thing can become.
    static let elasticHeadroom: CGFloat = maxStretch
    /// Below this amount of kinetic energy (the sum of the squared displacements) it counts as rest.
    private static let restEnergy: CGFloat = 0.12
    private static let restDuration: TimeInterval = 0.35

    private static let unrollDuration: TimeInterval = 0.45
    private static let retractDuration: TimeInterval = 0.30
    private static let fallFade: TimeInterval = 0.6
    private static let whipFade: TimeInterval = 0.45

    enum Phase {
        case unrolling
        case hanging
        case retracting
        case cut
    }

    private var pts: [VerletPoint] = []
    private(set) var phase: Phase = .unrolling
    private(set) var isAsleep = false
    /// The rope has been cut between this index and the next one.
    private(set) var cutIndex: Int?

    /// Everything has fallen away or rolled back up; the owner may clean up.
    private(set) var isFinished = false

    /// The figure is being held at this screen position.
    var grabTarget: CGPoint?

    private var anchor: CGPoint
    private var elapsed: TimeInterval = 0
    private var phaseTime: TimeInterval = 0
    private var calmTime: TimeInterval = 0

    /// From 0 (rolled up inside the knob) to 1 (fully unrolled).
    private var unroll: CGFloat = 0

    init(anchor: CGPoint) {
        self.anchor = anchor
        var points: [VerletPoint] = []
        points.reserveCapacity(BuddySimulation.pointCount)
        for i in 0..<BuddySimulation.pointCount {
            // Start rolled up under the knob, with a minuscule spread so the constraints have a
            // direction to fall out in.
            let offset = CGPoint(
                x: anchor.x + CGFloat(i % 3) * 0.4 - 0.4,
                y: anchor.y - CGFloat(i) * 0.6
            )
            let invMass: CGFloat
            switch i {
            case 0: invMass = 0
            case BuddySimulation.iEnd: invMass = BuddySimulation.bodyInvMass
            case BuddySimulation.iTorso, BuddySimulation.iLegL, BuddySimulation.iLegR:
                invMass = BuddySimulation.limbInvMass
            default: invMass = 1
            }
            points.append(VerletPoint(p: offset, prev: offset, invMass: invMass))
        }
        pts = points
    }

    // MARK: - Handy points for the drawing and the hit tests

    var handPoint: CGPoint { pts[BuddySimulation.iEnd].p }
    var torsoPoint: CGPoint { pts[BuddySimulation.iTorso].p }
    var legPoints: (CGPoint, CGPoint) {
        (pts[BuddySimulation.iLegL].p, pts[BuddySimulation.iLegR].p)
    }
    var ropePoints: [CGPoint] { (0...BuddySimulation.iEnd).map { pts[$0].p } }

    /// The grab point of the figure: between the hands and the hip.
    var bodyCentre: CGPoint {
        let a = handPoint, b = torsoPoint
        return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    /// Opacity of the upper piece of rope (after the cut it whips upwards and fades out).
    var upperAlpha: CGFloat {
        guard phase == .cut else { return 1 }
        return max(0, 1 - CGFloat(phaseTime / BuddySimulation.whipFade))
    }

    /// Opacity of the fallen part plus the figure.
    var lowerAlpha: CGFloat {
        guard phase == .cut else { return 1 }
        return max(0, 1 - CGFloat(phaseTime / BuddySimulation.fallFade))
    }

    // MARK: - Interaction

    func wake() {
        isAsleep = false
        calmTime = 0
    }

    /// Rolls the rope back up into the knob and reports itself finished afterwards.
    func retract() {
        guard phase == .unrolling || phase == .hanging else { return }
        phase = .retracting
        phaseTime = 0
        grabTarget = nil
        wake()
    }

    /// Cuts the rope between segment `index` and `index + 1`.
    func cut(at index: Int) {
        guard cutIndex == nil, phase != .cut else { return }
        cutIndex = min(max(index, 1), BuddySimulation.segments - 1)
        phase = .cut
        phaseTime = 0
        grabTarget = nil
        wake()
    }

    /// Segment index where a click cuts the rope, or nil if the click is not close enough to it.
    /// The top 20% does not count, so you cannot hit the knob by accident.
    func ropeSegment(near point: CGPoint, tolerance: CGFloat = 6) -> Int? {
        guard phase == .hanging || phase == .unrolling else { return nil }
        let first = max(1, Int((CGFloat(BuddySimulation.segments) * 0.2).rounded()))
        var best: (index: Int, distance: CGFloat)?
        for i in first..<BuddySimulation.iEnd {
            let d = BuddySimulation.distance(from: point, toSegment: pts[i].p, pts[i + 1].p)
            if d <= tolerance, best == nil || d < best!.distance {
                best = (i, d)
            }
        }
        return best?.index
    }

    /// Is the point on the figure?
    func hitsBuddy(_ point: CGPoint, tolerance: CGFloat = 28) -> Bool {
        guard phase == .hanging || phase == .unrolling else { return false }
        let c = bodyCentre
        return hypot(point.x - c.x, point.y - c.y) <= tolerance
    }

    // MARK: - Step

    func step(anchor newAnchor: CGPoint, dt: CGFloat) {
        if hypot(newAnchor.x - anchor.x, newAnchor.y - anchor.y) > 0.05 {
            wake()
        }
        anchor = newAnchor

        if isAsleep { return }

        elapsed += TimeInterval(dt)
        phaseTime += TimeInterval(dt)

        switch phase {
        case .unrolling:
            unroll = min(1, CGFloat(elapsed / BuddySimulation.unrollDuration))
            if unroll >= 1 { phase = .hanging; phaseTime = 0 }
        case .hanging:
            unroll = 1
        case .retracting:
            unroll = max(0, 1 - CGFloat(phaseTime / BuddySimulation.retractDuration))
            if unroll <= 0 { isFinished = true }
        case .cut:
            unroll = 1
            if phaseTime >= max(BuddySimulation.fallFade, BuddySimulation.whipFade) {
                isFinished = true
            }
        }

        integrate(dt: dt)
        applyGrab()

        for _ in 0..<BuddySimulation.iterations {
            pts[0].p = anchor
            solveConstraints()
        }
        pts[0].p = anchor
        pts[0].prev = anchor

        updateSleep()
    }

    private func integrate(dt: CGFloat) {
        let g = BuddySimulation.gravity * dt * dt
        for i in 1..<pts.count {
            let damping = i <= BuddySimulation.iEnd
                ? BuddySimulation.ropeDamping
                : BuddySimulation.bodyDamping
            var vx = (pts[i].p.x - pts[i].prev.x) * damping
            var vy = (pts[i].p.y - pts[i].prev.y) * damping
            let m = BuddySimulation.maxStep
            vx = min(max(vx, -m), m)
            vy = min(max(vy, -m), m)
            pts[i].prev = pts[i].p
            pts[i].p.x += vx
            pts[i].p.y += vy + g
        }
    }

    /// The figure follows the mouse, but never further than `maxStretch` times the rope length.
    /// Beyond that the rope holds it back instead of stretching along endlessly.
    private func applyGrab() {
        guard let target = grabTarget, phase == .hanging || phase == .unrolling else { return }
        let limit = BuddySimulation.ropeLength * BuddySimulation.maxStretch
        var wanted = target
        let dx = target.x - anchor.x
        let dy = target.y - anchor.y
        let d = hypot(dx, dy)
        if d > limit, d > 0 {
            wanted = CGPoint(x: anchor.x + dx / d * limit, y: anchor.y + dy / d * limit)
        }
        let i = BuddySimulation.iEnd
        // Leaving prev at the previous position keeps the velocity of your hand, so it whips
        // through nicely when you let go.
        pts[i].prev = pts[i].p
        pts[i].p = wanted
    }

    private func solveConstraints() {
        let grabbing = grabTarget != nil
        let end = BuddySimulation.iEnd
        let savedInvMass = pts[end].invMass
        if grabbing { pts[end].invMass = 0 }
        defer { if grabbing { pts[end].invMass = savedInvMass } }

        let seg = BuddySimulation.segmentLength * max(unroll, 0.02)

        for i in 0..<BuddySimulation.segments {
            if let cut = cutIndex, i == cut { continue }
            satisfy(i, i + 1, rest: seg, stiffness: BuddySimulation.ropeStiffness)
        }
        satisfy(end, BuddySimulation.iTorso, rest: BuddySimulation.torsoLength * max(unroll, 0.02))
        satisfy(BuddySimulation.iTorso, BuddySimulation.iLegL, rest: BuddySimulation.legLength * max(unroll, 0.02))
        satisfy(BuddySimulation.iTorso, BuddySimulation.iLegR, rest: BuddySimulation.legLength * max(unroll, 0.02))
        // Weak constraints: keep the legs off each other, and stop them folding up over the body.
        satisfy(BuddySimulation.iLegL, BuddySimulation.iLegR, rest: BuddySimulation.legSpread * max(unroll, 0.02), stiffness: 0.3)
        let reach = (BuddySimulation.torsoLength + BuddySimulation.legLength * 0.85) * max(unroll, 0.02)
        satisfy(end, BuddySimulation.iLegL, rest: reach, stiffness: 0.2)
        satisfy(end, BuddySimulation.iLegR, rest: reach, stiffness: 0.2)
    }

    private func satisfy(_ a: Int, _ b: Int, rest: CGFloat, stiffness: CGFloat = 1) {
        let wa = pts[a].invMass
        let wb = pts[b].invMass
        let w = wa + wb
        guard w > 0 else { return }
        var dx = pts[b].p.x - pts[a].p.x
        var dy = pts[b].p.y - pts[a].p.y
        var len = hypot(dx, dy)
        if len < 0.0001 {
            // Points that coincide completely have no direction; pick one.
            dx = 0; dy = -0.0001; len = 0.0001
        }
        let diff = (len - rest) / len * stiffness
        pts[a].p.x += dx * diff * (wa / w)
        pts[a].p.y += dy * diff * (wa / w)
        pts[b].p.x -= dx * diff * (wb / w)
        pts[b].p.y -= dy * diff * (wb / w)
    }

    private func updateSleep() {
        guard phase == .hanging, grabTarget == nil else {
            calmTime = 0
            return
        }
        var energy: CGFloat = 0
        for i in 1..<pts.count {
            let dx = pts[i].p.x - pts[i].prev.x
            let dy = pts[i].p.y - pts[i].prev.y
            energy += dx * dx + dy * dy
        }
        if energy < BuddySimulation.restEnergy {
            calmTime += 1.0 / 60.0
            if calmTime >= BuddySimulation.restDuration {
                isAsleep = true
            }
        } else {
            calmTime = 0
        }
    }

    // MARK: - Geometry

    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let vx = b.x - a.x
        let vy = b.y - a.y
        let len2 = vx * vx + vy * vy
        guard len2 > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        var t = ((point.x - a.x) * vx + (point.y - a.y) * vy) / len2
        t = min(max(t, 0), 1)
        return hypot(point.x - (a.x + vx * t), point.y - (a.y + vy * t))
    }
}

// MARK: - Drawing

/// Draws the rope and the figure. The simulation computes in screen coordinates; this view
/// converts them to its own coordinates by subtracting the window origin.
@MainActor
final class BuddyCanvasView: NSView {

    var simulation: BuddySimulation?
    var color: NoteColor = .yellow

    /// Mouse pass-through: only the figure and the rope catch clicks, the rest of this (large,
    /// transparent) window does not.
    var onGrabBegan: ((CGPoint) -> Void)?
    var onGrabMoved: ((CGPoint) -> Void)?
    var onGrabEnded: (() -> Void)?
    var onCut: ((Int) -> Void)?

    private var isDragging = false

    override var isFlipped: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func screenOrigin() -> CGPoint {
        window?.frame.origin ?? .zero
    }

    private func local(_ p: CGPoint) -> CGPoint {
        let o = screenOrigin()
        return CGPoint(x: p.x - o.x, y: p.y - o.y)
    }

    private func screenPoint(for event: NSEvent) -> CGPoint {
        let o = screenOrigin()
        let inWindow = event.locationInWindow
        return CGPoint(x: o.x + inWindow.x, y: o.y + inWindow.y)
    }

    // MARK: Hit-testing

    /// Second line of defence next to `ignoresMouseEvents`: anything outside the figure and the
    /// rope is of no interest to us and falls through to whatever lies underneath.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let simulation else { return nil }
        let o = screenOrigin()
        let screen = CGPoint(x: o.x + point.x, y: o.y + point.y)
        if simulation.hitsBuddy(screen) { return self }
        if simulation.ropeSegment(near: screen) != nil { return self }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        guard let simulation else { return }
        let p = screenPoint(for: event)
        if simulation.hitsBuddy(p) {
            isDragging = true
            onGrabBegan?(p)
            return
        }
        if let index = simulation.ropeSegment(near: p) {
            onCut?(index)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        onGrabMoved?(screenPoint(for: event))
    }

    override func mouseUp(with event: NSEvent) {
        guard isDragging else { return }
        isDragging = false
        onGrabEnded?()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let simulation else { return }
        let rope = simulation.ropePoints.map(local)
        guard rope.count > 1 else { return }

        let base = color.nsRope
        let cut = simulation.cutIndex
        let upper = simulation.upperAlpha
        let lower = simulation.lowerAlpha

        // Rope: drawn per segment, slightly thicker at the top than at the bottom.
        for i in 0..<(rope.count - 1) {
            // We do not draw the cut segment itself: its ends move apart and that would produce
            // one long line straight across the cut.
            if i == cut { continue }
            let t = CGFloat(i) / CGFloat(rope.count - 1)
            let width = 2.3 - 1.2 * t
            let alpha = (cut.map { i < $0 } ?? true) ? upper : lower
            guard alpha > 0.01 else { continue }
            let path = NSBezierPath()
            path.move(to: rope[i])
            path.line(to: rope[i + 1])
            path.lineWidth = width
            path.lineCapStyle = .round
            base.withAlphaComponent(alpha * 0.9).setStroke()
            path.stroke()
        }

        let figureAlpha = cut == nil ? upper : lower
        guard figureAlpha > 0.01 else { return }
        drawFigure(
            hands: local(simulation.handPoint),
            torso: local(simulation.torsoPoint),
            legs: (local(simulation.legPoints.0), local(simulation.legPoints.1)),
            color: base.withAlphaComponent(figureAlpha)
        )
    }

    private func drawFigure(hands: CGPoint, torso: CGPoint, legs: (CGPoint, CGPoint), color: NSColor) {
        let ax = torso.x - hands.x
        let ay = torso.y - hands.y
        let len = max(hypot(ax, ay), 0.001)
        let ux = ax / len, uy = ay / len
        let nx = -uy, ny = ux                       // perpendicular to the torso axis

        let head = CGPoint(x: hands.x + ux * len * 0.30, y: hands.y + uy * len * 0.30)
        let shoulder = CGPoint(x: hands.x + ux * len * 0.56, y: hands.y + uy * len * 0.56)
        let headRadius: CGFloat = 5

        color.setStroke()
        color.setFill()

        // Little arms: from the hands on the rope to the shoulders.
        let arms = NSBezierPath()
        for side in [CGFloat(1), CGFloat(-1)] {
            arms.move(to: CGPoint(x: hands.x + nx * side * 1.5, y: hands.y + ny * side * 1.5))
            arms.line(to: CGPoint(x: shoulder.x + nx * side * 5, y: shoulder.y + ny * side * 5))
        }
        arms.lineWidth = 1.6
        arms.lineCapStyle = .round
        arms.stroke()

        // Body.
        let body = NSBezierPath()
        body.move(to: shoulder)
        body.line(to: torso)
        body.lineWidth = 2
        body.lineCapStyle = .round
        body.stroke()

        // Little legs.
        let legPath = NSBezierPath()
        legPath.move(to: legs.0)
        legPath.line(to: torso)
        legPath.line(to: legs.1)
        legPath.lineWidth = 1.8
        legPath.lineCapStyle = .round
        legPath.lineJoinStyle = .round
        legPath.stroke()

        // Head on top, so the arms disappear neatly behind it.
        let headRect = NSRect(
            x: head.x - headRadius,
            y: head.y - headRadius,
            width: headRadius * 2,
            height: headRadius * 2
        )
        NSBezierPath(ovalIn: headRect).fill()
    }
}

// MARK: - Window

/// Transparent, borderless child window below the note. It can never become key: clicking the
/// figure must not activate the app.
@MainActor
final class BuddyWindow: NSPanel {

    init(contentRect: CGRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        becomesKeyOnlyIfNeeded = true
    }

    /// Being able to become key is needed for the hand cursor: macOS ignores cursor changes from
    /// an inactive app as long as the window under the mouse is not key.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// MARK: - Controller

/// Manages the rope window of a single note: creating, simulating, mouse pass-through and
/// cleaning up.
@MainActor
final class DanglingBuddyController {

    /// Margin left and right of the note, so a full swing stays inside the window.
    private static let sideMargin: CGFloat = BuddySimulation.ropeLength * BuddySimulation.elasticHeadroom + 40
    /// Height of the rope window: rope plus figure plus some slack for the overshoot and the
    /// extra stretch of the elastic rope.
    private static let height: CGFloat = BuddySimulation.ropeLength * BuddySimulation.elasticHeadroom + 130
    private static let frameInterval: TimeInterval = 1.0 / 60.0

    private unowned let panel: NSPanel
    private let window: BuddyWindow
    private let canvas: BuddyCanvasView
    private let simulation: BuddySimulation
    private var timer: Timer?
    private var isGrabbing = false
    private var hotCursorShown = false

    /// Called when the rope cleans itself up (cut or rolled back up).
    var onFinish: (() -> Void)?

    var color: NoteColor {
        didSet {
            guard color != oldValue else { return }
            canvas.color = color
            canvas.needsDisplay = true
        }
    }

    init(panel: NSPanel, color: NoteColor) {
        self.panel = panel
        self.color = color

        let frame = DanglingBuddyController.windowFrame(for: panel.frame)
        window = BuddyWindow(contentRect: frame)
        canvas = BuddyCanvasView(frame: CGRect(origin: .zero, size: frame.size))
        canvas.autoresizingMask = [.width, .height]
        canvas.color = color
        window.contentView = canvas

        simulation = BuddySimulation(anchor: DanglingBuddyController.anchor(for: panel.frame))
        canvas.simulation = simulation

        canvas.onGrabBegan = { [weak self] point in
            guard let self else { return }
            self.isGrabbing = true
            self.simulation.grabTarget = point
            self.simulation.wake()
        }
        canvas.onGrabMoved = { [weak self] point in
            guard let self else { return }
            self.simulation.grabTarget = point
            self.simulation.wake()
        }
        canvas.onGrabEnded = { [weak self] in
            guard let self else { return }
            self.isGrabbing = false
            self.simulation.grabTarget = nil
            self.simulation.wake()
        }
        canvas.onCut = { [weak self] index in
            self?.simulation.cut(at: index)
        }

        window.alphaValue = panel.alphaValue
        panel.addChildWindow(window, ordered: .below)
        window.orderFront(nil)
        startTimer()
    }

    /// Rolls the rope up; the simulation reports itself finished afterwards via `onFinish`.
    func retract() {
        simulation.retract()
    }

    /// Gone immediately, without animation. For tuck, hide, delete and quit.
    func dismiss() {
        timer?.invalidate()
        timer = nil
        if hotCursorShown {
            hotCursorShown = false
            NSCursor.arrow.set()
        }
        returnKeyFocus()
        canvas.simulation = nil
        panel.removeChildWindow(window)
        window.orderOut(nil)
        window.close()
    }

    // MARK: - Frames

    private static func anchor(for panelFrame: CGRect) -> CGPoint {
        CGPoint(x: panelFrame.midX, y: panelFrame.minY)
    }

    private static func windowFrame(for panelFrame: CGRect) -> CGRect {
        CGRect(
            x: panelFrame.minX - sideMargin,
            y: panelFrame.minY - height,
            width: panelFrame.width + sideMargin * 2,
            height: height
        )
    }

    // MARK: - Loop

    /// The timer runs for as long as the rope exists, even while the simulation is asleep: it
    /// still takes care of the mouse pass-through and keeps the window under the note.
    private func startTimer() {
        let timer = Timer(timeInterval: DanglingBuddyController.frameInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func tick() {
        // The window follows the note. As a child window it already moves along during a drag;
        // this re-check catches resizes and every other frame change.
        let wanted = DanglingBuddyController.windowFrame(for: panel.frame)
        if abs(wanted.origin.x - window.frame.origin.x) > 0.5
            || abs(wanted.origin.y - window.frame.origin.y) > 0.5
            || abs(wanted.width - window.frame.width) > 0.5 {
            window.setFrame(wanted, display: false)
        }
        // Take over the opacity of the note (hover, opacity slider, fades).
        if abs(window.alphaValue - panel.alphaValue) > 0.001 {
            window.alphaValue = panel.alphaValue
        }

        let wasAsleep = simulation.isAsleep
        simulation.step(
            anchor: DanglingBuddyController.anchor(for: panel.frame),
            dt: CGFloat(DanglingBuddyController.frameInterval)
        )
        if !simulation.isAsleep || !wasAsleep {
            canvas.needsDisplay = true
        }

        updateMousePassthrough()

        if simulation.isFinished {
            let finish = onFinish
            dismiss()
            finish?()
        }
    }

    /// Mouse pass-through. The window is large and nearly empty; if it caught every click, you
    /// could no longer click anything in the area below your note. `ignoresMouseEvents` is
    /// therefore on by default and only turns off while the mouse is hovering over the figure or
    /// the rope. Deliberately not through `hitTest` alone: that is there as a second line, but
    /// the window server decides for itself whether a click reaches our window at all.
    private func updateMousePassthrough() {
        guard !isGrabbing else {
            window.ignoresMouseEvents = false
            NSCursor.closedHand.set()
            return
        }
        let mouse = NSEvent.mouseLocation
        let hot = window.frame.contains(mouse)
            && (simulation.hitsBuddy(mouse) || simulation.ropeSegment(near: mouse) != nil)
        window.ignoresMouseEvents = !hot

        // Set it again on every tick while we hover over the rope or the figure: otherwise the
        // app underneath may overwrite the cursor again right away. And because macOS ignores
        // cursor changes from an inactive app as long as the window is not key, the window
        // becomes key during the hover and hands the focus back afterwards.
        if hot {
            if !window.isKeyWindow { window.makeKey() }
            NSCursor.openHand.set()
            hotCursorShown = true
        } else if hotCursorShown {
            hotCursorShown = false
            NSCursor.arrow.set()
            returnKeyFocus()
        }
    }

    /// Hands the key status back to the window underneath (the same pattern as Esc in
    /// `NotePanel`): briefly out of the window list, then back without becoming key. Because it
    /// is a child window, we detach and reattach it around the flip so it keeps hanging below
    /// the note.
    private func returnKeyFocus() {
        guard window.isKeyWindow else { return }
        let parent = window.parent
        parent?.removeChildWindow(window)
        window.orderOut(nil)
        window.orderFrontRegardless()
        parent?.addChildWindow(window, ordered: .below)
    }
}
