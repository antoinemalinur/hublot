//
//  ConversationView.swift
//  Hublot
//
//  L'écran principal. Le document occupe toute la fenêtre ; le chrome flotte
//  au-dessus en capsules de verre, et la lueur du fond dit ce que la machine
//  est en train de faire.
//
//  Trois partis pris, tous au service de réponses longues : pas de bulles, un
//  rail de lumière à gauche qui porte l'état de chaque bloc, et tout ce qui
//  n'est pas de la prose replié par défaut sur une seule ligne.
//

import MarkdownUI
import PhotosUI
import SwiftUI

struct ConversationView: View {
    let sessionTitle: String
    let engine: Engine
    var plan: [PlanEntry] = []
    let turns: [Turn]
    /// Vide pour les écrans témoins, branché sur `ChatSession.send` en vrai.
    var onSend: (String, [Attachment]) -> Void = { _, _ in }
    /// `nil` masque le retour : sur un écran témoin il n'y a nulle part où aller.
    var onBack: (() -> Void)?
    /// Les réglages tels que l'agent les décrit. Vide sur un écran témoin.
    var configOptions: [ConfigOption] = []
    var status: SessionStatus?
    var contextPercent: Int?
    /// Toutes les mesures de contexte du fil, pour la marée. Vide sur un écran
    /// témoin, et vide tant que le relais n'a rien mesuré.
    var contextHistory: [ContextTide.Sample] = []
    var commands: [String] = []
    var onChoose: (ConfigOption, String) -> Void = { _, _ in }
    /// Le dernier signe de vie du relais, et l'instant où il est arrivé. C'est
    /// ce qui permet de dire « il exécute une commande depuis deux minutes »
    /// plutôt que de laisser un écran immobile parler à notre place.
    var activity: Activity?
    var activityAt: Date?
    /// Vrai pendant qu'un tour tourne : le bouton d'envoi devient un bouton
    /// d'arrêt, et c'est le seul moyen de reprendre la main avant la fin.
    var isWorking = false
    /// Demandes déjà confiées au fil, qui partiront après le tour courant.
    var queuedPromptCount = 0
    /// Vrai pendant qu'on se rebranche : le chrome le dit, plutôt que de laisser
    /// croire à une réponse qui met du temps à venir.
    var isReconnecting = false
    var onStop: () -> Void = {}
    /// Transcrit une dictée. `nil` désactive le micro — écrans témoins.
    var onDictate: ((Data) async -> String?)?

    #if DEBUG
        /// L'amorçage du composer pour les écrans témoins : une pièce jointe
        /// déjà choisie, une phase de dictée imposée. Les deux gestes qui y
        /// mènent sortent de l'app — sélecteur de photos et autorisation
        /// micro — et ne sont donc pas pilotables ; ce que l'app en fait
        /// ensuite, si.
        var debugAttachments: [Attachment] = []
        var debugDictationPhase: Dictation.Phase?
    #endif

    @State private var showingRadiography = false
    @State private var showingContextTide = false

    /// Vrai quand la dernière ligne est visible. C'est ce qui décide si le fil
    /// suit la réponse qui s'écrit, ou s'il laisse lire là où on est.
    @State private var isPinned = true

    /// La position du fil, pilotable.
    ///
    /// Elle remplace un `ScrollViewReader` qui visait une sentinelle par son
    /// identifiant — et c'est **la** raison pour laquelle le bouton de retour
    /// au direct ne faisait rien : dans un `LazyVStack`, la vue ciblée n'existe
    /// plus dès qu'on s'en est éloigné, et `scrollTo(id:)` échoue alors en
    /// silence. Viser un *bord* ne dépend d'aucune vue.
    @State private var position = ScrollPosition(edge: .bottom)

    private static let bottomAnchor = "hublot.fil.bas"

    private var machine: MachineState { .derive(from: turns) }

    var body: some View {
        ZStack {
            AmbientBackground(state: machine)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Hublot.unit * 2) {
                    // Regroupé à l'affichage seulement : le fil, lui, garde
                    // chaque appel — cf. `threadRows`.
                    ForEach(turns.threadRows()) { row in
                        ThreadRowView(row: row)
                    }
                    // Le témoin qui dit si on est en bas. Un point de hauteur,
                    // à l'intérieur de la pile : sa visibilité vaut mieux qu'un
                    // calcul d'offsets, parce qu'un fil plus court que l'écran
                    // est déjà « en bas » sans qu'aucune arithmétique ne le
                    // dise — et c'est le cas au début de chaque conversation.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchor)
                        .onScrollVisibilityChange(threshold: 0.01) { visible in
                            isPinned = visible
                        }
                }
                .padding(.horizontal, Hublot.unit * 2)
                .padding(.top, Hublot.unit * 4)
                .padding(.bottom, Hublot.unit * 12)
                .background(alignment: .topLeading) {
                    LightRail(state: machine)
                }
                // Le texte doit être sélectionnable et copiable partout :
                // c'est une demande explicite du périmètre v1.
                .textSelection(.enabled)
            }
            // On ouvre une conversation pour voir où elle en est, pas comment
            // elle a commencé. L'ancrage bas fait aussi suivre le flux pendant
            // que la réponse s'écrit.
            .defaultScrollAnchor(.bottom)
            .scrollPosition($position)
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: turns.count) { _, _ in
                guard isPinned else { return }
                withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                SessionChrome(
                    title: sessionTitle, engine: engine, machine: machine, plan: plan,
                    status: status, contextPercent: contextPercent,
                    activity: activity, activityAt: activityAt,
                    isReconnecting: isReconnecting, onBack: onBack,
                    onRadiography: { showingRadiography = true },
                    onContextTide: { showingContextTide = true }
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                composer
                // Dans la marge haute du composer, là où il n'y a que du
                // fondu : le bouton ne coûte donc aucune hauteur au fil et
                // n'en déplace pas le contenu en apparaissant.
                .overlay(alignment: .topTrailing) {
                    if !isPinned {
                        JumpToLatest {
                            withAnimation(.easeOut(duration: 0.25)) {
                                position.scrollTo(edge: .bottom)
                            }
                        }
                        .padding(.trailing, Hublot.unit * 2)
                        .padding(.top, Hublot.unit * 2)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }
                }
                .animation(.snappy(duration: 0.22), value: isPinned)
            }
            // `scrollEdgeEffectStyle` n'est pas utilisé : mesuré sur capture,
            // il ne s'applique qu'aux barres système, pas à un `safeAreaInset`
            // quelconque. Le fondu est donc fabriqué à la main — cf.
            // `EdgeScrim`.
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showingRadiography) {
            RadiographyView(
                projectName: sessionTitle, turns: turns, isLive: isWorking
            )
        }
        .fullScreenCover(isPresented: $showingContextTide) {
            ContextTideView(
                projectName: sessionTitle, history: contextHistory, isLive: isWorking
            )
        }
    }

    private var composer: Composer {
        var view = Composer(
            engine: engine,
            configOptions: configOptions,
            status: status,
            commands: commands,
            onChoose: onChoose,
            isWorking: isWorking,
            queuedPromptCount: queuedPromptCount,
            onStop: onStop,
            onDictate: onDictate,
            onSend: onSend
        )
        #if DEBUG
            view.debugAttachments = debugAttachments
            view.debugDictationPhase = debugDictationPhase
        #endif
        return view
    }
}

