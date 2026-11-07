import Foundation

/// Something the user can ask a viewer window to do from the keyboard or a menu.
public enum ViewerCommand: Equatable, Sendable {
    case nextImage, previousImage, firstImage, lastImage
    case zoomIn, zoomOut, actualPixels, zoomToFit
    case toggleFullScreen, exitFullScreen
}

/// A key press, reduced to what the key bindings look at. AppKit events are translated into this
/// at the edge, so the rules below can be tested without any UI.
public struct KeyInput: Equatable, Sendable {
    public enum Key: Equatable, Sendable {
        case rightArrow, leftArrow, upArrow, downArrow
        case pageUp, pageDown, home, end
        case space, delete, escape, returnKey
        /// A printable key, lower-cased.
        case character(String)
    }

    public var key: Key
    /// ⌘, ⌃ or ⌥ was held. Those shortcuts belong to the menus.
    public var hasMenuModifier: Bool
    /// The key is repeating because it is held down.
    public var isRepeat: Bool

    public init(_ key: Key, hasMenuModifier: Bool = false, isRepeat: Bool = false) {
        self.key = key
        self.hasMenuModifier = hasMenuModifier
        self.isRepeat = isRepeat
    }
}

/// What a key press leads to.
public enum KeyAction: Equatable, Sendable {
    /// Carry out the command.
    case run(ViewerCommand)
    /// The key is ours but does nothing this time (a held key repeating a toggle). It must not
    /// fall through to the system, which would beep.
    case swallow
    /// Not ours: leave it for the menus and the system.
    case passThrough
}

public enum KeyBindings {
    /// The command for a key press.
    ///
    /// - Parameter isFullScreen: Whether the window is full screen (Esc only leaves full screen).
    public static func action(for input: KeyInput, isFullScreen: Bool) -> KeyAction {
        guard !input.hasMenuModifier else { return .passThrough }

        switch input.key {
        case .rightArrow, .downArrow, .pageDown, .space:
            return .run(.nextImage)
        case .leftArrow, .upArrow, .pageUp, .delete:
            return .run(.previousImage)
        case .home:
            return .run(.firstImage)
        case .end:
            return .run(.lastImage)
        case .escape:
            return isFullScreen ? .run(.exitFullScreen) : .passThrough
        case .returnKey:
            // Holding the key must not flicker in and out of full screen.
            return input.isRepeat ? .swallow : .run(.toggleFullScreen)
        case .character(let text):
            switch text {
            case "+", "=": return .run(.zoomIn)
            case "-", "_": return .run(.zoomOut)
            // As in the View menu: ⌘0 and 0 are actual pixels, ⌘9 and 9 fit. "1" is a second
            // way to reach actual pixels.
            case "0", "1": return .run(.actualPixels)
            case "9": return .run(.zoomToFit)
            case "f": return input.isRepeat ? .swallow : .run(.toggleFullScreen)
            default: return .passThrough
            }
        }
    }
}
