import Foundation
import AppKit
import Carbon.HIToolbox

class GlobalKeyboardShortcut {
    private var monitor: Any?
    private let action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
    }

    func register() {
        // ⌘ + Shift + L
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandShift = modifiers == [.command, .shift]
            let isL = event.keyCode == UInt16(kVK_ANSI_L)

            if isCommandShift && isL {
                DispatchQueue.main.async {
                    self.action()
                }
            }
        }

        // Also monitor local events (when our app is focused)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let isCommandShift = modifiers == [.command, .shift]
            let isL = event.keyCode == UInt16(kVK_ANSI_L)

            if isCommandShift && isL {
                DispatchQueue.main.async {
                    self.action()
                }
                return nil // consume the event
            }
            return event
        }
    }

    func unregister() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        unregister()
    }
}
