import AppKit
import SwiftUI

// MARK: - Drag handle

/// Invisible surface that drags the window via `performDrag(with:)`.
/// If the window does not move, it counts as a click and `onClick` is called.
struct WindowDragHandle: NSViewRepresentable {
    var onClick: (() -> Void)? = nil
    /// Only an activated note shows the move cursor. The tuck tab is set to `true`:
    /// that is one small surface where the openHand is always correct.
    var isActivated: Bool = true

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.onClick = onClick
        view.isActivated = isActivated
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragView else { return }
        view.onClick = onClick
        view.isActivated = isActivated
    }

    final class DragView: NSView {
        var onClick: (() -> Void)?

        var isActivated = true {
            didSet {
                guard isActivated != oldValue else { return }
                if !isActivated, showingHand {
                    showingHand = false
                    NSCursor.arrow.set()
                }
            }
        }

        private var trackingArea: NSTrackingArea?
        private var showingHand = false

        /// `.activeAlways`, because a nonactivating panel is usually not key; showing the
        /// cursor itself depends on `isActivated`.
        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea {
                removeTrackingArea(trackingArea)
            }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
        }

        private func applyCursor() {
            if isActivated {
                NSCursor.openHand.set()
                showingHand = true
            } else if showingHand {
                showingHand = false
                NSCursor.arrow.set()
            }
        }

        override func mouseEntered(with event: NSEvent) { applyCursor() }
        override func mouseMoved(with event: NSEvent) { applyCursor() }
        override func cursorUpdate(with event: NSEvent) { applyCursor() }

        override func mouseExited(with event: NSEvent) {
            showingHand = false
            NSCursor.arrow.set()
        }

        override func mouseDown(with event: NSEvent) {
            guard let window else { return }
            // Make it key first (that is the activation) and only then drag: performDrag
            // blocks until the mouse is released.
            window.makeKeyAndOrderFront(nil)

            let before = window.frame.origin
            NSCursor.closedHand.set()
            window.performDrag(with: event)
            let after = window.frame.origin
            applyCursor()

            let moved = abs(after.x - before.x) > 2 || abs(after.y - before.y) > 2
            if !moved {
                onClick?()
            }
        }
    }
}

// MARK: - Sizing

/// All sizes of the line list, derived from `textSize` and `isCompact`.
struct NoteMetrics: Equatable {
    let text: CGFloat
    let heading: CGFloat
    let checkbox: CGFloat
    let icon: CGFloat
    let rowSpacing: CGFloat
    let rowPadding: CGFloat
    let listPadding: CGFloat

    /// Fixed strip on the left where the drag handle appears; it always reserves its
    /// space so the text does not jump as soon as you hover over a line.
    static let gripWidth: CGFloat = 12

    init(size: TextSize, compact: Bool) {
        text = size.textSize
        heading = size.headingSize
        checkbox = size.checkboxSize
        icon = size.iconSize
        rowSpacing = compact ? 0 : 2
        rowPadding = compact ? 0 : 1
        listPadding = compact ? 3 : 6
    }
}

// MARK: - Note

struct NoteView: View {
    @ObservedObject var store: NoteStore
    @ObservedObject var chrome: NoteChrome
    let noteID: UUID
    /// Makes the panel key; needed before a popover is opened.
    var makeKey: () -> Void = {}

    @Environment(\.colorScheme) private var scheme
    @FocusState private var focusedLine: UUID?
    @State private var confirmingDelete = false
    @State private var showPalette = false
    @State private var confirmToken = 0