/// Le retour au direct. Il n'apparaît que lorsqu'on a quitté le bas du fil —
/// sinon il annonce un voyage qu'on a déjà fait.
struct JumpToLatest: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Hublot.ember)
                .frame(width: 34, height: 34)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityIdentifier("jump-to-latest")
        .accessibilityLabel("Aller à la dernière réponse")
    }
}

// MARK: - Le rail

/// Une ligne de lumière qui court sur toute la hauteur de la conversation, à
/// l'aplomb des glyphes de gouttière.
///
/// Elle s'éteint vers le haut et brûle vers le bas : le passé s'efface, le
/// présent est chaud. C'est aussi elle qui donne au verre du composer quelque
/// chose à réfracter juste en dessous.
struct LightRail: View {
    let state: MachineState

    private var tint: Color {
        state == .failed ? Hublot.removed : Hublot.ember
    }

    private var intensity: Double {
        switch state {
        case .idle: 0.25
        case .thinking: 0.55
        case .working: 0.85
        case .failed: 0.7
        }
    }

    var body: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: tint.opacity(0), location: 0),
                        .init(color: tint.opacity(0.10 * intensity), location: 0.35),
                        .init(color: tint.opacity(intensity), location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .padding(.leading, Hublot.unit * 2 + Hublot.gutter / 2)
            .blur(radius: 0.4)
            .allowsHitTesting(false)
    }
}

// MARK: - Fondu sous le chrome

/// Un flou progressif derrière une capsule flottante.
///
/// Le document doit se dissoudre en approchant du chrome, sinon il défile en
/// clair derrière le verre et l'écran devient illisible par le bas. Un matériau
/// masqué par un dégradé donne exactement ça : net loin du bord, franchement
/// flou au contact.
///
/// C'est le seul endroit où un matériau est encore employé — comme *fond* sous
/// le verre, jamais comme le verre lui-même.
struct EdgeScrim: View {
    let edge: VerticalEdge

    /// Les deux bords n'ont pas le même travail. En haut le document est déjà
    /// dégagé par la marge : le fondu n'est qu'une assurance, et trop appuyé il
    /// dessinerait un bandeau. En bas le texte passe vraiment derrière le
    /// composer et doit disparaître.
    ///
    /// Le haut était réglé pour un document qui commence sous le chrome. Dès
    /// qu'une conversation est assez longue pour défiler, elle passe derrière —
    /// et à 0,5 le texte restait lisible sous la capsule, deux écritures
    /// superposées. Il doit s'éteindre là aussi.
    private var opacity: Double { edge == .bottom ? 0.82 : 0.94 }

    /// La hauteur du fondu, en points fixes.
    ///
    /// Il était exprimé en fraction de la hauteur du fondu — donc il changeait
    /// de place dès que le chrome grandissait. Quand la barre de statut s'y est
    /// ajoutée, la zone pleine s'est retrouvée trop haut et le fil se lisait à
    /// hauteur des chiffres. En points, la zone pleine couvre le chrome quelle
    /// que soit sa taille, et le fondu s'éteint franchement en dessous.
    private var fade: CGFloat { 44 }

    /// Le fond lui-même. Un matériau seul *éclaircit* le noir : il dessinait un
    /// panneau gris visible en haut de l'écran. La teinte le ramène vers
    /// l'abysse, et le texte s'y éteint au lieu d'y blanchir.
    private var slab: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .overlay(Hublot.abyss.opacity(opacity))
    }

    var body: some View {
        slab
            // Le fondu déborde de la zone pleine — d'où le décalage : il vit
            // **sous** le chrome, pas dedans, et n'en réduit donc pas la
            // couverture.
            .overlay(alignment: edge == .bottom ? .top : .bottom) {
                slab
                    .mask {
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: edge == .bottom ? .bottom : .top,
                            endPoint: edge == .bottom ? .top : .bottom
                        )
                    }
                    .frame(height: fade)
                    .offset(y: edge == .bottom ? -fade : fade)
            }
            .allowsHitTesting(false)
    }
}

// MARK: - Chrome du haut

/// La session et le plan, en capsules de verre flottantes. Dans un même
/// `GlassEffectContainer` : quand elles sont proches, le verre fusionne au lieu
/// d'empiler deux plaques.
struct SessionChrome: View {
    let title: String
    let engine: Engine
    let machine: MachineState
    let plan: [PlanEntry]
    var status: SessionStatus?
    var contextPercent: Int?
    var activity: Activity?
    var activityAt: Date?
    var commands: [String] = []
    var isReconnecting = false
    var onBack: (() -> Void)?
    var onRadiography: (() -> Void)?
    /// Ouvre la marée de contexte. `nil` laisse la barre inerte — écrans
    /// témoins et aperçus, où il n'y a nulle part où aller.
    var onContextTide: (() -> Void)?

    @Namespace private var glass

