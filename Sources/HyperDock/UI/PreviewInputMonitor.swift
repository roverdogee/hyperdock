import AppKit
import CoreGraphics

/// Receives keyboard input on behalf of an open preview bubble.
@MainActor
protocol BubbleKeyboardHandling: AnyObject {
    var isAcceptingKeys: Bool { get }
    func handleKey(_ key: BubbleKey) -> Bool
}

enum BubbleKey: Sendable {
    case left, right, up, down
    case confirm
    case dismiss
    case closeWindow
}

/// Supplies global keyboard navigation and scrolling to the non-activating preview panel.
///
/// The callback only reads event scalars and delegates immediately; Accessibility work
/// remains outside the event delivery path so WindowServer cannot disable the tap for
/// taking too long.
@MainActor
final class PreviewInputMonitor {
    static let eventMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.scrollWheel.rawValue)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    weak var keyboardTarget: (any BubbleKeyboardHandling)?
    var bubbleScrollHandler: ((CGPoint, Int64, Int64, Bool) -> Bool)?

    @discardableResult
    func start() -> Bool {
        if tap != nil { return true }
        guard Permissions.shared.hasAccessibility else { return false }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<PreviewInputMonitor>
                    .fromOpaque(refcon).takeUnretainedValue()

                let location = event.location
                let flags = event.flags
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let lineY = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
                let lineX = event.getIntegerValueField(.scrollWheelEventDeltaAxis2)
                let pointY = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
                let pointX = event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
                let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)

                let swallow = MainActor.assumeIsolated {
                    monitor.handle(type: type, location: location, flags: flags,
                                   keyCode: keyCode, lineX: lineX, lineY: lineY,
                                   pointX: pointX, pointY: pointY,
                                   isMomentum: momentum != 0)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.windows.error("could not create the preview input tap")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        runLoopSource = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        keyboardTarget = nil
        bubbleScrollHandler = nil
    }

    private func handle(type: CGEventType,
                        location: CGPoint,
                        flags: CGEventFlags,
                        keyCode: Int64,
                        lineX: Int64,
                        lineY: Int64,
                        pointX: Int64,
                        pointY: Int64,
                        isMomentum: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard !Preferences.shared.disabled, !MissionControlDetector.isActive else {
            return false
        }

        switch type {
        case .keyDown:
            return handleKey(flags: flags, keyCode: keyCode)
        case .scrollWheel:
            let vertical = lineY != 0 ? lineY : pointY
            let horizontal = lineX != 0 ? lineX : pointX
            return bubbleScrollHandler?(location, vertical, horizontal, isMomentum) ?? false
        default:
            return false
        }
    }

    private func handleKey(flags: CGEventFlags, keyCode: Int64) -> Bool {
        if Self.isSettingsHotKey(keyCode: keyCode, flags: flags) {
            Task { @MainActor in
                SettingsWindowController.shared.show(selecting: .general)
            }
            return true
        }

        guard let target = keyboardTarget, target.isAcceptingKeys,
              let key = Self.bubbleKey(keyCode: keyCode, flags: flags)
        else { return false }
        return target.handleKey(key)
    }

    private static func isSettingsHotKey(keyCode: Int64, flags: CGEventFlags) -> Bool {
        let preferences = Preferences.shared
        guard preferences.settingsHotKeyEnabled,
              !preferences.settingsHotKeyModifiers.isEmpty,
              keyCode == 4 /* h */ else { return false }
        return ModifierCombo(eventFlags: flags) == preferences.settingsHotKeyModifiers
    }

    private static func bubbleKey(keyCode: Int64, flags: CGEventFlags) -> BubbleKey? {
        let combo = ModifierCombo(eventFlags: flags)
        switch keyCode {
        case 123 where combo.isEmpty: return .left
        case 124 where combo.isEmpty: return .right
        case 126 where combo.isEmpty: return .up
        case 125 where combo.isEmpty: return .down
        case 36 where combo.isEmpty, 76 where combo.isEmpty: return .confirm
        case 53: return .dismiss
        case 13 where combo == [.command]: return .closeWindow
        default: return nil
        }
    }
}
