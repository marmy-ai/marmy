import SwiftUI

/// Marmy Desktop's palette. Quiet paper-and-ink chrome so the topology and the
/// terminal are the only things that carry color.
enum Theme {
    static let paper = Color(light: 0xF6F7F9, dark: 0x15181C)
    static let surface = Color(light: 0xFFFFFF, dark: 0x1C2026)
    static let ink = Color(light: 0x202A36, dark: 0xE7ECF2)
    static let muted = Color(light: 0x687789, dark: 0x93A1B1)
    static let line = Color(light: 0xDDE3EA, dark: 0x2C333C)
    /// Managers.
    static let manager = Color(light: 0x356DB8, dark: 0x6FA3E6)
    /// Workers.
    static let worker = Color(light: 0x287D79, dark: 0x4FB3AE)
}

extension Color {
    /// Two deliberate values rather than one color dimmed by the system.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1)
    }
}