    var body: some View {
        // La barre de statut est **dans** la pile, pas en surimpression décalée.
        // En surimpression elle débordait du chrome, et le fondu — dimensionné
        // sur le chrome — s'arrêtait au-dessus d'elle : le fil défilait en clair
        // derrière les chiffres.
        VStack(alignment: .leading, spacing: Hublot.unit * 0.75) {
            GlassEffectContainer(spacing: Hublot.unit * 2) {
                HStack(alignment: .top, spacing: Hublot.unit) {
                Button { onBack?() } label: {
                    HStack(spacing: Hublot.unit) {
                        Image(systemName: onBack == nil ? "circle.dotted" : "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Hublot.meta)
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(Hublot.prose)
                            .lineLimit(1)
                        EngineBadge(engine: engine, machine: machine)
                    }
                    .padding(.horizontal, Hublot.unit * 1.75)
                    .padding(.vertical, Hublot.unit * 1.25)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(onBack == nil)
                .accessibilityIdentifier("conversation-back")
                .glassEffect(.regular.interactive(), in: .capsule)
                .glassEffectID("session", in: glass)

                if !plan.isEmpty {
                    PlanCapsule(entries: plan)
                        .glassEffectID("plan", in: glass)
                }

                if let onRadiography {
                    Button(action: onRadiography) {
                        Image(systemName: "scope")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Hublot.ember)
                            .frame(width: 34, height: 34)
                            .contentShape(.circle)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .glassEffectID("radiography", in: glass)
                    .accessibilityLabel("Ouvrir la radiographie du projet")
                }
                // Sans ce ressort, la rangée se réduit à la largeur de ses
                // capsules : la session se centrait quand il n'y avait pas de
                // plan, et le fondu du haut, calé sur elle, dessinait un
                // rectangle clair aux bords nets.
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Hublot.unit * 2)
                .padding(.top, Hublot.unit)
            }

            // Hors du conteneur de verre : à l'intérieur, les deux capsules
            // fusionnaient en une forme molle avec une encoche — l'effet d'union
            // du Liquid Glass, spectaculaire entre deux boutons, laid entre un
            // titre et une ligne de chiffres.
            // Une liaison qui se refait doit se dire. Quand elle se taisait, une
            // conversation coupée en plein tour ressemblait exactement à une
            // conversation lente — et on attendait devant une réponse qui
            // n'arrivait plus.
            if isReconnecting {
                HStack(spacing: Hublot.unit * 0.75) {
                    Image(systemName: "bolt.horizontal.circle")
                        .font(.system(size: 10, weight: .medium))
                    Text("reprise de la liaison…")
                }
                .font(.hublotMetaEmphasis)
                .foregroundStyle(Hublot.ember)
                .padding(.horizontal, Hublot.unit * 1.25)
                .padding(.vertical, Hublot.unit * 0.5)
                .glassEffect(.regular, in: .capsule)
                .padding(.leading, Hublot.unit * 2.5)
                // Le glyphe et le texte comptent pour un : sans fusion, deux
                // éléments répondent au même nom — la leçon de `composer-queue`.
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("reconnecting-banner")
                .transition(.opacity.combined(with: .offset(y: -6)))
            } else {
                // Les deux mesures partagent une seule ligne : les plafonds à
                // gauche, le pouls à droite. Empilées, elles coûtaient une
                // ligne de chrome de plus — donc autant de moins pour le texte,
                // qui est ce qu'on vient lire.
                HStack(alignment: .center, spacing: Hublot.unit) {
                    if let bar = StatusBar.label(
                        status: status, contextPercent: contextPercent
                    ) {
                        // Toute la barre ouvre la marée, pas seulement la
                        // cellule « CTX » : les mesures sont fondues dans une
                        // seule chaîne — c'est ce qui permet au glyphe de
                        // remise à zéro d'avoir sa propre taille — et découper
                        // une zone sensible à l'intérieur d'un `AttributedString`
                        // demanderait de renoncer à cette typographie.
                        Button { onContextTide?() } label: {
                            // Pas de `foregroundStyle` ici : chaque cellule
                            // porte déjà la couleur de son seuil, et un style
                            // de vue l'écraserait.
                            Text(bar)
                                .lineLimit(1)
                                .fixedSize()
                                .padding(.horizontal, Hublot.unit * 1.25)
                                .padding(.vertical, Hublot.unit * 0.5)
                                .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .disabled(onContextTide == nil)
                        // Aucun libellé d'accessibilité ici : celui que SwiftUI
                        // dérive du texte porte les chiffres eux-mêmes, et
                        // c'est ce qu'un lecteur d'écran doit entendre.
                        .accessibilityIdentifier("status-bar")
                        .accessibilityHint("Ouvre la marée de contexte")
                        .glassEffect(.regular, in: .capsule)
                    }

                    Spacer(minLength: 0)

                    if let activity, let activityAt, activity.running {
                        ActivityCapsule(activity: activity, receivedAt: activityAt)
                            .accessibilityIdentifier("activity-capsule")
                            .transition(.opacity.combined(with: .offset(y: -6)))
                    }
                }
                .padding(.horizontal, Hublot.unit * 2.5)
            }
        }
        .padding(.bottom, Hublot.unit * 1.5)
        .animation(.snappy(duration: 0.25), value: isReconnecting)
        .animation(.snappy(duration: 0.25), value: activity?.running)
        .background { EdgeScrim(edge: .top).ignoresSafeArea() }
    }
}

/// Le pouls du tour en cours : ce que le moteur fait, depuis combien de temps,
/// et — surtout — depuis combien de temps il n'a plus rien dit.
///
/// C'est la pièce qui manquait le plus. Une commande de trois minutes et un
/// moteur mort donnaient exactement le même écran : rien qui bouge. On restait
/// devant sans savoir s'il fallait attendre ou tout relancer. Le relais, lui,
/// voit passer chaque événement du moteur ; il envoie donc son compte à rebours
/// du silence, et cette capsule le lit.
///
/// Elle se met à jour toute seule, sans horloge à entretenir : `TimelineView`
/// bat la seconde, et les chiffres sont recalculés à partir de l'instant de
/// réception du dernier battement. Un battement qui cesse d'arriver est donc
/// visible lui aussi — c'est la liaison qui ne porte plus rien.
struct ActivityCapsule: View {
    let activity: Activity
    let receivedAt: Date

    /// Au-delà, le relais lui-même s'est tu : il bat toutes les quatre
    /// secondes, donc vingt sans un mot ne sont pas une lenteur du moteur.
    private static let lostAfter: TimeInterval = 20
    /// Au-delà, le moteur n'a rien émis depuis assez longtemps pour qu'on ait
    /// le droit de s'inquiéter — sans pour autant affirmer qu'il est mort.
    private static let quietAfter: TimeInterval = 45

    var body: some View {
        TimelineView(.periodic(from: receivedAt, by: 1)) { context in
            let age = max(0, context.date.timeIntervalSince(receivedAt))
            let elapsed = activity.elapsed + age
            let quiet = activity.quiet + age
            let lost = age > Self.lostAfter

            HStack(spacing: Hublot.unit * 0.75) {
                PulseDot(tint: lost ? Hublot.removed : Hublot.ember, beating: !lost)
                // Seul le libellé se laisse rogner. Le compteur, lui, doit
                // rester lisible en entier : c'est ce qu'on regarde quand on se
                // demande depuis combien de temps on attend.
                Text(caption(quiet: quiet, lost: lost))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(lost ? Hublot.removed : Hublot.prose)
                Text(Self.clock(elapsed))
                    .foregroundStyle(Hublot.meta)
                    .monospacedDigit()
                    .fixedSize()
            }
            .font(.hublotMetaEmphasis)
            .padding(.horizontal, Hublot.unit * 1.25)
            .padding(.vertical, Hublot.unit * 0.5)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(caption(quiet: quiet, lost: lost)), depuis \(Self.clock(elapsed))"
            )
        }
    }

    /// Ce qu'on écrit, par ordre de gravité : la liaison muette d'abord, puis le
    /// moteur muet, puis simplement ce qu'il fait.
    ///
    /// Court, parce que la capsule partage sa ligne avec les plafonds. Le
    /// détail complet de l'outil est dans le fil, juste en dessous.
    private func caption(quiet: TimeInterval, lost: Bool) -> String {
        if lost { return "sans signal" }
        if activity.phase == .waiting { return "autorisation ?" }
        if quiet > Self.quietAfter { return "silence \(Self.clock(quiet))" }
        guard let detail else { return verb }
        return "\(verb) · \(detail)"
    }

    private var verb: String {
        switch activity.phase {
        case .starting: "démarrage"
        case .thinking: "réfléchit"
        case .writing: "écrit"
        case .tool: "exécute"
        case .waiting: "attend"
        case .done, .unknown: "en cours"
        }
    }

    /// Le libellé du relais, ramené à ce qui tient dans une capsule partagée.
    /// Une commande entière y déborderait et chasserait le compteur de l'écran.
    private var detail: String? {
        guard let label = activity.label?.trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty
        else { return nil }
        // La fin d'un chemin en dit plus que son début : « app.py » plutôt que
        // « /root/repos/office-… ».
        let flat = label.replacingOccurrences(of: "\n", with: " ")
        let leaf = flat.contains("/") && !flat.contains(" ")
            ? String(flat.split(separator: "/").last ?? "")
            : flat
        return leaf.count > 22 ? String(leaf.prefix(21)) + "…" : leaf
    }

    /// « 2:14 », « 1:04:09 ». Les secondes comptent : c'est à elles qu'on voit
    /// que quelque chose avance encore.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, (total % 3600) / 60, total % 60)
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}

/// Un point qui bat. Le même feu que le fond, réduit à six points de diamètre.
struct PulseDot: View {
    let tint: Color
    var beating = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: 6, height: 6)
            .shadow(color: tint.opacity(beating ? 0.9 : 0), radius: pulse ? 6 : 2)
            .opacity(beating && pulse ? 0.5 : 1)
            .animation(
                reduceMotion || !beating
                    ? nil
                    : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}

/// Le moteur qui répond, précédé du point vivant.
struct EngineBadge: View {
    let engine: Engine
    var machine: MachineState = .idle

    private var isLive: Bool { machine == .thinking || machine == .working }

    var body: some View {
        HStack(spacing: Hublot.unit * 0.75) {
            PulseDot(
                tint: machine == .failed ? Hublot.removed : Hublot.ember,
                beating: isLive
            )
            Text(engine.label)
                .font(.hublotMetaEmphasis)
                .foregroundStyle(Hublot.meta)
        }
    }
}

/// Le plan, réduit à ce qui tient dans une capsule : combien de jalons sont
/// franchis. Le détail se déplie au toucher.
struct PlanCapsule: View {
    let entries: [PlanEntry]
    @State private var isExpanded = false

    private var done: Int { entries.filter { $0.status == .completed }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Hublot.unit) {
            Button { withAnimation(.snappy(duration: 0.25)) { isExpanded.toggle() } } label: {
                HStack(spacing: Hublot.unit * 0.75) {
                    PlanRing(fraction: Double(done) / Double(entries.count))
                        .frame(width: 13, height: 13)
                    Text("\(done)/\(entries.count)")
                        .font(.hublotMetaEmphasis)
                        .foregroundStyle(Hublot.meta)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Pas de libellé écrit à la main : celui que SwiftUI dérive porte le
            // compteur lui-même — « 2/4 » — et c'est la seule valeur calculée
            // que cette capsule affiche.
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("plan-capsule")
            .accessibilityHint(isExpanded ? "Replier le plan" : "Déplier le plan")

            if isExpanded {
                VStack(alignment: .leading, spacing: Hublot.unit * 0.75) {
                    ForEach(entries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: Hublot.unit) {
                            Image(systemName: glyph(entry.status))
                                .font(.system(size: 9))
                                .foregroundStyle(
                                    entry.status == .completed ? Hublot.ember : Hublot.meta
                                )
                                .frame(width: 11)
                            Text(entry.content)
                                .font(.system(size: 12))
                                .foregroundStyle(
                                    entry.status == .completed ? Hublot.meta : Hublot.prose
                                )
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .frame(maxWidth: 240, alignment: .leading)
            }
        }
        .padding(.horizontal, Hublot.unit * 1.5)
        .padding(.vertical, Hublot.unit * 1.25)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private func glyph(_ status: PlanEntry.Status) -> String {
        switch status {
        case .pending: "circle"
        case .inProgress: "circle.lefthalf.filled"
        case .completed: "checkmark"
        }
    }
}

/// Un anneau plutôt qu'une barre : il tient dans la hauteur d'une capitale et
/// se lit d'un coup d'œil.
struct PlanRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().strokeBorder(Hublot.meta.opacity(0.3), lineWidth: 1.5)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction)))
                .stroke(Hublot.ember, style: .init(lineWidth: 1.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Composer

struct Composer: View {
    let engine: Engine
    var configOptions: [ConfigOption] = []
    var status: SessionStatus?
    var commands: [String] = []
    var onChoose: (ConfigOption, String) -> Void = { _, _ in }
    var isWorking = false
    var queuedPromptCount = 0
    var onStop: () -> Void = {}
    var onDictate: ((Data) async -> String?)?
    let onSend: (String, [Attachment]) -> Void

    #if DEBUG
        var debugAttachments: [Attachment] = []
        var debugDictationPhase: Dictation.Phase?
    #endif

    @State private var draft = ""
    @State private var dictation = Dictation()
    /// Les images jointes à la demande en cours d'écriture.
    @State private var attachments: [Attachment] = []
    /// La sélection brute du sélecteur système, vidée dès qu'elle est lue.
    @State private var picked: [PhotosPickerItem] = []
    @State private var isImporting = false

    /// Vrai dès qu'il y a quelque chose à envoyer — une image seule suffit.
    private var hasSomethingToSend: Bool { !draft.isEmpty || !attachments.isEmpty }

    /// Ce que le bouton fait, dans l'ordre de priorité : arrêter un
    /// enregistrement, envoyer ce qui est écrit, arrêter un tour, dicter.
    ///
    /// L'envoi passe avant l'arrêt lorsque le champ est rempli : pendant un
    /// tour, il met ainsi le message en file. Un bouton d'arrêt séparé reste
    /// alors visible juste à côté.
    private func act() {
        if dictation.phase == .recording {
            Task {
                // `stop()` attend que le fichier soit clos avant de le rendre :
                // le prendre sans attendre donnait un enregistrement amputé de
                // sa fin, et donc une transcription tronquée.
                guard let audio = await dictation.stop() else { return }
                let text = await onDictate?(audio)
                if let text, !text.isEmpty {
                    // On ajoute à ce qui est déjà là plutôt que de l'écraser :
                    // dicter par bouts est le mode d'emploi naturel.
                    draft = draft.isEmpty ? text : draft + " " + text
                    dictation.settle()
                } else {
                    dictation.settle(text == nil ? "Transcription indisponible." : nil)
                }
            }
            return
        }
        if hasSomethingToSend {
            // Le champ et le bouton possèdent le même état. Quand le brouillon
            // vivait dans ``ConversationView``, le TextField focalisé pouvait
            // réappliquer sa valeur d'édition après que la vue parente l'avait
            // vidé : la demande partait, mais le texte restait affiché.
            let text = draft
            let images = attachments
            // Envoyer signifie passer de l'écriture à la lecture. Libérer le
            // focus ferme immédiatement le clavier et rend sa hauteur au fil
            // pendant que la réponse commence à arriver.
            isWriting = false
            draft = ""
            attachments = []
            onSend(text, images)
            return
        }
        if isWorking { onStop(); return }
        Task { await dictation.start() }
    }

    /// Charge ce que le sélecteur a rendu. Une image illisible est ignorée sans
    /// bruit : c'est un cas de photothèque, pas une faute de l'utilisateur.
    private func absorb(_ items: [PhotosPickerItem]) async {
        isImporting = true
        defer { isImporting = false }
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self),
                let attachment = await Attachment.make(from: data)
            else { continue }
            withAnimation(.snappy(duration: 0.25)) { attachments.append(attachment) }
        }
        picked = []
    }

    private var glyph: String {
        if dictation.phase == .recording { "stop.fill" }
        else if hasSomethingToSend { "arrow.up" }
        else if isWorking { "stop.fill" }
        else { "mic.fill" }
    }

    private var glyphSize: CGFloat {
        glyph == "arrow.up" ? 15 : 13
    }

    private var actionLabel: String {
        if dictation.phase == .recording { return "Arrêter la dictée" }
        if hasSomethingToSend {
            return isWorking ? "Mettre le message en attente" : "Envoyer le message"
        }
        return isWorking ? "Arrêter la réponse" : "Démarrer la dictée"
    }

    /// L'invite dit ce qui bloque quand quelque chose bloque : un micro refusé
    /// se règle dans les Réglages, et rien dans l'app ne peut le deviner.
    private var placeholder: String {
        switch dictation.phase {
        case .refused: "Micro refusé — Réglages ▸ Hublot"
        case .failed(let reason): reason
        case .transcribing: "Transcription…"
        default: "Message…"
        }
    }

    /// La palette s'ouvre dès que la saisie commence par « / » et se ferme au
    /// premier espace : au-delà, ce n'est plus un nom de commande mais ses
    /// arguments.
    private var matches: [String] {
        guard draft.hasPrefix("/"), !draft.dropFirst().contains(" ") else { return [] }
        let typed = draft.dropFirst().lowercased()
        let found = typed.isEmpty
            ? commands
            : commands.filter { $0.lowercased().hasPrefix(typed) }
        return Array(found.prefix(40))
    }

    @Namespace private var glass
    @FocusState private var isWriting: Bool

    var body: some View {
        // `PhotosPicker` traite son label comme une closure `Sendable`.
        // Capturer une couleur déjà résolue évite d'y relire l'état SwiftUI
        // isolé au MainActor (warning qui n'apparaissait qu'en Release).
        let pickerTint = attachments.isEmpty ? Hublot.meta : Hublot.ember

        return GlassEffectContainer(spacing: Hublot.unit * 1.5) {
            VStack(alignment: .leading, spacing: Hublot.unit * 1.25) {
                if queuedPromptCount > 0 {
                    Label(
                        queuedPromptCount == 1
                            ? "1 message en attente"
                            : "\(queuedPromptCount) messages en attente",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Hublot.ember)
                    .padding(.horizontal, Hublot.unit * 1.5)
                    // Un `Label` expose son icône et son texte séparément : les
                    // deux héritaient de l'identifiant, VoiceOver énonçait la
                    // file en deux temps et toute recherche par identifiant en
                    // trouvait deux. Le compteur est une seule information.
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("composer-queue")
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }

                // Les réglages s'effacent pendant qu'on écrit : au moment de
                // formuler une demande, le choix du modèle n'est plus la
                // question.
                if !isWriting {
                    // Une pilule par réglage annoncé par l'agent, dans son
                    // ordre. L'app n'en connaît ni le nom ni les valeurs :
                    // ajouter un réglage côté serveur suffit à le faire
                    // apparaître ici.
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Hublot.unit) {
                            ForEach(configOptions) { option in
                                PillMenu(
                                    option: option,
                                    displayLabel: liveLabel(for: option)
                                ) { onChoose(option, $0) }
                                    // Modèle, effort et moteur ne peuvent agir
                                    // qu'au prochain tour. Les laisser changer
                                    // pendant celui-ci donnait deux vérités à
                                    // l'écran : Claude en bas, Codex en haut.
                                    .disabled(isWorking && option.id != "permission")
                            }
                        }
                        .padding(.trailing, Hublot.unit * 2)
                    }
                    .accessibilityIdentifier("config-options")
                    // La rangée déborde dès que les libellés s'allongent —
                    // « Medium » au lieu de « Low » suffit. Sans ce fondu, la
                    // dernière pilule paraît coupée plutôt que suivie d'autres.
                    .trailingScrollFade()
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }

                // Ce qu'on s'apprête à montrer, au-dessus de ce qu'on écrit :
                // une pièce jointe qu'on ne voit pas est une pièce jointe qu'on
                // envoie par accident.
                if !attachments.isEmpty || isImporting {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Hublot.unit) {
                            ForEach(attachments) { attachment in
                                AttachmentChip(attachment: attachment) {
                                    withAnimation(.snappy(duration: 0.25)) {
                                        attachments.removeAll { $0.id == attachment.id }
                                    }
                                }
                            }
                            if isImporting {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(Hublot.ember)
                                    .frame(width: 62, height: 62)
                                    .glassEffect(
                                        .regular,
                                        in: .rect(cornerRadius: Hublot.radius, style: .continuous)
                                    )
                            }
                        }
                        .padding(.trailing, Hublot.unit * 2)
                        // Le halo du bouton de retrait déborde du cadre : sans
                        // cette marge il se fait couper par le défilement.
                        .padding(.top, Hublot.unit * 0.75)
                    }
                    .scrollClipDisabled()
                    .transition(.opacity.combined(with: .offset(y: 8)))
                }

                // Le bouton est un cercle de 34 pt centré dans la capsule ; la
                // saisie garde la même marge verticale de chaque côté. Aligné
                // en bas, il « tombait » dès que le texte passait sur deux
                // lignes.
                HStack(alignment: .center, spacing: Hublot.unit) {
                    // Pendant une dictée, la zone de saisie cède la place à ce
                    // qui se passe vraiment : un point rouge et un compteur.
                    // Laisser « Message… » pendant qu'on parle donnerait à
                    // croire que rien n'écoute.
                    if dictation.phase == .recording {
                        HStack(spacing: Hublot.unit) {
                            Circle()
                                .fill(Hublot.removed)
                                .frame(width: 7, height: 7)
                                .shadow(color: Hublot.removed.opacity(0.8), radius: 5)
                            Text("\(dictation.caption) · \(dictation.listening)")
                                .font(.system(size: 16))
                                .foregroundStyle(Hublot.prose)
                                .contentTransition(.numericText())
                            Spacer(minLength: 0)
                        }
                        .padding(.leading, Hublot.unit * 2)
                        .frame(minHeight: 34)
                    } else {
                        // Le trombone est à gauche, dans la capsule : joindre
                        // une image appartient à la saisie, pas au chrome. Il
                        // s'efface pendant une dictée — on ne choisit pas une
                        // photo en parlant.
                        PhotosPicker(
                            selection: $picked, maxSelectionCount: 4,
                            matching: .images, photoLibrary: .shared()
                        ) {
                            Image(systemName: "photo.on.rectangle.angled")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(pickerTint)
                                .frame(width: 32, height: 34)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Joindre une image")

                        TextField(placeholder, text: $draft, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(size: 16))
                            .foregroundStyle(Hublot.prose)
                            .focused($isWriting)
                            .accessibilityIdentifier("composer-input")
                            .lineLimit(1...6)
                    }

                    // Tant qu'il n'y a rien à envoyer, le bouton garde son
                    // office historique : arrêter le tour. Dès qu'un brouillon
                    // existe, l'arrêt reste distinct afin que l'autre bouton
                    // puisse mettre le nouveau message en file.
                    if isWorking && hasSomethingToSend {
                        Button(action: onStop) {
                            Image(systemName: "stop.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("composer-stop")
                        .accessibilityLabel("Arrêter la réponse")
                        .tint(Hublot.removed)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    }

                    Button(action: act) {
                        Group {
                            if dictation.phase == .transcribing {
                                ProgressView().controlSize(.small).tint(Hublot.abyss)
                            } else {
                                Image(systemName: glyph)
                                    .font(.system(size: glyphSize, weight: .semibold))
                                    .contentTransition(.symbolEffect(.replace))
                            }
                        }
                        .frame(width: 34, height: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityIdentifier("composer-action")
                    .accessibilityLabel(actionLabel)
                    .tint(dictation.phase == .recording ? Hublot.removed : Hublot.ember)
                    .disabled(dictation.phase == .transcribing)
                    .animation(.snappy(duration: 0.2), value: isWorking)
                    .animation(.snappy(duration: 0.2), value: dictation.phase)
                }
                .padding(Hublot.unit * 0.75)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 26, style: .continuous))
                .glassEffectID("input", in: glass)
            }
            .padding(.horizontal, Hublot.unit * 2)
            .padding(.top, Hublot.unit * 7)
            .padding(.bottom, Hublot.unit)
        }
        .background { EdgeScrim(edge: .bottom).ignoresSafeArea() }
        .animation(.snappy(duration: 0.28), value: isWriting)
        .animation(.snappy(duration: 0.2), value: hasSomethingToSend)
        .animation(.snappy(duration: 0.2), value: queuedPromptCount)
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await absorb(items) }
        }
        #if DEBUG
            // L'amorçage des écrans témoins. Il s'applique à l'apparition et
            // pas à la construction : `attachments` et `dictation` sont des
            // états de cette vue, et un `@State` ne se sème pas depuis une
            // propriété de la structure qui le porte.
            .onAppear {
                if !debugAttachments.isEmpty { attachments = debugAttachments }
                if let debugDictationPhase {
                    dictation = Dictation(debugPhase: debugDictationPhase)
                }
            }
        #endif
    }

