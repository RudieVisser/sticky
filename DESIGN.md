# Sticky - always-on-top sticky notes for macOS

## Goal
Small sticky notes (text + checkable todo lines) that are always visible: above every window,
on every Space, and on top of fullscreen apps. Managed from a menu bar icon. Everything can be
hidden/shown in one go (menu bar + global hotkey). Each note can be dragged to the left or right
edge of the screen so that it "tucks away" like an iOS PiP video: all that is left is a small
arrow tab at the edge; click it and the note slides back into view.

## Technical constraints
- Swift 6 toolchain, target macOS 14+. Swift Package Manager executable, no Xcode project.
- AppKit for windows/panels/menu bar; SwiftUI (via NSHostingView) for the note content.
- `swift build` must succeed. A `Makefile` bundles the whole thing into `Sticky.app` (a script
  copies the binary + Info.plist into a .app structure) and `make run` launches it.
- Info.plist: `LSUIElement = true` (no Dock icon), bundle id `nl.rudievisser.sticky`.
- No external dependencies. No accessibility permissions needed: the global hotkey goes through
  Carbon `RegisterEventHotKey`.
- Swift 6 strict concurrency: everything that touches AppKit is `@MainActor`.

## Architecture (files under `Sources/Sticky/`)
- `main.swift` - NSApplication bootstrap, `AppDelegate`.
- `Models.swift` - `Note`, `NoteLine`, `NoteColor`.
- `NoteStore.swift` - observable store, JSON persistence, debounced autosave.
- `NoteWindowController.swift` - NSPanel per note, position/size, tuck behaviour.
- `NotePanel.swift` - NSPanel subclass (nonactivating, floating).
- `NoteView.swift` - SwiftUI note content (editor with line kinds, title bar, colour picker,
  text size) plus `NoteMetrics`, the sizing per note.
- `LineMarkup.swift` - detection of URLs, email addresses and ticket codes in a line.
- `NoteContainerView.swift` - AppKit carrier below the hosting view: hover tracking and our own
  edge resizing with the matching cursors.
- `TuckTabView.swift` - the arrow tab at the screen edge.
- `StatusBarController.swift` - NSStatusItem + menu.
- `HotKey.swift` - Carbon global hotkey wrapper, several hotkeys at the same time.
- `NoteChrome.swift` - window state the SwiftUI content needs to know but that does not belong in
  the model (`isActivated`, `isEdgeHighlighted`). A separate object, so that activating does not
  trigger an autosave.
- `NoteTransfer.swift` - text into and out of a note: parsing pasted/serviced text and exporting
  as plain text or Markdown.
- `QuickCapture.swift` - the ⌥⌘N input panel.
- `ScreenLayouts.swift` - `NoteLayoutEntry` (frame + tuck state of a single note) and
  `ScreenConfiguration.currentKey()`, the key of the current screen configuration.
- `NoteSearch.swift` - the search panel that opens from the menu bar menu.
- `DanglingBuddy.swift` - the dangling buddy: knob, verlet physics, drawing and the transparent
  child window below the note (see "Dangling buddy").

## Data model
```swift
enum NoteColor: String, Codable, CaseIterable { case yellow, pink, blue, green, purple, gray }

/// Kind of line. Replaces the separate bools from v1; a line has exactly one kind.
enum LineKind: String, Codable, CaseIterable { case text, checklist, heading, separator, mono }

enum TextSize: String, Codable, CaseIterable { case small, medium, large }

struct NoteLine: Codable, Identifiable, Equatable {
    var id: UUID
    var text: String
    var kind: LineKind      // .checklist has a checkbox, .separator has no text field
    var isDone: Bool        // checked → struck through + dimmed
    // derived: isChecklist (kind == .checklist), isEditable (kind != .separator)
}

struct Note: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String               // may be empty
    var lines: [NoteLine]           // at least 1 line
    var color: NoteColor
    var frame: CGRect               // last free (untucked) position/size
    var tuckedEdge: TuckEdge?       // nil = freely visible
    var tuckedY: CGFloat            // y position of the tab on the edge
    var createdAt: Date
    var opacity: Double             // 0.35...1.0, default 1.0
    var textSize: TextSize          // default .medium
    var isCompact: Bool             // less vertical space between lines
}

enum TuckEdge: String, Codable { case left, right }
```

## Persistence
- JSON file: `~/Library/Application Support/Sticky/notes.json` plus a small
  `state.json` (`allHidden: Bool`, `ticketBaseURL: String`) and `layouts.json` (positions per
  screen configuration, see "Positions per monitor arrangement").
