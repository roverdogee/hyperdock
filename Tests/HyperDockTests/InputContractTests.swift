import CoreGraphics
import Testing
@testable import HyperDock

@Test func rightMouseDownMapsToConfiguredRightButton() {
    #expect(DockMouseButton(eventType: .rightMouseDown, buttonNumber: 1) == .right)
    let rightMouseBit: CGEventMask = 1 << CGEventType.rightMouseDown.rawValue
    #expect(WindowManager.eventMask & rightMouseBit != 0)
}

@Test func onlySupportedMouseDownEventsBecomeDockButtons() {
    #expect(DockMouseButton(eventType: .leftMouseDown, buttonNumber: 0) == .left)
    #expect(DockMouseButton(eventType: .otherMouseDown, buttonNumber: 2) == .middle)
    #expect(DockMouseButton(eventType: .otherMouseDown, buttonNumber: 3) == nil)
    #expect(DockMouseButton(eventType: .leftMouseUp, buttonNumber: 0) == nil)
}

@Test func everySelectableModifierRoundTripsThroughEventFlags() {
    let expected: [(ModifierCombo, CGEventFlags)] = [
        (.control, .maskControl),
        (.option, .maskAlternate),
        (.command, .maskCommand),
        (.shift, .maskShift),
    ]

    #expect(ModifierCombo.userSelectable == expected.map(\.0))
    for (modifier, flags) in expected {
        #expect(ModifierCombo(eventFlags: flags) == modifier)
    }
}
