import Carbon.HIToolbox

@MainActor
final class HotKey {
    private static var nextID: UInt32 = 1
    private static let signature: OSType = 0x46474C4B // "FGLK"

    private let id: UInt32
    private let handler: @MainActor () -> Void
    nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
    nonisolated(unsafe) private var handlerRef: EventHandlerRef?

    init?(
        keyCode: UInt32 = UInt32(kVK_ANSI_G),
        modifiers: UInt32 = UInt32(cmdKey | shiftKey),
        handler: @escaping @MainActor () -> Void
    ) {
        id = Self.nextID
        Self.nextID += 1
        self.handler = handler

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
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
            guard status == noErr else { return status }
            let hotKey = Unmanaged<HotKey>.fromOpaque(userData).takeUnretainedValue()
            return MainActor.assumeIsolated {
                guard hotKeyID.signature == HotKey.signature, hotKeyID.id == hotKey.id else {
                    return OSStatus(eventNotHandledErr)
                }
                hotKey.handler()
                return noErr
            }
        }

        let selfPointer = Unmanaged.passUnretained(self).toOpaque()
        guard InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPointer, &handlerRef) == noErr else {
            return nil
        }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef) == noErr else {
            if let handlerRef { RemoveEventHandler(handlerRef) }
            return nil
        }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
