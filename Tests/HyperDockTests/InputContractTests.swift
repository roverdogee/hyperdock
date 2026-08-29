import CoreGraphics
import Testing
@testable import HyperDock

@Test func previewInputTapOnlyObservesKeyboardAndScroll() {
    let keyBit: CGEventMask = 1 << CGEventType.keyDown.rawValue
    let scrollBit: CGEventMask = 1 << CGEventType.scrollWheel.rawValue
    let mouseBit: CGEventMask = 1 << CGEventType.leftMouseDown.rawValue
    let dragBit: CGEventMask = 1 << CGEventType.leftMouseDragged.rawValue

    #expect(PreviewInputMonitor.eventMask & keyBit != 0)
    #expect(PreviewInputMonitor.eventMask & scrollBit != 0)
    #expect(PreviewInputMonitor.eventMask & mouseBit == 0)
    #expect(PreviewInputMonitor.eventMask & dragBit == 0)
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
