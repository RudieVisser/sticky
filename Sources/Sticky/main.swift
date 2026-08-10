import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let store = NoteStore.shared
    private var manager: NoteWindowManager?
    private var statusBar: StatusBarController?
    private var quickCapture: QuickCaptureController?
    private var search: NoteSearchController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let manager = NoteWindowManager(store: store)
        self.manager = manager
        let quickCapture = QuickCaptureController(store: store, manager: manager)
        self.quickCapture = quickCapture
        let search = NoteSearchController(store: store, manager: manager)
        self.search = search
        self.statusBar = StatusBarController(
            store: store,
            manager: manager,
            quickCapture: quickCapture,
            search: search
        )

        // Panels are created in the last known state; hidden stays hidden.
        manager.start()

        // Hide/show everything.
        HotKeyCenter.shared.register(
            keyCode: HotKeyCodes.s,
            modifiers: HotKeyCodes.optionCommand
        ) { [weak manager] in
            manager?.toggleAllHidden()
        }

        // Quick capture.
        HotKeyCenter.shared.register(
            keyCode: HotKeyCodes.n,
            modifiers: HotKeyCodes.optionCommand
        ) { [weak quickCapture] in
            quickCapture?.toggle()
        }

        // Note from clipboard.
        HotKeyCenter.shared.register(
            keyCode: HotKeyCodes.v,
            modifiers: HotKeyCodes.optionCommand
        ) { [weak self, weak manager] in
            guard let self else { return }
            NoteTransfer.makeNoteFromClipboard(store: self.store, manager: manager)
        }

        // macOS Services ("Make Sticky Note"). Requires a bundled app; the entry lives
        // in Info.plist under NSServices.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
    }

    /// Target method of the Service. The name has to match NSMessage in Info.plist.
    @objc func makeStickyNote(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString>?
    ) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            error?.pointee = "No text found to make a note from." as NSString
            return
        }
        NoteTransfer.makeNote(from: text, store: store, manager: manager)
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
        // The current positions belong to the current screen configuration.
        manager?.captureCurrentLayout()
        store.saveNow()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }
}

// The delegate is held weakly by NSApplication, so we keep it around globally.
let appDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = appDelegate
    application.setActivationPolicy(.accessory)
    application.run()
}
