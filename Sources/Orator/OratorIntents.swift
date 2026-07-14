import AppIntents

struct SpeakTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak Text"

    @Parameter(title: "Text")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.shared?.speakText(text)
        return .result()
    }
}

struct SpeakClipboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Speak Clipboard"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.shared?.speakClipboard()
        return .result()
    }
}

struct StopSpeakingIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Speaking"

    @MainActor
    func perform() async throws -> some IntentResult {
        AppDelegate.shared?.stopSpeaking()
        return .result()
    }
}

struct OratorShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SpeakTextIntent(),
            phrases: ["Speak text with \(.applicationName)"],
            shortTitle: "Speak Text",
            systemImageName: "waveform"
        )
        AppShortcut(
            intent: SpeakClipboardIntent(),
            phrases: ["Speak clipboard with \(.applicationName)"],
            shortTitle: "Speak Clipboard",
            systemImageName: "doc.on.clipboard"
        )
        AppShortcut(
            intent: StopSpeakingIntent(),
            phrases: ["Stop \(.applicationName)"],
            shortTitle: "Stop Speaking",
            systemImageName: "stop.circle"
        )
    }
}