- `Note` has a hand-written `init(from:)` that reads every field with `decodeIfPresent`. A
  `notes.json` from before a new field was added (such as `opacity`, `textSize`, `isCompact`)
  therefore still loads fine. The same goes for `AppState` in `state.json`.
- `NoteLine` likewise has its own `init(from:)`: if `kind` is missing, the old
  `isChecklist: true` is converted to `.checklist` and the rest to `.text`. Writing always happens
  in the new shape; `isChecklist` is no longer written out.
- Autosave with debounce (~0.5 s) on every mutation; also a synchronous write on app quit.
- Corrupt/missing file → start with a single welcome note that explains the gestures.

## Note windows
- `NSPanel` with `styleMask: [.nonactivatingPanel, .borderless]`, both free and tucked.
  Deliberately not `.titled`: a title bar keeps restoring the standard window buttons (visible
  above the rounded corners after a tuck/untuck) and pushes the SwiftUI content down with a
  contentView inset. Borderless solves both structurally; we do the resizing ourselves (see
  below). `NotePanel.hideStandardButtons()` remains as a safety net and runs after every
  styleMask change, every contentView swap, `show()` and `untuck()`.
- `isFloatingPanel = true`, `hidesOnDeactivate = false`, `becomesKeyOnlyIfNeeded = true`
  (see "Activation model").
- `level = .statusBar` so that they also float above fullscreen apps.
- `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]`.
- Clicking in the text makes the panel key so you can type, without activating the app
  (nonactivating panel); Esc gives focus back to the previous app (resign key).

### Activation model (cursors)
- `becomesKeyOnlyIfNeeded = true`: the panel becomes key when the content needs it (a click in a
  text field) or when we make it key ourselves. The drag handle (`WindowDragHandle.mouseDown`)
  and the resize strip (`NoteContainerView.mouseDown`) call `makeKeyAndOrderFront` for that
  before the drag starts, so activation does not hang off `performDrag` (which blocks until
  mouse-up); the colour dot does the same before opening the popover. A click on the header or on
  the content therefore activates, and a click in another app deactivates.
  **Why not `false`:** then every click makes every panel key, and Esc
  (`cancelOperation` → `orderOut`) hands the key status to some arbitrary other note panel
  instead of to the previous app. The same applied to closing QuickCapture.
- Becoming key is "activating". `NoteWindowController` listens for `windowDidBecomeKey` /
  `windowDidResignKey` and sets one flag: `NoteChrome.isActivated` (for SwiftUI) plus
  `NoteContainerView.isActivated` and `WindowDragHandle.isActivated` (for the cursors).
- The tracking areas are set to `.activeAlways` (otherwise no `mouseMoved` arrives as long as the
  panel is not key), but showing a cursor hangs off `isActivated`. Click in another app and the
  panel resigns key, so all cursor feedback disappears immediately.
- Cursors: resize cursors on the 6 pt edge strip, `NSCursor.openHand` above the header/drag zone
  and `closedHand` while dragging.
- Visual feedback: an activated note gets a thin border (1.5 pt) in the note's accent colour
  instead of the usual grey 1 pt border.
