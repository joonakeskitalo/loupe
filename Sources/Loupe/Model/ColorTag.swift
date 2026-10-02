import SwiftUI

/// A color label that can be attached to a file, mirroring Finder's color
/// tags. Like flagging, tags are an in-session annotation held by the
/// per-window `BrowserModel` keyed by item ID — they are not written to disk.
///
/// The raw value is a stable identifier (used only in-memory); the digit order
/// of the cases also defines the Ctrl+1…Ctrl+5 hotkey mapping (see
/// `allInHotkeyOrder`).
enum ColorTag: String, CaseIterable, Sendable {
    case red
    case blue
    case green
    case orange
    case purple

    /// Tags in the order their Ctrl+digit hotkeys are assigned: Ctrl+1 = red,
    /// Ctrl+2 = blue, Ctrl+3 = green, Ctrl+4 = orange, Ctrl+5 = purple.
    static let allInHotkeyOrder: [ColorTag] = [.red, .blue, .green, .orange, .purple]

    /// Human-readable name used in menus and accessibility labels.
    var displayName: String {
        switch self {
        case .red: return "Red"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        case .purple: return "Purple"
        }
    }

    /// The SwiftUI color used for the badge/chip fill, matching the flag
    /// feature's styling convention of a solid system color.
    var color: Color {
        switch self {
        case .red: return .red
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .purple: return .purple
        }
    }

    /// SF Symbol for the tag badge. A filled circle reads clearly as a color
    /// swatch at small badge sizes.
    var symbol: String { "circle.fill" }
}