    /// Pendant un tour, les descripteurs de réglages disent encore ce qui est
    /// configuré pour le prochain départ. La rangée, elle, est lue comme l'état
    /// présent. Si Claude est épinglé mais indisponible, Codex assure l'intérim :
    /// montrer « Claude · Opus » sous sa jauge Codex reproduit exactement la
    /// contradiction signalée. Le statut vivant gagne jusqu'à la fin du tour.
    private func liveLabel(for option: ConfigOption) -> String? {
        guard isWorking else { return nil }
        switch option.id {
        // Le moteur en vol se nomme comme l'option le nomme au repos : « Codex »
        // et non son `rawValue`. Sans ce détour, la pastille changeait de casse
        // au départ du tour et revenait à « Codex » à son terme.
        case "engine": return option.name(for: engine.rawValue)
        case "model": return status?.model
        case "effort": return status?.effort?.capitalized
        default: return nil
        }
    }
}

/// Une image jointe, dans le composer : la vignette, son poids, et de quoi la
/// retirer.
///
/// Le poids est affiché parce qu'il se paie — une capture d'écran part depuis un
/// réseau mobile, et savoir avant d'envoyer vaut mieux que le découvrir après.
struct AttachmentChip: View {
    let attachment: Attachment
    let onRemove: () -> Void

