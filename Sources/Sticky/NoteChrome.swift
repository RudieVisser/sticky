import Foundation
import SwiftUI

/// Window state that the SwiftUI content of a note needs to know, but that does not belong
/// in the model (and therefore not in `notes.json`).
///
/// The controller owns it; the view only reads. Deliberately a separate object and not the
/// `NoteStore`, so that activating or an edge glow does not trigger an autosave.
@MainActor
final class NoteChrome: ObservableObject {
    /// The note is "activated": the panel is key. Only then do we show hover cursors
    /// (resize edges, move cursor) and a slightly more pronounced border.
    @Published var isActivated = false

    /// During a drag the mouse touches a real screen edge: letting go will tuck it.
    @Published var isEdgeHighlighted = false
}
