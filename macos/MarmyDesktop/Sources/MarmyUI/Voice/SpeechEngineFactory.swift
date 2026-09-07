import Foundation

/// Picks the recogniser this Mac should use.
///
/// The long-form engine is the right one for dictation that runs for minutes and
/// is what macOS 26 offers; older systems get the short-utterance recogniser
/// with rollover, which keeps what it has heard and says so when it is cut off.
public enum SpeechEngineFactory {
    @MainActor
    public static func makeEngine(locale: Locale = Locale.current) -> any SpeechEngine {
        if #available(macOS 26.0, *) {
            let engine = ModernSpeechEngine(locale: locale)
            // Capabilities are read in the background; nothing is requested and
            // no audio is touched.
            Task { await engine.refreshCapabilities() }
            return engine
        }
        return LegacySpeechEngine(locale: locale)
    }
}
