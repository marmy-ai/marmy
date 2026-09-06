import SwiftUI

/// Marmy Desktop's palette.
///
/// Quiet paper-and-ink chrome so the two things that matter — the topology and
/// the terminal — are what carry colour. Every value is stated for both
/// appearances rather than letting the system dim one of them.
public enum Theme {
    public static let paper = Color(light: 0xF6F7F9, dark: 0x15181C)
    public static let surface = Color(light: 0xFFFFFF, dark: 0x1C2026)
    public static let raised = Color(light: 0xFFFFFF, dark: 0x232830)
    public static let ink = Color(light: 0x202A36, dark: 0xE7ECF2)
    public static let muted = Color(light: 0x687789, dark: 0x93A1B1)
    public static let line = Color(light: 0xDDE3EA, dark: 0x2C333C)
    /// Managers.
    public static let manager = Color(light: 0x356DB8, dark: 0x6FA3E6)
    /// Workers.
    public static let worker = Color(light: 0x287D79, dark: 0x4FB3AE)
    public static let warning = Color(light: 0x9A6212, dark: 0xE0A94A)
    public static let danger = Color(light: 0xA33A31, dark: 0xE2796E)
    public static let terminalBackground = Color(light: 0xFBFBFC, dark: 0x121519)

    public static func accent(for kind: AgentKindTint) -> Color {
        switch kind {
        case .manager: return manager
        case .worker: return worker
        }
    }
}

public enum AgentKindTint {
    case manager
    case worker
}

extension Color {
    /// Two deliberate values rather than one colour dimmed by the system.
    public init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(marmyHex: isDark ? dark : light)
        })
    }
}

extension NSColor {
    public convenience init(marmyHex hex: UInt32) {
        self.init(
            srgbRed: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            alpha: 1)
    }
}