    var body: some View {
        AttachedImage(data: attachment.jpeg, side: 62)
            .overlay(alignment: .bottom) {
                Text(attachment.size)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(Hublot.prose)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Hublot.abyss.opacity(0.75), in: .capsule)
                    .padding(3)
            }
            // La vignette et son poids sont une seule information : fusionnés
            // **avant** que la croix ne soit posée, sinon le bouton de retrait
            // se fond dans la vignette et cesse d'être touchable par son nom.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Image jointe, \(attachment.size)")
            .accessibilityIdentifier("attachment-chip")
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Hublot.abyss)
                        .frame(width: 18, height: 18)
                        .background(Hublot.ember, in: .circle)
                        .shadow(color: Hublot.ember.opacity(0.5), radius: 5)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .offset(x: 6, y: -6)
                .accessibilityIdentifier("attachment-remove")
                .accessibilityLabel("Retirer l'image")
            }
    }
}

/// Un sélecteur compact. Le libellé est la valeur courante : pas d'étiquette
/// séparée, l'espace en bas d'écran est trop cher.
struct PillMenu: View {
    let option: ConfigOption
    var displayLabel: String?
    let onSelect: (String) -> Void

    var body: some View {
        Menu {
            ForEach(option.options ?? []) { choice in
                Button {
                    onSelect(choice.value)
                } label: {
                    // La description vient de l'agent : « Opus 4.8 · Best for
                    // everyday, complex tasks ». Elle vaut mieux que tout ce
                    // qu'on pourrait écrire ici.
                    if let description = choice.description, !description.isEmpty {
                        Text(choice.name)
                        Text(description)
                    } else {
                        Text(choice.name)
                    }
                }
                .disabled(choice.value == option.currentValueString)
            }
        } label: {
            capsule(displayLabel ?? option.currentLabel)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .accessibilityIdentifier("config-\(option.id)")
    }

    private func capsule(_ text: String) -> some View {
        HStack(spacing: Hublot.unit * 0.5) {
            Text(text)
                .font(.hublotMetaEmphasis)
                .lineLimit(1)
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .semibold))
        }
        .foregroundStyle(Hublot.meta)
        .padding(.horizontal, Hublot.unit * 1.5)
        .padding(.vertical, Hublot.unit * 0.75)
        .contentShape(.capsule)
    }
}

