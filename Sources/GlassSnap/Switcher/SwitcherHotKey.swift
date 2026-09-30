import AppKit
import Carbon

/// Carbon reserves only Option+Tab and Option+Shift+Tab. Other keystrokes are
/// never intercepted while the panel is closed.
final class SwitcherHotKey {
    private var handler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    var pressed: ((Bool) -> Void)?
    func register() -> Bool {
        unregister()
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr else { return result }
            let hotkey = Unmanaged<SwitcherHotKey>.fromOpaque(context).takeUnretainedValue()
            hotkey.pressed?(identifier.id == 2)
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        for reverse in [false, true] {
            var ref: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: 0x47534E50, id: reverse ? 2 : 1)
            let modifiers = UInt32(optionKey) | (reverse ? UInt32(shiftKey) : 0)
            guard RegisterEventHotKey(UInt32(kVK_Tab), modifiers, identifier, GetApplicationEventTarget(), 0, &ref) == noErr,
                  let ref else { unregister(); return false }
            hotKeys.append(ref)
        }
        return true
    }
    func unregister() {
        hotKeys.forEach { UnregisterEventHotKey($0) }; hotKeys.removeAll()
        if let handler { RemoveEventHandler(handler) }; handler = nil
    }
    deinit { unregister() }
}
