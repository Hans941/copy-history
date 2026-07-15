import AppKit
import Carbon

final class KeyboardShortcutManager: NSObject, ObservableObject {
    private struct HotKeyDefinition {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private let hotKeyDefinitions: [HotKeyDefinition] = [
        HotKeyDefinition(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey | cmdKey)),
        HotKeyDefinition(keyCode: UInt32(kVK_ANSI_Grave), modifiers: UInt32(controlKey))
    ]

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?
    private var globalKeyMonitor: Any?
    private let hotKeySignature = OSType(UInt32(truncatingIfNeeded: 0x54474c48))
    private let modifierMask: NSEvent.ModifierFlags = [.control, .option, .command, .shift]
    private let toggleDebounceInterval: TimeInterval = 0.2
    private var lastToggleTimestamp: TimeInterval = 0

    var onTogglePanel: (() -> Void)?

    func configure(onTogglePanel: (() -> Void)?) {
        self.onTogglePanel = onTogglePanel
    }

    func start() {
        guard hotKeyHandler == nil else { return }
        var eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (nextHandler, event, userData) -> OSStatus in
            guard let userData else { return noErr }
            let manager = Unmanaged<KeyboardShortcutManager>.fromOpaque(userData).takeUnretainedValue()
            return manager.handle(event: event)
        }, 1, &eventSpec, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)

        registerHotKeys()
        startGlobalMonitor()
    }

    func stop() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
        if let hotKeyHandler {
            RemoveEventHandler(hotKeyHandler)
            self.hotKeyHandler = nil
        }
        stopGlobalMonitor()
    }

    deinit {
        stop()
    }

    private func registerHotKeys() {
        for (index, definition) in hotKeyDefinitions.enumerated() {
            var ref: EventHotKeyRef?
            let hotKeyId = EventHotKeyID(signature: hotKeySignature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(definition.keyCode,
                                             definition.modifiers,
                                             hotKeyId,
                                             GetApplicationEventTarget(),
                                             0,
                                             &ref)
            if status == noErr, let ref {
                hotKeyRefs.append(ref)
            } else {
                ClipLog.error("注册快捷键失败，code=\(status)")
            }
        }
    }

    private func handle(event: EventRef?) -> OSStatus {
        guard let event else { return noErr }
        var hotKeyID = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
        if hotKeyID.signature == hotKeySignature {
            triggerPanelToggle()
        }
        return noErr
    }

    private func startGlobalMonitor() {
        guard globalKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleGlobalKey(event)
        }
    }

    private func stopGlobalMonitor() {
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func handleGlobalKey(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        guard matchesHotKey(event) else { return }
        triggerPanelToggle()
    }

    private func matchesHotKey(_ event: NSEvent) -> Bool {
        let eventModifiers = event.modifierFlags.intersection(modifierMask)
        for definition in hotKeyDefinitions {
            let expectedModifiers = modifierFlags(from: definition.modifiers)
            if event.keyCode == UInt16(definition.keyCode), eventModifiers == expectedModifiers {
                return true
            }
        }
        return false
    }

    private func modifierFlags(from modifiers: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    private func triggerPanelToggle() {
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastToggleTimestamp < toggleDebounceInterval {
            return
        }
        lastToggleTimestamp = now
        DispatchQueue.main.async { [weak self] in
            self?.onTogglePanel?()
        }
    }
}