    var body: some View {
        let note = store.binding(for: noteID)

        VStack(spacing: 0) {
            header(note)
            Divider().opacity(0.25)
            lines(note)
        }
        .background(note.wrappedValue.color.background(scheme))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(borderColor(note.wrappedValue), lineWidth: borderWidth)
        )
        .animation(.easeOut(duration: 0.12), value: chrome.isActivated)
        .animation(.easeOut(duration: 0.12), value: chrome.isEdgeHighlighted)
    }

    /// Subtle visual feedback: activated means a thin border in the accent color,
    /// mouse at the screen edge while dragging means a clearer glow (releasing tucks).
    private func borderColor(_ note: Note) -> Color {
        if chrome.isEdgeHighlighted { return note.color.accent(scheme) }
        if chrome.isActivated { return note.color.accent(scheme).opacity(0.75) }
        return Color.primary.opacity(0.08)
    }

    private var borderWidth: CGFloat {
        if chrome.isEdgeHighlighted { return 2.5 }
        if chrome.isActivated { return 1.5 }
        return 1
    }

    // MARK: Header

    private func header(_ note: Binding<Note>) -> some View {
        HStack(spacing: 6) {
            Button {
                makeKey()
                showPalette.toggle()
            } label: {
                Circle()
                    .fill(note.wrappedValue.color.accent(scheme))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .help("Choose color")
            .popover(isPresented: $showPalette, arrowEdge: .bottom) {
                palette(note)
            }

            TextField("Title", text: note.title)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: 130, alignment: .leading)

            WindowDragHandle(isActivated: chrome.isActivated)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if store.hasDoneLines(noteID) {
                Button {
                    store.cleanupDoneLines(in: noteID)
                } label: {
                    Image(systemName: "paintbrush")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .frame(width: 16, height: 16)
                }
                .buttonStyle(.plain)
                .help("Clean up checked lines (⌘Z undoes)")
            }

            Menu {
                noteMenuItems(note)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 16)
            .help("More actions")

            Button {
                handleDeleteTap()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(confirmingDelete ? Color.white : Color.primary.opacity(0.55))
                    .frame(width: 16, height: 16)
                    .background(
                        Circle().fill(confirmingDelete ? Color.red : Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)
            .help(confirmingDelete ? "Click again to delete" : "Delete note")
        }
        // One slim row right against the top edge; the note no longer has a titlebar
        // taking up space above it.
        .padding(.horizontal, 10)
        .frame(height: Note.headerHeight)
        .background(Color.primary.opacity(0.04))
        .contentShape(Rectangle())
        // Right-click works on the header itself; above the drag zone the AppKit view
        // swallows the click, which is why the same menu also sits under the ellipsis button.
        .contextMenu { noteMenuItems(note) }
    }

    /// Actions that appear both in the ellipsis menu and in the context menu.
    @ViewBuilder private func noteMenuItems(_ note: Binding<Note>) -> some View {
        Button("Copy as Text") {
            NoteTransfer.copyToPasteboard(NoteTransfer.plainText(note.wrappedValue))
        }
        Button("Copy as Markdown") {
            NoteTransfer.copyToPasteboard(NoteTransfer.markdown(note.wrappedValue))
        }
        Divider()
        Button("Clean Up Checked Lines") {
            store.cleanupDoneLines(in: noteID)
        }
        .disabled(!store.hasDoneLines(noteID))
        // Inside a note we only undo the cleanup of that note, just like ⌘Z.
        Button("Undo Cleanup") {
            store.undoLastCleanup(for: noteID)
        }
        .disabled(!store.canUndoCleanup(for: noteID))
    }

    private func palette(_ note: Binding<Note>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ForEach(NoteColor.allCases, id: \.self) { color in
                    Button {
                        note.wrappedValue.color = color
                        showPalette = false
                    } label: {
                        Circle()
                            .fill(color.accent(scheme))
                            .frame(width: 18, height: 18)
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        note.wrappedValue.color == color ? Color.primary : Color.primary.opacity(0.15),
                                        lineWidth: note.wrappedValue.color == color ? 2 : 1
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .help(color.label)
                }
            }

            Divider().opacity(0.4)

            HStack(spacing: 8) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.6))
                Slider(
                    value: opacityBinding(note),
                    in: Note.minOpacity...Note.maxOpacity
                )
                .controlSize(.small)
                .frame(width: 130)
            }
            .help("Opacity")

            HStack(spacing: 8) {
                Image(systemName: "textformat.size")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.primary.opacity(0.6))

                ForEach(TextSize.allCases, id: \.self) { size in
                    let selected = note.wrappedValue.textSize == size
                    Button {
                        note.wrappedValue.textSize = size
                    } label: {
                        Text(size.label)
                            .font(.system(size: 11, weight: selected ? .semibold : .regular))
                            .foregroundStyle(selected ? Color.primary : Color.primary.opacity(0.6))
                            .frame(width: 22, height: 18)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Color.primary.opacity(selected ? 0.14 : 0.05))
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Text size \(size.label)")
                }

                Spacer(minLength: 4)

                Button {
                    note.wrappedValue.isCompact.toggle()
                } label: {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 10))
                        .foregroundStyle(
                            note.wrappedValue.isCompact ? Color.primary : Color.primary.opacity(0.6)
                        )
                        .frame(width: 22, height: 18)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(note.wrappedValue.isCompact ? 0.14 : 0.05))
                        )
                }
                .buttonStyle(.plain)
                .help("Compact line spacing")
            }
        }
        .padding(10)
    }

    /// Clamps the value right away, so an old or manually edited note never ends up
    /// outside the allowed range.
    private func opacityBinding(_ note: Binding<Note>) -> Binding<Double> {
        Binding(
            get: { Note.clampOpacity(note.wrappedValue.opacity) },
            set: { note.wrappedValue.opacity = Note.clampOpacity($0) }
        )
    }

    // MARK: Lines

    private func lines(_ note: Binding<Note>) -> some View {
        let metrics = NoteMetrics(
            size: note.wrappedValue.textSize,
            compact: note.wrappedValue.isCompact
        )

        return ScrollView {
            VStack(alignment: .leading, spacing: metrics.rowSpacing) {
                // Iterating over the values with an id-based binding per line: an
                // index binding keeps writing to the old position after a remove(at:).
                ForEach(note.wrappedValue.lines) { line in
                    NoteLineRow(
                        line: lineBinding(for: line.id, in: note),
                        focused: $focusedLine,
                        showsPlaceholder: showsPlaceholder(note.wrappedValue, lineID: line.id),
                        metrics: metrics,
                        ticketBaseURL: store.ticketBaseURL,
                        onSubmit: { insertLine(after: line.id, in: note) },
                        onBackspaceAtStart: { mergeIntoPrevious(line.id, in: note) },
                        onMove: { delta in move(line.id, by: delta, in: note) },
                        onBecameSeparator: { insertLine(after: line.id, in: note) },
                        onDropLine: { dragged in move(dragged, onto: line.id, in: note) },
                        onDelete: { deleteLine(line.id, in: note) }
                    )
                }
            }
            // More than the 6 pt resize strip of NoteContainerView, so the drag handle
            // starts completely outside that strip and its left edge does not start a resize.
            .padding(.leading, 7)
            .padding(.trailing, 10)
            .padding(.vertical, metrics.listPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .contentShape(Rectangle())
        .onTapGesture {
            focusLastEditableLine(in: note)
        }
    }

    private func showsPlaceholder(_ note: Note, lineID: UUID) -> Bool {
        note.lines.first?.id == lineID && note.isEmpty
    }

    /// Binding to a single line via its id. If the line is gone, writing is a no-op.
    private func lineBinding(for id: UUID, in note: Binding<Note>) -> Binding<NoteLine> {
        Binding(
            get: {
                note.wrappedValue.lines.first(where: { $0.id == id }) ?? NoteLine(id: id)
            },
            set: { newValue in
                guard let index = note.wrappedValue.lines.firstIndex(where: { $0.id == id }) else { return }
                note.wrappedValue.lines[index] = newValue
            }
        )
    }

    /// A click in the empty area focuses the last line. If that line is not editable (a
    /// separator) or checked, a new empty line is added below it, because otherwise you
    /// could never type below a closing separator.
    private func focusLastEditableLine(in note: Binding<Note>) {
        if let last = note.wrappedValue.lines.last, !last.isDone, last.isEditable {
            focusedLine = last.id
            return
        }
        let inherited = note.wrappedValue.lines.last?.isChecklist ?? false
        let newLine = NoteLine(kind: inherited ? .checklist : .text)
        note.wrappedValue.lines.append(newLine)
        focusedLine = newLine.id
    }

    /// Deletes a single line; the note always keeps at least one (editable) line.
    private func deleteLine(_ id: UUID, in note: Binding<Note>) {
        guard let index = note.wrappedValue.lines.firstIndex(where: { $0.id == id }) else { return }
        note.wrappedValue.lines.remove(at: index)
        if note.wrappedValue.lines.isEmpty {
            let newLine = NoteLine()
            note.wrappedValue.lines = [newLine]
            focusedLine = newLine.id
        }
    }

    // MARK: Editing

    /// Enter creates a new line below. Checklist and mono are inherited, a heading
    /// or separator is not, because below those you want plain text.
    private func insertLine(after id: UUID, in note: Binding<Note>) {
        guard let index = note.wrappedValue.lines.firstIndex(where: { $0.id == id }) else { return }
        let current = note.wrappedValue.lines[index].kind
        let inherited: LineKind = (current == .checklist || current == .mono) ? current : .text
        let newLine = NoteLine(kind: inherited)
        note.wrappedValue.lines.insert(newLine, at: index + 1)
        focusedLine = newLine.id
    }

    /// Backspace at the start of a line merges it with the previous line.
    /// If there is a separator above it, that separator disappears (it cannot take focus itself).
    private func mergeIntoPrevious(_ id: UUID, in note: Binding<Note>) -> Bool {
        guard let index = note.wrappedValue.lines.firstIndex(where: { $0.id == id }), index > 0 else {
            return false
        }
        if note.wrappedValue.lines[index - 1].kind == .separator {
            note.wrappedValue.lines.remove(at: index - 1)
            focusedLine = id
            return true
        }
        let current = note.wrappedValue.lines[index]
        var previous = note.wrappedValue.lines[index - 1]
        previous.text += current.text
        // A checked line renders as Text and cannot take focus; by unchecking it on a
        // merge, the merged line stays editable.
        previous.isDone = false
        note.wrappedValue.lines[index - 1] = previous
        note.wrappedValue.lines.remove(at: index)
        focusedLine = previous.id
        return true
    }

    /// Moves a line one position up (-1) or down (+1).
    private func move(_ id: UUID, by delta: Int, in note: Binding<Note>) {
        guard let index = note.wrappedValue.lines.firstIndex(where: { $0.id == id }) else { return }
        let target = index + delta
        guard target >= 0, target < note.wrappedValue.lines.count else { return }
        note.wrappedValue.lines.swapAt(index, target)
    }

    /// Puts the dragged line at the position of the line it was dropped on.
    /// Returns `false` if the id does not occur in this note (a drag from another
    /// note), so the drop is refused instead of silently doing nothing.
    private func move(_ dragged: UUID, onto target: UUID, in note: Binding<Note>) -> Bool {
        guard let from = note.wrappedValue.lines.firstIndex(where: { $0.id == dragged }) else {
            return false
        }
        guard dragged != target,
              let to = note.wrappedValue.lines.firstIndex(where: { $0.id == target }) else {
            return true
        }
        let line = note.wrappedValue.lines.remove(at: from)
        // After the removal all lines after `from` shift up one place; without this
        // correction a line moving down lands one position too far.
        let insertIndex = from < to ? to - 1 : to
        note.wrappedValue.lines.insert(line, at: insertIndex)
        return true
    }

    private func handleDeleteTap() {
        if confirmingDelete {
            store.delete(noteID)
            return
        }
        confirmingDelete = true
        confirmToken += 1
        let token = confirmToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            if token == confirmToken {
                confirmingDelete = false
            }
        }
    }
}

