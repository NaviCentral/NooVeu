import Testing
@testable import NooVeuShell

@Suite("KeyBindings")
struct KeyBindingsTests {
    private func action(_ key: KeyInput.Key, menu: Bool = false, repeating: Bool = false, fullScreen: Bool = false) -> KeyAction {
        KeyBindings.action(for: KeyInput(key, hasMenuModifier: menu, isRepeat: repeating), isFullScreen: fullScreen)
    }

    @Test(arguments: [KeyInput.Key.rightArrow, .downArrow, .pageDown, .space])
    func theseKeysGoToTheNextImage(key: KeyInput.Key) {
        #expect(action(key) == .run(.nextImage))
    }

    @Test(arguments: [KeyInput.Key.leftArrow, .upArrow, .pageUp, .delete])
    func theseKeysGoToThePreviousImage(key: KeyInput.Key) {
        #expect(action(key) == .run(.previousImage))
    }

    @Test func homeAndEndJumpToTheEnds() {
        #expect(action(.home) == .run(.firstImage))
        #expect(action(.end) == .run(.lastImage))
    }

    @Test(arguments: [("+", ViewerCommand.zoomIn), ("=", .zoomIn), ("-", .zoomOut), ("_", .zoomOut),
                      ("0", .actualPixels), ("1", .actualPixels), ("9", .zoomToFit)])
    func theZoomKeys(text: String, expected: ViewerCommand) {
        #expect(action(.character(text)) == .run(expected))
    }

    @Test func escapeLeavesFullScreenAndOtherwiseIsNotOurs() {
        #expect(action(.escape, fullScreen: true) == .run(.exitFullScreen))
        #expect(action(.escape, fullScreen: false) == .passThrough)
    }

    @Test(arguments: [KeyInput.Key.returnKey, .character("f")])
    func fullScreenTogglesOnceAndIgnoresAHeldKey(key: KeyInput.Key) {
        #expect(action(key) == .run(.toggleFullScreen))
        #expect(action(key, repeating: true) == .swallow, "a held key must not flicker in and out, nor beep")
    }

    @Test func aKeyWithNoMeaningIsLeftToTheSystem() {
        #expect(action(.character("x")) == .passThrough)
        #expect(action(.character("")) == .passThrough)
    }

    @Test(arguments: [KeyInput.Key.rightArrow, .space, .home, .escape, .returnKey, .character("f"), .character("0"), .character("+")])
    func commandControlAndOptionShortcutsBelongToTheMenus(key: KeyInput.Key) {
        #expect(action(key, menu: true, fullScreen: true) == .passThrough)
    }

    @Test func holdingTheArrowKeyKeepsFlipping() {
        // Only the toggles ignore repeats: flipping must keep going while the key is held.
        #expect(action(.rightArrow, repeating: true) == .run(.nextImage))
        #expect(action(.character("+"), repeating: true) == .run(.zoomIn))
    }
}
