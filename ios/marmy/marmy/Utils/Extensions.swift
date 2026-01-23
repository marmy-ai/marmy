//
//  Extensions.swift
//  marmy
//

import SwiftUI

// MARK: - Date Extensions

extension Date {
    var relativeFormatted: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    var timeFormatted: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}

// MARK: - View Extensions

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    @ViewBuilder
    func `if`<Content: View>(_ condition: Bool, transform: (Self) -> Content) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

// MARK: - Color Extensions

extension Color {
    static let terminalBackground = Color(red: 0.1, green: 0.1, blue: 0.1)
    static let terminalText = Color(red: 0.9, green: 0.9, blue: 0.9)
    static let terminalGreen = Color(red: 0.2, green: 0.8, blue: 0.2)
    static let terminalRed = Color(red: 0.9, green: 0.3, blue: 0.3)
    static let terminalYellow = Color(red: 0.9, green: 0.9, blue: 0.3)
}

// MARK: - Font Extensions

extension Font {
    static func terminalFont(size: CGFloat) -> Font {
        .system(size: size, design: .monospaced)
    }

    static let terminalBody = Font.system(size: 14, design: .monospaced)
    static let terminalSmall = Font.system(size: 12, design: .monospaced)
}

// MARK: - String Extensions

extension String {
    var isBlank: Bool {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

// MARK: - UserDefaults Extension

extension UserDefaults {
    private enum Keys {
        static let serverHost = "serverHost"
        static let serverPort = "serverPort"
        static let ttsEnabled = "ttsEnabled"
        static let ttsSpeechRate = "ttsSpeechRate"
        static let ttsVoiceId = "ttsVoiceId"
        static let sttLanguage = "sttLanguage"
        static let autoReadEnabled = "autoReadEnabled"
    }

    var serverHost: String {
        get { string(forKey: Keys.serverHost) ?? "" }
        set { set(newValue, forKey: Keys.serverHost) }
    }

    var serverPort: Int {
        get {
            let port = integer(forKey: Keys.serverPort)
            return port > 0 ? port : 3000
        }
        set { set(newValue, forKey: Keys.serverPort) }
    }

    var ttsEnabled: Bool {
        get { bool(forKey: Keys.ttsEnabled) }
        set { set(newValue, forKey: Keys.ttsEnabled) }
    }

    var ttsSpeechRate: Float {
        get {
            let rate = float(forKey: Keys.ttsSpeechRate)
            return rate > 0 ? rate : 0.5
        }
        set { set(newValue, forKey: Keys.ttsSpeechRate) }
    }

    var ttsVoiceId: String? {
        get { string(forKey: Keys.ttsVoiceId) }
        set { set(newValue, forKey: Keys.ttsVoiceId) }
    }

    var sttLanguage: String {
        get { string(forKey: Keys.sttLanguage) ?? "en-US" }
        set { set(newValue, forKey: Keys.sttLanguage) }
    }

    var autoReadEnabled: Bool {
        get { bool(forKey: Keys.autoReadEnabled) }
        set { set(newValue, forKey: Keys.autoReadEnabled) }
    }
}
