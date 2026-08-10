import AppKit
import Carbon.HIToolbox

/// Global hotkeys via Carbon. Works without accessibility permissions.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var handler: EventHandlerRef?

    private init() {}

    /// Registers a hotkey. Returns `false` if that fails.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) -> Bool {
        installHandlerIfNeeded()

        let id = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: HotKeyCenter.signatureValue, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        guard status == noErr, let ref else {
            NSLog("Sticky: failed to register hotkey (status \(status))")
            return false
        }

        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        actions.removeAll()
    }

    fileprivate func fire(_ id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(GetApplicationEventTarget(), stickyHotKeyHandler, 1, &spec, nil, &handler)
    }
}

private func stickyHotKeyHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == HotKeyCenter.signatureValue else { return noErr }

    let id = hotKeyID.id
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            HotKeyCenter.shared.fire(id)
        }
    }
    return noErr
}

extension HotKeyCenter {
    /// Non-isolated copy of the signature for use in the C callback.
    nonisolated static var signatureValue: OSType {
        (OSType(83) << 24) | (OSType(84) << 16) | (OSType(75) << 8) | OSType(89) // "STKY"
    }
}

enum HotKeyCodes {
    static let s = UInt32(kVK_ANSI_S)
    static let n = UInt32(kVK_ANSI_N)
    static let v = UInt32(kVK_ANSI_V)
    static let optionCommand = UInt32(optionKey | cmdKey)
}
