#if DEBUG
    import Foundation

    /// Point d'entree unique pour les etats deterministes de XCTest UI.
    /// Les anciens drapeaux restent reconnus pendant leur migration.
    enum HublotUITestScenario: String {
        case connection
        case projects
        case projectsPromptAge = "projects-prompt-age"
        case projectsEmpty = "projects-empty"
        case projectsError = "projects-error"
        case sessions
        case sessionsEmpty = "sessions-empty"
        case sessionsError = "sessions-error"
        case sessionsInstructions = "sessions-instructions"
        case conversation
        case codexQuota = "codex-quota"
        case contextTide = "context-tide"
        case radiography
        case radiographyDense = "radiography-dense"

        static var current: HublotUITestScenario? {
            let arguments = ProcessInfo.processInfo.arguments
            if let index = arguments.firstIndex(of: "-HublotUITestScenario"),
                arguments.indices.contains(index + 1),
                let scenario = Self(rawValue: arguments[index + 1])
            {
                return scenario
            }

            let legacy: [(String, Self)] = [
                ("HublotRadiographyDense", .radiographyDense),
                ("HublotRadiographyDemo", .radiography),
                ("HublotContextTideDemo", .contextTide),
                ("HublotCodexQuotaDemo", .codexQuota),
                ("HublotConversationDemo", .conversation),
                ("HublotSessionsDemo", .sessions),
                ("HublotProjectsDemo", .projects),
            ]
            return legacy.first { UserDefaults.standard.bool(forKey: $0.0) }?.1
        }
    }
#endif

enum HublotMotion {
    static func isReduced(_ systemSetting: Bool) -> Bool {
        #if DEBUG
            return systemSetting
                || ProcessInfo.processInfo.arguments.contains("-HublotSnapshotMode")
        #else
            return systemSetting
        #endif
    }
}