// MARK: - A single line

private struct NoteLineRow: View {
    @Binding var line: NoteLine
    @FocusState.Binding var focused: UUID?
    let showsPlaceholder: Bool
    let metrics: NoteMetrics
    let ticketBaseURL: String
    let onSubmit: () -> Void
    let onBackspaceAtStart: () -> Bool
    let onMove: (Int) -> Void
    let onBecameSeparator: () -> Void
    let onDropLine: (UUID) -> Bool
    let onDelete: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    @State private var copied = false
    @State private var copyToken = 0

    var body: some View {
        row
            .padding(.vertical, metrics.rowPadding)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let id = UUID(uuidString: raw) else { return false }
                return onDropLine(id)
            }
    }

    @ViewBuilder private var row: some View {
        if line.kind == .separator {
            HStack(alignment: .center, spacing: 6) {
                grip
                Rectangle()
                    .fill(Color.primary.opacity(0.18))
                    .frame(height: 1)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.rowPadding + 3)
                // A separator has no text field, so backspace never reaches it;
                // this little button is the way to remove it.
                deleteButton
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                grip
                checkbox
                content
                trailingControls
            }
        }
    }

    // MARK: Grip

    /// Always reserves the same width; only the visibility depends on hover.
    private var grip: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: metrics.icon - 1))
            .foregroundStyle(Color.primary.opacity(hovering ? 0.35 : 0))
            .frame(width: NoteMetrics.gripWidth)
            .contentShape(Rectangle())
            .draggable(line.id.uuidString)
            .help("Drag to move the line")
    }

    /// Delete button for a separator; only visible on hover, but it always
    /// reserves its space so the line does not jump.
    private var deleteButton: some View {
        Button {
            onDelete()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: metrics.icon - 1, weight: .bold))
                .foregroundStyle(Color.primary.opacity(hovering ? 0.45 : 0))
                .frame(width: metrics.icon + 4, height: metrics.icon + 4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hovering)
        .help("Delete separator")
    }

    @ViewBuilder private var checkbox: some View {
        if line.kind == .checklist {
            Button {
                line.isDone.toggle()
            } label: {
                Image(systemName: line.isDone ? "checkmark.square.fill" : "square")
                    .font(.system(size: metrics.checkbox))
                    .foregroundStyle(line.isDone ? Color.primary.opacity(0.5) : Color.primary.opacity(0.7))
            }
            .buttonStyle(.plain)
            .help(line.isDone ? "Uncheck" : "Check")
        }
    }

    // MARK: Content

    private var font: Font {
        switch line.kind {
        case .heading:   return .system(size: metrics.heading, weight: .semibold)
        case .mono:      return .system(size: metrics.text, design: .monospaced)
        default:         return .system(size: metrics.text)
        }
    }

    private var isFocused: Bool { focused == line.id }

    private var hasLinks: Bool {
        LineMarkup.hasLinks(in: line.text, ticketBaseURL: ticketBaseURL)
    }

    @ViewBuilder private var content: some View {
        if line.isDone {
            Text(line.text.isEmpty ? " " : line.text)
                .font(font)
                .strikethrough(true, color: .primary)
                .opacity(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onTapGesture { line.isDone = false }
                .modifier(MonoBackground(active: line.kind == .mono))
        } else if !isFocused && hasLinks {
            // A TextField does not render links, so an unfocused line that has links
            // shows a Text; clicking it switches back to the text field.
            richText
        } else {
            field
        }
    }

    private var richText: some View {
        Text(LineMarkup.attributed(line.text, ticketBaseURL: ticketBaseURL, tint: LineMarkup.tint(scheme)))
            .font(font)
            .frame(maxWidth: .infinity, alignment: .leading)
            // The tap layer sits behind the text, so a click on a link reaches the link
            // first and only the rest puts the cursor in the text field.
            .background(
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { focused = line.id }
            )
            .environment(\.openURL, OpenURLAction { url in
                guard NSEvent.modifierFlags.contains(.command) else {
                    focused = line.id
                    return .handled
                }
                NSWorkspace.shared.open(url)
                return .handled
            })
            .modifier(MonoBackground(active: line.kind == .mono))
            .help("Cmd-click opens the link")
    }

    private var field: some View {
        TextField(showsPlaceholder ? "Type here…" : "", text: $line.text)
            .textFieldStyle(.plain)
            .font(font)
            .focused($focused, equals: line.id)
            .onSubmit(onSubmit)
            .onKeyPress(.delete) {
                if line.text.isEmpty {
                    return onBackspaceAtStart() ? .handled : .ignored
                }
                return .ignored
            }
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                guard press.modifiers.contains(.option) else { return .ignored }
                onMove(press.key == .upArrow ? -1 : 1)
                return .handled
            }
            .onChange(of: line.text) { _, newValue in
                convertPrefix(newValue)
            }
            .modifier(MonoBackground(active: line.kind == .mono))
    }

    // MARK: Buttons on the right

    @ViewBuilder private var trailingControls: some View {
        if hovering {
            HStack(spacing: 6) {
                if !line.isDone {
                    Button {
                        line.kind = line.kind == .checklist ? .text : .checklist
                    } label: {
                        Image(systemName: line.kind == .checklist ? "text.alignleft" : "checkmark.square")
                            .font(.system(size: metrics.icon))
                            .foregroundStyle(Color.primary.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .help(line.kind == .checklist ? "Remove checkbox" : "Add checkbox")
                }

                Button {
                    copyLine()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: metrics.icon))
                        .foregroundStyle(Color.primary.opacity(copied ? 0.75 : 0.45))
                }
                .buttonStyle(.plain)
                .help("Copy line")
            }
        }
    }

    private func copyLine() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(line.text, forType: .string)
        copied = true
        copyToken += 1
        let token = copyToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            if token == copyToken {
                copied = false
            }
        }
    }

    // MARK: Prefixes

    /// Converts prefixes at the start of a line into a line kind. Every conversion
    /// strips the prefix, so you do not see it back in the text.
    private func convertPrefix(_ text: String) {
        // A separator has no text field and therefore never changes through a prefix.
        guard line.isEditable else { return }

        // Backtick: mono on and off, from every editable line kind.
        if text.hasPrefix("`") {
            line.kind = line.kind == .mono ? .text : .mono
            line.text = String(text.dropFirst())
            return
        }

        // "---" and "# " apply to every editable line kind as well, so you do not have to
        // turn a checklist or mono line back into plain text first.
        if text == "---" {
            line.kind = .separator
            line.text = ""
            line.isDone = false
            onBecameSeparator()
            return
        }

        if text.hasPrefix("# ") {
            line.kind = .heading
            line.text = String(text.dropFirst(2).drop(while: { $0 == " " }))
            return
        }

        // "[] ", "[ ] " or "- [ ] " turns it into a checklist line. Only variants with a
        // trailing space, otherwise the conversion already fires while you are still typing.
        // Only from plain text: on a checklist line it would add nothing.
        guard line.kind == .text else { return }
        for prefix in ["- [ ] ", "[ ] ", "[] "] where text.hasPrefix(prefix) {
            line.kind = .checklist
            line.text = String(text.dropFirst(prefix.count).drop(while: { $0 == " " }))
            return
        }
    }
}

// MARK: - Mono block

/// Subtly rounded background block behind a monospace line.
private struct MonoBackground: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
        } else {
            content
        }
    }
}
