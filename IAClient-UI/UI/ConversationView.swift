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
    var commands: [String] = []
    var onChoose: (ConfigOption, String) -> Void = { _, _ in }
    /// Vrai pendant qu'un tour tourne : le bouton d'envoi devient un bouton
    /// d'arrêt, et c'est le seul moyen de reprendre la main avant la fin.
    var isWorking = false
    /// Vrai pendant qu'on se rebranche : le chrome le dit, plutôt que de laisser
    /// croire à une réponse qui met du temps à venir.
    var isReconnecting = false
    var onStop: () -> Void = {}
    /// Transcrit une dictée. `nil` désactive le micro — écrans témoins.
    var onDictate: ((Data) async -> String?)?

    @State private var showingRadiography = false

    private var machine: MachineState { .derive(from: turns) }

    var body: some View {
        ZStack {
            AmbientBackground(state: machine)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Hublot.unit * 2) {
                    ForEach(turns) { turn in
                        TurnRow(turn: turn)
                    }
                }
                .padding(.horizontal, Hublot.unit * 2)
                .padding(.top, Hublot.unit * 4)
                .padding(.bottom, Hublot.unit * 12)
                .background(alignment: .topLeading) {
                    LightRail(state: machine)
                }
                // Le texte doit être sélectionnable et copiable partout : c'est
                // une demande explicite du périmètre v1.
                .textSelection(.enabled)
            }
            // On ouvre une conversation pour voir où elle en est, pas comment
            // elle a commencé. L'ancrage bas fait aussi suivre le flux pendant
            // que la réponse s'écrit, sans code de défilement à la main.
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .safeAreaInset(edge: .top, spacing: 0) {
                SessionChrome(
                    title: sessionTitle, engine: engine, machine: machine, plan: plan,
                    status: status, contextPercent: contextPercent,
                    isReconnecting: isReconnecting, onBack: onBack,
                    onRadiography: { showingRadiography = true }
                )
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Composer(
                    engine: engine,
                    configOptions: configOptions,
                    commands: commands,
                    onChoose: onChoose,
                    isWorking: isWorking,
                    onStop: onStop,
                    onDictate: onDictate,
                    onSend: onSend
                )
            }
            // `scrollEdgeEffectStyle` n'est pas utilisé : mesuré sur capture,
            // il ne s'applique qu'aux barres système, pas à un `safeAreaInset`
            // quelconque. Le fondu est donc fabriqué à la main — cf. `EdgeScrim`.
        }
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showingRadiography) {
            RadiographyView(projectName: sessionTitle, turns: turns)
        }
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
    var commands: [String] = []
    var isReconnecting = false
    var onBack: (() -> Void)?
    var onRadiography: (() -> Void)?

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
                .transition(.opacity.combined(with: .offset(y: -6)))
            } else if let bar = StatusBar.label(status: status, contextPercent: contextPercent) {
                Text(bar)
                    .foregroundStyle(Hublot.meta)
                    .lineLimit(1)
                    .padding(.horizontal, Hublot.unit * 1.25)
                    .padding(.vertical, Hublot.unit * 0.5)
                    .glassEffect(.regular, in: .capsule)
                    .padding(.leading, Hublot.unit * 2.5)
            }
        }
        .padding(.bottom, Hublot.unit * 1.5)
        .animation(.snappy(duration: 0.25), value: isReconnecting)
        .background { EdgeScrim(edge: .top).ignoresSafeArea() }
    }
}

/// Le point vivant. Il bat quand la machine travaille, et il a un halo — c'est
/// le même feu que celui du fond, en miniature.
struct EngineBadge: View {
    let engine: Engine
    var machine: MachineState = .idle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var isLive: Bool { machine == .thinking || machine == .working }
    private var tint: Color { machine == .failed ? Hublot.removed : Hublot.ember }

    var body: some View {
        HStack(spacing: Hublot.unit * 0.75) {
            Circle()
                .fill(tint)
                .frame(width: 6, height: 6)
                .shadow(color: tint.opacity(isLive ? 0.9 : 0), radius: pulse ? 6 : 2)
                .opacity(isLive && pulse ? 0.55 : 1)
                .animation(
                    reduceMotion || !isLive
                        ? nil
                        : .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: pulse
                )
            Text(engine.label)
                .font(.hublotMetaEmphasis)
                .foregroundStyle(Hublot.meta)
        }
        .onAppear { pulse = true }
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
    var commands: [String] = []
    var onChoose: (ConfigOption, String) -> Void = { _, _ in }
    var isWorking = false
    var onStop: () -> Void = {}
    var onDictate: ((Data) async -> String?)?
    let onSend: (String, [Attachment]) -> Void

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
    /// enregistrement, arrêter un tour, envoyer ce qui est écrit, dicter.
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
        if isWorking { onStop(); return }
        if hasSomethingToSend {
            // Le champ et le bouton possèdent le même état. Quand le brouillon
            // vivait dans ``ConversationView``, le TextField focalisé pouvait
            // réappliquer sa valeur d'édition après que la vue parente l'avait
            // vidé : la demande partait, mais le texte restait affiché.
            let text = draft
            let images = attachments
            draft = ""
            attachments = []
            onSend(text, images)
            return
        }
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
        else if isWorking { "stop.fill" }
        else if !hasSomethingToSend { "mic.fill" }
        else { "arrow.up" }
    }

    private var glyphSize: CGFloat {
        glyph == "arrow.up" ? 15 : 13
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
        GlassEffectContainer(spacing: Hublot.unit * 1.5) {
            VStack(alignment: .leading, spacing: Hublot.unit * 1.25) {
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
                                PillMenu(option: option) { onChoose(option, $0) }
                            }
                        }
                        .padding(.trailing, Hublot.unit * 2)
                    }
                    // La rangée déborde dès que les libellés s'allongent —
                    // « Medium » au lieu de « Low » suffit. Sans ce fondu, la
                    // dernière pilule paraît coupée plutôt que suivie d'autres.
                    .trailingScrollFade()
                    .scrollClipDisabled()
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
                                .foregroundStyle(
                                    attachments.isEmpty ? Hublot.meta : Hublot.ember
                                )
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
                            .lineLimit(1...6)
                    }

                    // Un seul bouton, quatre offices. Deux ou trois boutons
                    // côte à côte auraient demandé de viser ; là où il n'y en a
                    // qu'un, le geste est le même et c'est l'état qui décide de
                    // son sens.
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
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await absorb(items) }
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
                .accessibilityLabel("Retirer l'image")
            }
    }
}

/// Un sélecteur compact. Le libellé est la valeur courante : pas d'étiquette
/// séparée, l'espace en bas d'écran est trop cher.
struct PillMenu: View {
    let option: ConfigOption
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
            capsule(option.currentLabel)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
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
