import SwiftUI

/// The little tab that stays at the screen edge when a note is tucked away.
/// Clicking brings the note back, dragging vertically moves the tab along the edge.
struct TuckTabView: View {
    @ObservedObject var store: NoteStore
    let noteID: UUID
    let onClick: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var note: Note {
        store.note(with: noteID) ?? NoteStore.placeholder
    }

    private var edge: TuckEdge {
        note.tuckedEdge ?? .left
    }

    var body: some View {
        ZStack {
            shape
                .fill(note.color.background(scheme))
                .overlay(shape.strokeBorder(note.color.accent(scheme).opacity(0.6), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 3, x: edge == .left ? 2 : -2, y: 0)

            Image(systemName: edge == .left ? "chevron.right" : "chevron.left")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.65))
        }
        .frame(width: Note.tabSize.width, height: Note.tabSize.height)
        .contentShape(Rectangle())
        .overlay(WindowDragHandle(onClick: onClick))
        .help(note.menuTitle)
    }

    /// Only the side that points into the screen is rounded.
    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: edge == .left ? 0 : 8,
            bottomLeadingRadius: edge == .left ? 0 : 8,
            bottomTrailingRadius: edge == .left ? 8 : 0,
            topTrailingRadius: edge == .left ? 8 : 0,
            style: .continuous
        )
    }
}
