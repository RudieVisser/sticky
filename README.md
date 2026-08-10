# Sticky

Small always-on-top sticky notes for macOS, living in the menu bar.

Notes float above every window, show up on all Spaces and stay visible over fullscreen apps. You
manage them from a menu bar icon; nothing appears in the Dock. Each note is a list of plain text
lines and checkable todo lines.

## Features

- **Tuck them away like a PiP video.** Drag a note to the left or right edge of your screen and let
  go. It slides off screen and leaves a small tab behind. Hover the tab and the note peeks back into
  view, click it and the note slides back to where it was.
- **Quick capture.** One keystroke opens a single-line input in the middle of your screen. Enter
  appends the line to your inbox note, shift-Enter turns it into a brand new note.
- **Note from clipboard, or from any app.** Paste a block of text and Sticky parses it into a title,
  headings and checkboxes. The same works through the macOS Services menu ("Make Sticky Note") on
  any selected text.
- **Per-monitor layouts.** Sticky remembers where every note lives for each screen arrangement. Dock
  your laptop and the notes move to their desk positions; undock and they move back.
- **Line types and links.** Headings, monospaced lines, separators and checkboxes. URLs, email
  addresses and ticket codes such as `ABC-123` become clickable (cmd-click opens them).
- **Search.** Filter all notes by title or line content and jump straight to the match.
- **Per note styling.** Six colors, three text sizes, a compact mode and an opacity slider so a note
  can sit quietly on top of your work until you hover it.
- **A dangling buddy.** There is a little knob on the bottom edge of every note. Click it. That is
  all the documentation this feature gets.

## Requirements

macOS 14 or newer and a Swift 6 toolchain. No external dependencies, and no accessibility
permissions: the global shortcuts go through Carbon's `RegisterEventHotKey`.

## Build and run

```sh
make build    # swift build -c release
make bundle   # creates build/Sticky.app and signs it ad hoc
make run      # bundles and launches the app
make clean    # removes build/ and .build/
```

To keep it around, drag `build/Sticky.app` into your Applications folder and switch on "Launch at
Login" in the menu.

## How it works

### Keyboard shortcuts

| Shortcut | What it does |
|---|---|
| `⌥⌘S` | Hide or show all notes |
| `⌥⌘N` | Quick capture |
| `⌥⌘V` | New note from the clipboard |

These are global and work from any app. Inside a note, `⌘Z` undoes the last cleanup of checked
lines, and `Esc` hands keyboard focus back to the app you were working in.

### Gestures

- Drag the header of a note to move it.
- Drag it past the left or right screen edge and release to tuck it away.
- Click the tab at the edge to bring the note back; drag the tab up and down to move it along the
  edge.
- Enter starts a new line below, with the same checkbox state as the line you were on.
- Backspace at the start of a line merges it into the line above.
- Option plus the up or down arrow moves a line.
- Drag the grip on the left of a line to reorder it.
- Click the color dot in the header for another color, the text size, the opacity and compact mode.
- The cross deletes the note. The first click turns it red, a second click within two seconds
  actually deletes.

### Typing conventions

Type these at the start of a line and the prefix disappears into the formatting.

| Type | You get |
|---|---|
| `# ` | A heading |
| `---` | A separator line |
| `` ` `` | A monospaced line (type it again to go back) |
| `[] ` | A checkbox (`[ ] ` and `- [ ] ` work too) |

The same prefixes are understood when you paste a block of text into a new note, along with
`- [x] ` for a checked item and `## ` for a heading. Copying a note back out gives you either plain
text or Markdown.

## Where your notes live

In `~/Library/Application Support/Sticky/`.

- `notes.json` holds the notes themselves.
- `state.json` holds whether everything is hidden and the ticket base URL.
- `layouts.json` holds the note positions per screen arrangement.

Saving happens half a second after each change, and once more on quit. An unreadable `notes.json` is
moved aside as `notes.json.bak` rather than overwritten.

## License

MIT. See [LICENSE](LICENSE).
