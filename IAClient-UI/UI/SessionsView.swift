//
//  SessionsView.swift
//  Hublot
//
//  Les conversations d'un projet. Elles ne sont pas une invention de l'app :
//  ce sont les fichiers que Claude Code écrit lui-même, un par conversation.
//  D'où la promesse qui compte — reprendre trois semaines après, exactement là
//  où c'était resté, et pouvoir en tenir plusieurs de front sur le même dépôt.
//

import SwiftUI

struct SessionsView: View {
    @Bindable var model: AppModel
    let project: ProjectListResult.Project
    var initiallyShowsInstructions = false

    @State private var showingInstructions = false

    var body: some View {
        ZStack {
            AmbientBackground(state: .idle)

            // `swipeActions` est un comportement de rangée de `List`. Dans le
            // `ScrollView` précédent il n'existait aucun geste système à
            // accrocher : seule la pression longue pouvait supprimer. La liste
            // garde notre rendu en cartes mais récupère la physique et
            // l'accessibilité natives de Messages/Mail.
            List {
                if let failure = model.failure {
                    FailureNote(text: failure)
                        .sessionListRow()
                }

                // « Aucune conversation » ne doit paraître qu'une fois la liste
                // revenue : l'afficher pendant le chargement annonçait un vide
                // qui se démentait une demi-seconde plus tard.
                if model.sessions.isEmpty && !model.isLoadingSessions && !model.isBusy {
                    EmptyConversations()
                        .sessionListRow()
                }

                ForEach(Array(model.sessions.enumerated()), id: \.element.id) { index, session in
                    SessionRow(
                        session: session,
                        // La plus récente est celle qu'on reprend neuf fois
                        // sur dix : elle est marquée pour qu'on la trouve
                        // sans lire.
                        isLatest: index == 0,
                        running: model.running.first { $0.sessionId == session.sessionId }
                    ) {
                        Task { await model.resume(session) }
                    } onDelete: {
                        Task { await model.delete(session) }
                    }
                    .sessionListRow()
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await model.delete(session) }
                        } label: {
                            Label("Supprimer", systemImage: "trash")
                        }
                        .tint(Hublot.removed)
                    }
                }
            }
            .listStyle(.plain)
            .listRowSpacing(Hublot.unit * 0.25)
            .scrollContentBackground(.hidden)
            .contentMargins(.top, Hublot.unit * 2, for: .scrollContent)
            .contentMargins(.bottom, Hublot.unit * 4, for: .scrollContent)
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) { actions }
            .refreshable { await model.loadSessions(for: project) }
        }
        #if DEBUG
            // `-HublotShowInstructions 1` : ouvre la feuille au lancement, pour
            // qu'elle soit vérifiable en capture comme les autres écrans.
            .task {
                guard initiallyShowsInstructions
                    || UserDefaults.standard.bool(forKey: "HublotShowInstructions")
                else { return }
                try? await Task.sleep(for: .seconds(1))
                showingInstructions = model.instructions != nil
            }
        #endif
        .preferredColorScheme(.dark)
        // Même veille que sur l'écran des projets : elle dit quelles
        // conversations de ce dépôt travaillent en ce moment.
        .task { await model.watchRunning() }
        .sheet(isPresented: $showingInstructions) {
            if let document = model.instructions {
                InstructionsSheet(project: project.name, document: document)
            }
        }
    }

    private var header: some View {
        HStack(spacing: Hublot.unit) {
            Button { model.back() } label: {
                HStack(spacing: Hublot.unit * 0.75) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .semibold))
                    Text(project.name)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                }
                .foregroundStyle(Hublot.prose)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("sessions-back")

            if model.isReconnecting { ReconnectingBadge() }
            Spacer()
            InstructionsButton(document: model.instructions) {
                showingInstructions = true
            }
        }
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.vertical, Hublot.unit * 1.5)
        .padding(.bottom, Hublot.unit * 3)
        .background { EdgeScrim(edge: .top).ignoresSafeArea() }
    }

    private var actions: some View {
        ActionButton(title: "Nouvelle conversation", symbol: "plus.bubble") {
            Task { await model.startSession(in: project) }
        }
        .disabled(model.isBusy)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.top, Hublot.unit * 6)
        .padding(.bottom, Hublot.unit)
        .background { EdgeScrim(edge: .bottom).ignoresSafeArea() }
    }
}

private extension View {
    /// Retire l'habillage de `List` sans retirer son geste de balayage natif.
    func sessionListRow() -> some View {
        listRowInsets(EdgeInsets(
            top: Hublot.unit * 0.5,
            leading: Hublot.unit * 2,
            bottom: Hublot.unit * 0.5,
            trailing: Hublot.unit * 2
        ))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

struct SessionRow: View {
    let session: SessionListResult.Summary
    var isLatest = false
    /// Le tour qui travaille dans cette conversation, s'il y en a un.
    var running: RunningResult.Turn?
    let onOpen: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: Hublot.unit * 1.5) {
                Image(systemName: isLatest ? "bubble.left.fill" : "bubble.left")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(isLatest || running != nil ? Hublot.ember : Hublot.meta)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.displayTitle)
                        .font(.system(size: 15))
                        .foregroundStyle(Hublot.prose)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.hublotMeta)
                        .foregroundStyle(running == nil ? Hublot.meta : Hublot.ember)
                }
                Spacer(minLength: 0)
                // La conversation qui travaille se voit dans la liste, avant
                // de l'ouvrir : c'est là qu'on choisit laquelle reprendre.
                if running != nil { PulseDot(tint: Hublot.ember) }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Hublot.meta.opacity(0.6))
            }
            .padding(.horizontal, Hublot.unit * 1.75)
            .padding(.vertical, Hublot.unit * 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16, style: .continuous))
        .accessibilityLabel("\(session.displayTitle), \(subtitle)")
        .accessibilityIdentifier("session-row-\(session.sessionId)")
        .contextMenu {
            Button("Supprimer", systemImage: "trash", role: .destructive, action: onDelete)
        }
    }

    private var subtitle: String {
        // Ce qui se passe maintenant prime sur ce qui s'est passé : devant une
        // conversation en train de travailler, sa date de dernière modification
        // n'apprend rien.
        if let running {
            let what = running.label.map { " · \($0.split(separator: "/").last ?? "")" } ?? ""
            return "en cours\(what) · \(ActivityCapsule.clock(running.elapsed))"
        }
        var parts: [String] = []
        if let exchanges = session.exchanges, exchanges > 0 {
            parts.append("\(exchanges) échange\(exchanges > 1 ? "s" : "")")
        }
        if let updatedAt = session.updatedAt {
            parts.append(Relative.since(updatedAt))
        }
        if isLatest { parts.append("dernière") }
        return parts.joined(separator: " · ")
    }
}

/// Un écran vide est une invitation à agir, pas un constat d'échec.
struct EmptyConversations: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Hublot.unit) {
            Text("Aucune conversation")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Hublot.prose)
            Text("Ouvrez-en une pour commencer à travailler sur ce dépôt.")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
        }
        .padding(.vertical, Hublot.unit * 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
