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
        case concurrentConversations = "concurrent-conversations"
        case conversationAge = "conversation-age"
        case engineSwitchQuota = "engine-switch-quota"
        case conversation
        case conversationWorking = "conversation-working"
        case codexQuota = "codex-quota"
        case activeEngineLock = "active-engine-lock"
        case contextTide = "context-tide"
        case radiography
        case radiographyDense = "radiography-dense"

        // Les états ajoutés par la couverture exhaustive. Chacun est atteint par
        // au moins un test : une fixture orpheline ferait baisser la couverture
        // de la cible sans rien prouver.
        case navigation
        case connectionBusy = "connection-busy"
        case connectionFailure = "connection-failure"
        case projectsVariants = "projects-variants"
        case projectsReload = "projects-reload"
        case sessionsVariants = "sessions-variants"
        case sessionsReload = "sessions-reload"
        /// Le même écran que `sessions-instructions`, mais avec un règlement
        /// assez long pour défiler. L'état court reste inchangé : c'est lui que
        /// la référence visuelle photographie.
        case sessionsInstructionsLong = "sessions-instructions-long"
        case threadBlocks = "thread-blocks"
        case threadGrowing = "thread-growing"
        case streamingPressure = "streaming-pressure"
        case projectLoading = "project-loading"
        case chromePlan = "chrome-plan"
        case chromeLost = "chrome-lost"
        case chromeQuiet = "chrome-quiet"
        case chromeReconnecting = "chrome-reconnecting"
        case chromeSilent = "chrome-silent"
        case composerAttachment = "composer-attachment"
        case composerRefusedMic = "composer-refused-mic"
        case contextTideEmpty = "context-tide-empty"
        case contextTideFinished = "context-tide-finished"
        case radiographyEmpty = "radiography-empty"
        case holdingLaunch = "holding-launch"
        case holdingReconnect = "holding-reconnect"

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

    /// Les durées qu'un test a le droit de raccourcir ou d'allonger.
    ///
    /// Certaines attentes de l'app sont trop longues pour un test — dix secondes
    /// avant l'issue de secours — et d'autres trop courtes pour qu'il ait le
    /// temps de se placer avant l'événement qu'il observe. Les valeurs par
    /// défaut, elles, ne changent jamais : c'est ce que l'app fait sur un
    /// téléphone.
    enum HublotLaunchDelay {
        static func seconds(_ name: String, fallback: TimeInterval) -> TimeInterval {
            let arguments = ProcessInfo.processInfo.arguments
            guard let index = arguments.firstIndex(of: name),
                arguments.indices.contains(index + 1),
                let value = TimeInterval(arguments[index + 1]), value >= 0
            else { return fallback }
            return value
        }
    }
#endif

/// « Réduire les animations », tel que l'app doit l'entendre.
///
/// En production, c'est le réglage du système et rien d'autre.
///
/// En développement, deux entrées s'y ajoutent, pour une raison mesurée le
/// 15 août 2026 sur iOS 26 : **l'argument de lancement
/// `-UIAccessibilityReduceMotionEnabled YES` ne change pas
/// `accessibilityReduceMotion`**. Un test qui le passe croit couper les
/// animations et ne coupe rien — la marée continuait de peindre à 1,6 % de
/// pixels par seconde, contre 0,07 % avec le vrai réglage posé par
/// `defaults write com.apple.Accessibility ReduceMotionEnabled`.
///
/// Ce réglage-là ne se pose que depuis l'extérieur du simulateur, donc hors de
/// portée d'un test hermétique. L'argument est donc lu ici, à la main : ce qui
/// est vérifié reste le chemin de code qui arrête la peinture, seule son entrée
/// change.
enum HublotMotion {
    static func isReduced(_ systemSetting: Bool) -> Bool {
        #if DEBUG
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("-HublotSnapshotMode") { return true }
            if let index = arguments.firstIndex(of: "-UIAccessibilityReduceMotionEnabled"),
                arguments.indices.contains(index + 1)
            {
                return systemSetting || arguments[index + 1] == "YES"
            }
            return systemSetting
        #else
            return systemSetting
        #endif
    }
}