// MARK: - Palette de commandes

/// Les commandes du moteur, filtrées à la frappe.
///
/// La liste vient de l'agent — Claude en annonce quarante-cinq, skills et
/// plugins compris — et n'est jamais écrite en dur : installer un plugin sur le
/// VPS suffit à le voir apparaître ici.
struct CommandPalette: View {
    let commands: [String]
    let onSelect: (String) -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(commands, id: \.self) { command in
                    Button { onSelect(command) } label: {
                        HStack(spacing: Hublot.unit) {
                            Text("/")
                                .font(.hublotMeta)
                                .foregroundStyle(Hublot.ember)
                            Text(command)
                                .font(.hublotMono)
                                .foregroundStyle(Hublot.prose)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, Hublot.unit * 1.75)
                        .padding(.vertical, Hublot.unit * 1.125)
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    if command != commands.last {
                        Divider().overlay(Hublot.rule).padding(.leading, Hublot.unit * 1.75)
                    }
                }
            }
        }
        // Bornée en hauteur : quarante-cinq commandes ne doivent pas recouvrir
        // la conversation qu'on est en train de lire.
        .frame(maxHeight: 240)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
        .transition(.opacity.combined(with: .offset(y: 10)))
    }
}

#if DEBUG
    extension ConversationView {
        /// Écran témoin des gestes critiques, lancé par les UI tests.
        ///
        /// Il reste entièrement local : une panne réseau ne peut ni le vider,
        /// ni changer ses libellés, ni rendre un test de mise en page aléatoire.
        static var screenTestDemo: ConversationView {
            demo(engine: .claude, status: SessionStatus(
                model: "Opus", effort: "high", engine: "claude",
                limits: [
                    "five_hour": .init(percent: 17, resetsAt: .now.addingTimeInterval(14_400))
                ]
            ))
        }

        /// Le même fil pendant un tour, avec une file pilotée par le témoin UI.
        static func workingScreenTestDemo(
            queuedPromptCount: Int,
            onSend: @escaping (String, [Attachment]) -> Void
        ) -> ConversationView {
            var view = screenTestDemo
            view.isWorking = true
            view.queuedPromptCount = queuedPromptCount
            view.onSend = onSend
            return view
        }

        /// Le même fil, mené par Codex, avec **les deux** fenêtres remplies.
        ///
        /// C'est le seul cas où la préférence se voit. Codex est plafonné par
        /// sa semaine — `account/rateLimits/read` ne lui rend d'ailleurs que
        /// celle-là sur ce compte — et demander le 5 h en premier affichait
        /// « 5H » sur une mesure hebdomadaire. Un abonnement qui exposerait
        /// soudain les deux aurait fait mentir la barre sans prévenir.
        static var codexQuotaDemo: ConversationView {
            demo(engine: .codex, status: SessionStatus(
                model: "GPT-5.6-Sol", effort: "max", engine: "codex",
                limits: [
                    "five_hour": .init(percent: 3, resetsAt: .now.addingTimeInterval(9_000)),
                    "seven_day": .init(percent: 64, resetsAt: .now.addingTimeInterval(172_800)),
                ]
            ))
        }

        /// Le cas de la capture du 10 août : Codex travaille encore et le
        /// sélecteur ne doit pas permettre d'afficher Claude comme moteur
        /// courant avant que le bouton d'arrêt ait rendu la main.
        static var activeEngineLockDemo: ConversationView {
            ConversationView(
                sessionTitle: "Vérifier le dépôt", engine: .codex,
                turns: [.assistant(.init(id: "live", markdown: "Codex travaille."))],
                configOptions: [
                    ConfigOption(
                        id: "engine", name: "Moteur", category: "mode", type: "select",
                        // Le prochain tour est épinglé sur Claude, mais le tour
                        // déjà en vol est Codex : c'est l'état de la capture.
                        currentValue: .string("claude"),
                        options: [
                            .init(value: "claude", name: "Claude", description: nil),
                            .init(value: "codex", name: "Codex", description: nil),
                        ]
                    ),
                    // L'exception du verrou : les permissions peuvent encore
                    // servir au tour en cours, à son prochain appel de commande.
                    ConfigOption(
                        id: "permission", name: "Permissions", category: "mode",
                        type: "select", currentValue: .string("ask"),
                        options: [
                            .init(value: "ask", name: "Demander", description: nil),
                            .init(value: "auto", name: "Tout autoriser", description: nil),
                        ]
                    ),
                ],
                status: SessionStatus(
                    model: "GPT-5.6-Sol", effort: "max", engine: "codex",
                    limits: [
                        "seven_day": .init(
                            percent: 36, resetsAt: .now.addingTimeInterval(118 * 60 + 27)
                        )
                    ]
                ),
                contextPercent: 14,
                activity: .init(
                    running: true, phase: .thinking, engine: "codex", elapsed: 89, quiet: 1
                ),
                activityAt: .now, isWorking: true
            )
        }

        private static func demo(engine: Engine, status: SessionStatus) -> ConversationView {
            var rows: [Turn] = []
            for index in 1...10 {
                rows.append(.user(.init(
                    id: "question-\(index)",
                    text: "Question historique \(index) — vérifier le comportement du fil."
                )))
                rows.append(.assistant(.init(
                    id: "answer-\(index)",
                    markdown: String(repeating: "Réponse de contrôle \(index). ", count: 8)
                )))
            }
            for index in 1...6 {
                rows.append(.toolCall(.init(
                    id: "edit-\(index)", title: index == 6 ? "styles.css" : "app.py",
                    kind: .edit, status: .completed
                )))
            }
            rows.append(.assistant(.init(
                id: "latest-answer",
                markdown: "FIN DU FIL — réponse la plus récente."
            )))

            let options = [
                ConfigOption(
                    id: "model", name: "Modèle", category: "model", type: "select",
                    currentValue: .string("opus"),
                    options: [.init(value: "opus", name: "Opus", description: nil)]
                ),
                ConfigOption(
                    id: "effort", name: "Effort", category: "thought_level", type: "select",
                    currentValue: .string("high"),
                    options: [.init(value: "high", name: "Élevé", description: nil)]
                ),
                ConfigOption(
                    id: "mode", name: "Mode", category: "mode", type: "select",
                    currentValue: .string("code"),
                    options: [.init(value: "code", name: "Code", description: nil)]
                ),
                ConfigOption(
                    id: "detail", name: "Détail", category: "style", type: "select",
                    currentValue: .string("concise"),
                    options: [.init(value: "concise", name: "Concis", description: nil)]
                ),
                ConfigOption(
                    // Le serveur publie ce réglage au singulier (`acp_server.py`),
                    // et c'est cet identifiant exact qui le laisse modifiable
                    // pendant un tour. Au pluriel, l'écran témoin décrivait une
                    // app qui n'existe pas.
                    id: "permission", name: "Permissions", category: "mode", type: "select",
                    currentValue: .string("allow_all"),
                    options: [
                        .init(value: "allow_all", name: "Tout autoriser", description: nil)
                    ]
                ),
            ]
            // La marée de ce fil témoin. La dernière mesure vaut exactement
            // 42 % — le même chiffre que `contextPercent` ci-dessous, sinon
            // l'écran et la barre qui l'ouvre se contrediraient. Le témoin
            // Codex porte la fenêtre globale publiée pour GPT-5.6 ; c'est le
            // parcours tactile de régression du dénominateur affiché.
            let contextSize = engine == .codex ? 1_050_000 : 200_000
            let readings = engine == .codex
                ? [35_700, 101_850, 173_775, 271_425, 358_050, 441_000]
                : [6_800, 19_400, 33_100, 51_700, 68_200, 84_000]
            let history = readings.enumerated().map { index, used in
                ContextTide.Sample(
                    id: "demo-ctx-\(index)", sequence: index,
                    used: used, size: contextSize,
                    at: Date(timeIntervalSinceReferenceDate: 800_000_000)
                        .addingTimeInterval(Double(index) * 120),
                    model: status.model, engine: status.engine
                )
            }

            return ConversationView(
                sessionTitle: "Résumer le dernier prompt", engine: engine,
                turns: rows, onBack: {}, configOptions: options,
                status: status, contextPercent: 42, contextHistory: history,
                activity: .init(
                    running: true, phase: .tool,
                    label: "/root/repos/office-chess/scripts/validation-complete.sh",
                    engine: status.engine, elapsed: 134, quiet: 1
                ),
                activityAt: .now, isWorking: false
            )
        }
    }
#endif