- Size: default 260×220, min 180×120. Resizing lives in `NoteContainerView`: a 6 pt strip along
  the edges and corners. That strip is withheld from SwiftUI via `hitTest`, sets the cursor in
  three ways (cursor rects, `cursorUpdate` and explicitly on every `mouseMoved`, so the hosting
  view's tracking cannot override it) and moves the frame in its own event loop with a `minSize`
  clamp. Cursors via `NSCursor.frameResize(position:directions:)` on macOS 15+, with
  `resizeLeftRight`/`resizeUpDown` as a fallback on macOS 14.
- `NoteContainerView` pins the hosting view to the full panel area and reports hover to the
  controller.
- Dragging: the whole header (title zone) is a drag area (`isMovableByWindowBackground` on the
  header zone, or manually via `performDrag(with:)` in a drag handle view).
- Appearance: rounded corners (12pt), pastel background per `NoteColor` with a subtle shadow, a
  darker variant in dark mode. The header is a single slim row of 28 pt flush against the top
  edge with 10 pt horizontal padding, and directly below it the lines (10 pt horizontal, 6 pt
  vertical).
  The header shows: colour dot (click = popover with the colour palette and opacity slider; the
  click makes the panel key first, otherwise a popover on a nonactivating panel refuses), title
  (editable, placeholder "Title"), drag zone, broom button (only when there are checked lines),
  ellipsis menu, close button (×, deletes the note after confirmation via a brief "are you
  sure" stage: the first click turns it red, the second click deletes; timeout 2 s).

## Opacity per note
- `note.opacity` (0.35...1.0) drives `panel.alphaValue`, for the tuck tab as well.
- Mouse above the note or the tab: to 1.0 in 0.15 s so it is always readable; back again on
  mouse-exit. Hover is reported by the tracking area of `NoteContainerView`.
- The fades of `hide()`/`show()`/`flash()` animate between 0 and this effective alpha, not
  between 0 and 1.
- Adjustable through a compact slider with an opacity icon below the colour palette in the
  popover. Below that slider sit three buttons S/M/L for `textSize` and a toggle for `isCompact`.

## Editor (NoteView)
- Vertical list of lines. Every line: a fixed drag strip on the left (12 pt), an optional
  checkbox, a text field (plain, no formatting) and hover buttons on the right.
- Enter → a new line below it, focus moves along. `.checklist` and `.mono` are inherited, a
  heading or separator is not (below those you get ordinary text).
- Backspace at the start of a line → merge with the previous line. If there is a separator above
  it, that one disappears (a separator cannot take focus itself).
- **Limitation (deliberate):** backspace only merges from an empty line. `onKeyPress(.delete)`
  cannot see the cursor position in a SwiftUI TextField, so "cursor is at the front" cannot be
  told apart from "cursor is somewhere in the middle"; only with empty text is it unambiguous.
  Consequence: a separator above a filled line or as the last line cannot be removed with
  backspace. That is why a separator row shows a small × button on the right on hover that
  removes it, and why a click in the empty area below the lines adds a new line when the last
  line is not editable (or is checked).
- Toggling a checkbox: click the checkbox. `isDone` → text struck through + 50% opacity.
- An empty note (no text) shows the placeholder "Type here…".
- Scrollable when the content does not fit.

### Line kinds and prefixes
Prefixes are converted in `onChange(of: line.text)`; the prefix itself disappears from the text.
Which prefixes apply depends on the line kind you are coming from.

| Prefix | Works from | Becomes |
|---|---|---|
| Backtick at the start | any editable kind | `.mono`; from `.mono` it goes back to `.text` |
| `---` (exact) | any editable kind | `.separator` |
| `# ` at the start | any editable kind | `.heading` |
| `[] `, `[ ] `, `- [ ] ` | only `.text` | `.checklist` |

- `.separator` has no text field and therefore never changes through a prefix.
- The checklist prefixes only apply with a trailing space (otherwise they kick in while you are
  still typing) and only from ordinary text; on a checklist line they would add nothing. Turning
  a checkbox on or off is always possible through the ☑ button on hover.
- `.heading`: bold and larger, no checkbox.
- `.mono`: SF Mono (`design: .monospaced`) with a subtly rounded background block
  (`Color.primary.opacity(0.07)`, radius 4).
- `.separator`: a thin line across the full width, no text field. The text is cleared and a new
  line appears right below it with the focus. On hover an × button appears on the right that
  removes the line.

### Links and ticket codes (`LineMarkup`)
- `LineMarkup` (main actor, regexes as stored values) detects, in order, URLs
  (`https?://…`, trailing punctuation is trimmed off), email addresses and ticket codes
  (`[A-Z][A-Z0-9]+-\d+`). Overlapping hits are skipped, so a code inside a URL does not count
  separately.
- Email addresses come out of a hand-written, linear scan and not out of a regex: the obvious
  pattern (`[..]+@[..]+\.[A-Za-z]{2,}`) backtracks quadratically and made a pasted token of a few
  thousand characters containing an at-sign freeze the note for seconds. The scan walks the text
  once and expands left and right around every at-sign.
- The spans that are found are cached per (line text, ticket base); every render asks for them at
  least twice (`hasLinks` and `attributed`). Above 2000 characters per line we skip link
  detection entirely.
- Ticket codes only become a link when `ticketBaseURL` is filled in; the code is appended with
  exactly one slash in between (or directly, if the base ends in `/` or `=`).
- A TextField does not render links. That is why a line that does not have the focus and does
  contain links renders as `Text` with an `AttributedString`; clicking turns it back into the
  text field. Lines without links always stay a TextField, so that typing and placing the cursor
  there remain unchanged.
- Links get a calm, slightly different tint (no underline). An ordinary click puts the cursor in
  the line, cmd-click opens it. That distinction lives in a custom `OpenURLAction` that reads
  `NSEvent.modifierFlags`; the tap layer for focus sits as a `background` behind the text, so
  that a click on a link reaches the link first.
- Limitation: when switching from `Text` to `TextField` the cursor ends up at the end of the
  line, not at the click position.

### Copying, reordering and sizing
- Hovering over a line shows a copy icon on the right (`doc.on.doc`); clicking puts the line text
  on `NSPasteboard` and the icon turns into a checkmark for 0.8 s. The buttons only take up space
  during hover.
- Reordering: option-arrow-up/down moves the focused line (via
  `.onKeyPress(keys: [.upArrow, .downArrow])` on the TextField, only with option held). On top of
  that, hover shows a grip on the left (`line.3.horizontal`) with `.draggable`; every line is a
  `.dropDestination(for: String.self)` that puts the dragged line id at the position of the
  target line. If a line moves down, it is inserted at `to - 1`: after the removal, every line
  after it has already shifted up one place. An id that does not exist in this note (a drag from
  another note) returns `false`, so the drop is refused cleanly instead of silently doing
  nothing.
  The drag strip has a fixed width so the text does not jump around on hover. The line list has
  7 pt leading padding, so the grip starts outside the 6 pt resize strip of
  `NoteContainerView`; otherwise the left edge of the grip would start a window resize.
- `NoteMetrics` derives all sizes from `note.textSize` (S/M/L) and `note.isCompact`: text,
  heading, checkbox and icon size plus line spacing and padding.

## Tuck behaviour (the PiP gesture)
- While dragging a note: simply allow the drag to go beyond the screen.
- **First trigger, the mouse position leads.** If on release the mouse is within 2 pt of the left
  or right edge of the screen the mouse is on, the note tucks to that edge, no matter how far the
  note itself hangs over the edge (`NoteWindowController.tuckEdgeUnderMouse()`).
  Multi-monitor: only a real screen edge counts. If there is an adjacent screen on that side
  (tested with a point just outside the edge at the height of the mouse), the transition is
  seamless and we do not tuck.
- **Second trigger (unchanged).** If the window centre is past the left or right edge of the
  current screen, or the edge is crossed by more than 40% of the width → tuck to that edge.
- Feedback during the drag: as soon as the mouse touches the edge the note goes to alpha 0.55 and
  gets a thicker border (2.5 pt) in the accent colour. The drag watcher timer (0.05 s) polls the
  mouse position for that; on release the edge is determined again, so moving away from the edge
  still cancels the tuck.
- **Only a real drag counts.** `windowDidMove` only starts the drag watcher with the mouse button
  held down, and that sets the flag `isDragging`. `finishDrag()` only runs when that flag is set
  and clears it immediately. If the system moves a panel without a mouse button (disconnecting a
  screen, a resolution change), nothing happens: that path used to write `panel.frame` into the
  model and could even tuck spontaneously, after which those polluted positions were recorded
  under the still-valid old layout key.
- As long as a screen change is being handled (`NoteWindowManager.isScreenChangePending`, from
  the notification until the end of the debounce handling), `windowDidMove` and `windowDidResize`
  write nothing at all into the model.
- Tuck animation (~0.25 s ease-out): the panel slides offscreen until only a tab of 22×64 pt is
  visible on the edge, vertically at the height where the note was released (clamped within the
  visible screen area). Implementation: the same panel temporarily gets the tab as its content
  (a separate small frame), or a second mini panel; pick whichever animates robustly.
- The tab (`TuckTabView`): rounded on the inside, in the note's colour, with a chevron
  (‹ or ›, pointing into the screen). Multiple tucked notes on the same edge stack vertically
  with 8 pt of space between them; never overlapping (redistribute on adding/removing).
- Click on the tab → the note slides back to its last free position (clamped within the screen),
  same animation.
- The tab can be dragged vertically along the edge (this adjusts `tuckedY`).
- Tuck state is persistent (`tuckedEdge`/`tuckedY` in the model): tucked again after a restart.

## Peek on hovering a tuck tab
- Rest the mouse on a tab for 0.4 s and the note slides into view temporarily:
  `min(0.5 × note width, 180 pt)` visible, the same 0.25 s ease-out animation. If the mouse
  leaves the note or the tab, it slides away again after 0.2 s. The hover delay prevents a mouse
  that just flies past from triggering it.
- **The peek changes nothing in the model.** `tuckedEdge`, `tuckedY` and `frame` stay as they
  are; it is purely a temporary frame shift of the same panel. During the peek the panel gets the
  ordinary note content (`ContentMode.peek` in `NoteWindowController.applyContent`) and is set to
  note size, with the note largely off screen: you see the edge that points into the screen.
- During the peek a `PeekCatcherView` lies over the content. It intercepts every mouse click, so
  the text fields do not become editable and a click calls the same `untuck()` as a click on the
  tab. The note then continues on to its free position instead of first sliding back.
  `isResizable` is off, so the resize edge does nothing either.
- Coordination with the rest:
  - `finishDrag` stops immediately when `isPeeking`; `panel.frame` is a temporary spot then and
    must never end up in the store as `tuckedY` or as the free frame. The same goes for
    `windowDidMove`, `windowDidResize` and `setTabFrame` (which leaves a peeking panel alone).
  - A drag aborts the peek; a peek does not start while the mouse button is held down or while a
    frame animation is still running. Such an abort is temporary: as long as the mouse keeps
    hanging over the tab, `beginPeek()` schedules itself again, otherwise the peek would be gone
    until you left the tab and approached it again.
  - After `tuck()` the hover is re-tested against the mouse position (in the completion of the
    tuck animation). The hover state of the large note says nothing about the small tab, and
    without that re-test a mouse that was already above the new tab did not count as hover.
  - `hide()`, `tuck()`, `untuck()`, `applyLayout` and `close()` end a running peek.
    `hide()` ends the peek first and only clears `isHovering` afterwards; the other way around
    the re-test in `endPeek` set it back to true and the note came back after "Show All" at alpha
    1.0 instead of at its own opacity. `syncHoverWithMouse()` skips the test as soon as the panel
    is not supposed to be visible.
  - All direct frame assignments (peek, `move`, `applyLayout`, `clampToVisibleScreens`,
    `setTabFrame`) go through `setFrameNow`: an animation group with duration 0 on
    `panel.animator()`. A bare `setFrame` lets a running animation on the same property continue,
    and that animation then writes back its own target frame; hiding during the peek slide-in
    animation left the panel deformed because of that.
  - The existing hover opacity keeps working (the mouse is above the note, so alpha 1.0). After
    sliding back, the hover state is re-tested against the mouse position, otherwise a note would
    stay opaque while the mouse was long gone.
  - Besides mouse-exit, a timer of 0.15 s runs during a peek that checks whether the mouse is
    still hanging above the panel. That is needed because the panel slides out from under the
    mouse and the tracking area then does not always produce a clean enter/exit.

## Positions per monitor arrangement
- Notes and tuck tabs remember their spot per screen configuration. `layouts.json` contains, per
  configuration key, a table of note id → `{frame, tuckedEdge, tuckedY}`.
- **The key** (`ScreenConfiguration.currentKey()`) is the physical identity of every connected
  screen (`CGDisplayVendorNumber`/`ModelNumber`/`SerialNumber` via the `NSScreenNumber` from
  `deviceDescription`) plus its size and place in the global coordinate system, sorted by
  position. Deliberately not the bare `CGDirectDisplayID`: that one is handed out on connection
  and can differ each time, whereas vendor/model/serial number are attached to the screen itself
  and therefore survive a dock/undock and a restart. By sorting on position, the order of
  `NSScreen.screens` does not matter.
- **The model stays the source for the active configuration.** `Note.frame`/`tuckedEdge`/`tuckedY`
  lead; the layout table is an overlay for the configurations that are not active right now.
- Keeping track: `NoteWindowManager.captureCurrentLayout()` writes the spot of all notes under
  the active key and runs at the end of every `sync()` (so on every model change) and on app
  quit. That way new notes end up in the active layout by themselves and deleted ones drop out of
  it. Deleting also removes the note from all layouts (`NoteStore.removeFromLayouts`), and on
  loading, references to unknown notes are cleaned up.
- Capture reads from the **model**, not from `panel.frame`. That way there is no way to record an
  intermediate frame in the middle of a tuck, untuck or peek animation: at that moment the model
  is already at the final value.
- On `didChangeScreenParametersNotification` (macOS fires those in salvos) a debounce of 0.4 s
  waits until things settle. After that:
  1. if the key is unchanged, only clamp to the visible area and rearrange the tabs;
  2. otherwise first record the current positions under the old key, then switch over, then apply
     the stored layout of the new key with animation. A note that this configuration does not
     know anything about yet is clamped to the visible area, exactly as before.
- On startup the stored layout of the current arrangement is applied (read out before the first
  `sync()`, otherwise that would overwrite it with the positions from `notes.json`, and those
  belong to the arrangement of the previous session).
- **Limitation**: rearranging screens or picking a different resolution produces a new key. That
  is deliberate (it is a different arrangement), but it does mean that the first time after such
  a change you have to place your notes again. If CoreGraphics reports no vendor/model/serial
  number (virtual screens, some adapters), the key falls back to the display id and a layout can
  expire after reconnecting.

## Hotkeys
`HotKeyCenter` registers several Carbon hotkeys side by side (an id per registration, one shared
event handler): ⌥⌘S hides/shows everything, ⌥⌘N opens quick capture, ⌥⌘V makes a note from the
clipboard.

## Hide/show everything
- Menu bar item "Hide All" / "Show All" + global hotkey ⌥⌘S (Carbon hotkey).
- Hiding: `orderOut` all panels (tabs included) with a short fade. Showing: back in exactly the
  same state (tucked stays tucked).
- `allHidden` is persistent; the app starts in the last known state.

## Quick capture (⌥⌘N)
- A second Carbon hotkey. `QuickCaptureController` opens a borderless nonactivating `NSPanel`
  of 460×48 at `level = .statusBar`, centred on the screen the mouse is on, with an
  `NSVisualEffectView` and a single `NSTextField` ("Quick capture…") as first responder.
- Enter → the line goes into the inbox note: the oldest note (`min(by: createdAt)`), or a new
  note "Inbox" if there is nothing yet. An empty last line is reused instead of adding another
  line. If the text starts with `[] ` (or `- `, `* `, `[x] `), it becomes a checklist line; that
  goes through the same parser as the import (`NoteTransfer.line(from:)`).
- Shift-Enter (`insertNewlineIgnoringFieldEditor:`) → an entirely new note with that text.
- Esc, a click outside it (global mouse monitor) or `windowDidResignKey` closes it without doing
  anything.
- After Enter the panel flashes briefly (alpha to 0.25 in 0.09 s) and closes. `commit(_:)` sets
  `isClosing` to true right at the start: putting the text away can make another panel key (with
  Shift-Enter the new note), and then `windowDidResignKey` used to close this panel before the
  flash.
- Limitation: the panel calls `NSApp.activate()` before `makeKeyAndOrderFront`. A panel of an
  inactive app otherwise gets no keyboard focus without a mouse click. The app is an accessory
  (no Dock icon), so that is invisible anyway.

## Searching from the menu bar
- Menu item "Find Note…" with ⌘F as the key equivalent within the opened menu. That opens
  `NoteSearchController`: a borderless nonactivating `NSPanel` 420 pt wide at
  `level = .statusBar`, centred on the screen the mouse is on, with an
  `NSVisualEffectView`, a single `NSTextField` at the top and the hit list below it.
- Typing filters live on title and line text, case and accent insensitive
  (`folding(options: [.caseInsensitive, .diacriticInsensitive])`). Every hit shows a colour dot,
  the menu title and the line the hit is in; at most 7 rows, the panel grows downwards along with
  it and the top edge stays put.
- The selection stays within the shown rows (`min(number of hits, 7) - 1`), otherwise the arrow
  selection ran off the list and Enter opened a hit that was not in view.
- If a hit is only in the title, the detail line falls back to the first filled line instead of
  staying empty.
- Arrow up/down moves the selection, Enter brings the selected note (by default the top one) into
  view via `NoteWindowManager.reveal` (unhide if hidden, untuck if tucked, a short flash).
  Clicking a row does the same. Esc, a click outside it (global mouse monitor) or
  `windowDidResignKey` closes it without any action.
- **Choice made**: deliberately a floating panel and not an `NSSearchField` as a view item inside
  the `NSMenu`. An opened `NSMenu` runs its own event loop and intercepts key presses for
  type-select; a text field in a menu item of an accessory app therefore does not hold the focus
  reliably, and arrow keys can then no longer be unambiguously assigned to either the menu or the
  field. The panel simply gets key status and can handle arrows, Enter and Esc neatly itself. It
  uses the same building blocks as `QuickCapture`, so its behaviour (activating, closing on a
  click outside) is already proven.
- **Limitation**: just like with quick capture, the panel calls `NSApp.activate()`, otherwise a
  panel of a background app gets no keyboard focus. The app is an accessory, so that is
  invisible.

## Cleaning up checked lines
- Broom button (`paintbrush`) in the note header, only visible when that note has checked
  checklist lines. Clicking removes them all.
- The menu bar action "Clean Up Checked Lines" does the same for all notes.
- If nothing is left, the note keeps one empty line.
- Undo: `NoteStore` keeps a **one-shot** buffer (`cleanupUndo: [UUID: [NoteLine]]`) with the
  previous `lines` of the notes involved, plus `cleanupPost` with the state right after the
  cleanup. Callable via ⌘Z within a note panel (`NotePanel.performKeyEquivalent`; the app has no
  Edit menu, so there is no other consumer of ⌘Z), via the ellipsis menu on the note and via the
  menu bar menu when there is something to restore.
- **Scope.** The menu bar action cleans up all notes and therefore buffers them all, but ⌘Z and
  the ellipsis menu within a panel restore only their own note
  (`undoLastCleanup(for:)`). Without that boundary, ⌘Z in note B undid a cleanup in note A.
- **Invalidation.** On every mutation of `notes`, the buffer of a note expires as soon as its
  `lines` differ from the post-cleanup state. That way undo can never destroy work that was typed
  after the cleanup; it used to put the lines back wholesale to the snapshot.
- **Limitation**: this is not an undo stack. Only the last cleanup action can be restored, a
  second cleanup action overwrites the buffer, and editing text cannot be undone with it.

## A note from other apps
- The menu bar action "Note from Clipboard" plus a third hotkey ⌥⌘V. An empty clipboard gives a
  beep.
- macOS Services: an `NSServices` entry in `Info.plist` ("Make Sticky note", `NSMessage`
  `makeStickyNote`, `NSSendTypes` utf8-plain-text) plus `NSApp.servicesProvider = self` and
  `NSUpdateDynamicServices()` in the `AppDelegate`. The provider method uses exactly the same
  parse path as the clipboard.
- **Limitation**: Services only work from a bundled app. `swift build` can compile the path, but
  registration only happens after `make bundle` and the first launch of `Sticky.app`. The menu
  item shows up in "Services" after that; sometimes only after a restart of the target app or
  logging in again.
- Parse rules (`NoteTransfer.parse`): a first short line (< 40 characters) that is followed by an
  empty line becomes the title. A leading `#` prefix is stripped off ("## Header" becomes the
  title "Header"), and a dash line (`---`, `***`, `___`) is not a title but a separator.
  Lines starting with `- `, `* `, `[] `, `[ ] ` or `- [ ] `
  become checklist lines; the `[x] ` variants come in checked. `# `/`## ` becomes a heading,
  `---`/`***`/`___` a separator.

## Copying as text or Markdown
- Ellipsis button (`ellipsis`) in the note header with "Copy as Text", "Copy as Markdown",
  "Clean Up Checked Lines" and "Undo Cleanup". The same menu hangs off the header as a
  `.contextMenu`.
- Plain text: the title, then the lines; a checklist with `✓ ` when checked and `· ` when open,
  separators as `---`.
- Markdown: the title as `## `, headings as `### `, checklists as `- [ ]`/`- [x]`, mono lines
  between backticks, separators as `---`.
- **Limitation**: right-clicking above the drag zone of the header ends up at the AppKit drag
  view and not at the SwiftUI context menu; that is why the same menu also sits under the
  ellipsis button.

## Menu bar (StatusBarController)
- SF Symbol `note.text` as a template icon.
- `menu.autoenablesItems = false`. The app is an accessory without a responder chain that could
  validate the items; with the default `true` the manual `isEnabled` did nothing and
  "Clean Up Checked Lines" and "Find Note…" were always clickable. The menu is rebuilt on every
  opening (`menuNeedsUpdate`), so that is where the enabled state is set.
- Menu:
  - "New Note" (⌘N within the menu) → a new note in the middle of the screen the mouse is on.
  - "Quick Capture… ⌥⌘N".
  - "Note from Clipboard ⌥⌘V".
  - "Find Note…" (⌘F within the menu).
  - "Clean Up Checked Lines" (+ "Undo Cleanup" when there is something in the buffer).
  - "Hide All ⌥⌘S" / "Show All ⌥⌘S" (toggling title).
  - A separator, then one row per note: colour dot + title (or the first text line, truncated at
    30 characters, "Empty note" if there is nothing) → clicking brings that note into view
    (untuck if needed, unhide if hidden, a short bounce/flash so you see it).
  - A separator, "Set Ticket URL…" → an NSAlert with a text field and an explanation
    ("for example https://yourcompany.atlassian.net/browse/"); emptying it turns ticket links
    off. The alert comes to the front with `NSApp.activate()`, otherwise it stays stuck behind
    other apps.
  - "Launch at Login" (checkbox, `SMAppService.mainApp`).
  - "Quit Sticky" (⌘Q).

## Dangling buddy (easter egg)
- At the bottom of every **free** note, in the middle of the bottom edge, sits a knob of 10 pt,
  half over the edge. Dimmed in the note colour (a darker tint of the accent colour), lighting up
  slightly on hover. A tuck tab and a peek do not show it.
- Click it and a rope of 140 pt rolls out with a stick figure on it (head, body, arms up on the
  rope, legs). Another click rolls it back up and cleans everything away.
- **Physics** (`BuddySimulation`): verlet integration, 14 segments of 10 pt, 5
  relaxation iterations per frame, gravity 1500 pt/s², air damping 0.992 on the rope and
  0.985 on the figure. The buddy is a point mass at the end (invMass 1/3.5 against 1 for
  a rope segment); its torso and two leg points are three extra verlet points with invMass
  1/1.4, so that arms and legs swing along. 60 fps via a `Timer` on `RunLoop.Mode.common`.
- **Rest**: if the kinetic energy (the sum of the squared displacements per frame) stays below
  the threshold for 0.35 s, the simulation sleeps and nothing more is drawn. It is woken by
  anchor movement, a grab or a cut.
- **The simulation computes in screen coordinates**, not in window coordinates. The rope window
  is a child window and therefore moves along with the note; if the points were in window
  coordinates, a drag would move the anchor and the mass at the same time and nothing would
  swing. In screen coordinates the mass stays where it was while the anchor walks away: that is
  exactly the swing you want to see when dragging a note. When drawing, the view only subtracts
  the window origin.
- **Grabbing**: a mouse-down within 16 pt of the figure pins the end point to the mouse (`prev`
  stays at the previous position, so it retains the speed of your hand and whips through on
  release). The distance to the anchor is clamped to 1.3 × rope length; beyond that the rope
  pulls it back instead of stretching along endlessly.
- **Cutting**: a click within 6 pt of the rope line, and only from segment 3 onwards (≈20% below
  the anchor) so you do not hit the knob. The constraint on that segment lapses: the lower part
  plus the buddy falls away under gravity and fades out in 0.6 s, the upper remnant flicks up
  weightlessly and fades in 0.45 s. After that only the knob is there again.
  No audio.
- **The window** (`BuddyWindow`): a borderless nonactivating `NSPanel`, `backgroundColor` clear,
  `isOpaque` false, `hasShadow` false, `level = .statusBar`, `canBecomeKey` false, hung off the
  note panel as `addChildWindow(_:ordered: .below)`. Frame = note width plus 180 pt of margin
  left and right (rope length + 40, so that a full swing stays within view) and 280 pt high. The
  ticker re-tests the frame against `panel.frame` every frame (that catches resizing; dragging is
  already handled by the child window itself) and copies `panel.alphaValue`, so that the opacity
  setting, the hover fade and `hide()`/`show()` follow along by themselves.
- **Mouse pass-through**: `ignoresMouseEvents` is **on** by default and only goes off, per frame,
  as long as the mouse is within the hit zone of the buddy or the rope. Deliberately the tracking
  route and not only `hitTest`: the window server decides for itself whether a click even reaches
  our window at all, and this window is large and virtually empty. `BuddyCanvasView.hitTest`
  still returns `nil` outside those zones as a second line of defence. During a grab the
  pass-through stays off.
- **The knob** sits as an AppKit subview (`BuddyKnobView`) in `NoteContainerView`, on top of the
  hosting view. It falls right in the middle of the bottom resize strip; `hitTest` and
  `applyCursor` give it priority there, but only within its own circle of 7 pt. The resize strip
  next to it therefore keeps working as usual.
- **Cleaning up**: tucking, hide-all, deleting, quitting and a screen change (`applyLayout`)
  remove the rope window immediately and stop the simulation. Untucking or showing brings only
  the knob back. No persistence: after a restart there is never a rope hanging.
- **Limitation**: on a very wild swing or right after a cut, part of the figure can fall outside
  the rope window and get clipped; the window is deliberately not full screen. On top of that
  there is ~16 ms of slack between the mouse and the pass-through switch, so an extremely fast
  click exactly on the rope can occasionally fall through to whatever lies beneath.

## Edge cases
- Multiple screens: tuck works on the edge of the screen the note is on; notes remember their
  screen through frame coordinates. Screen gone at restart → clamp to the main screen, unless
  that arrangement already has a stored layout (see "Positions per monitor arrangement").
- A note fully offscreen because of a screen change → clamp to the visible area on load.
- App quit → save synchronously.
- A new note while everything is hidden → unhide everything.

## Out of scope (v1)
- Sync/iCloud, formatting within a line (bold/italic on a selection), images,
  reminders/notifications, multiple "boards". Line kinds (heading, mono, separator) and clickable
  links are in; further markdown is not.
