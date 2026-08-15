//
//  ProjectsView.swift
//  Hublot
//
//  Le premier écran : sur quoi travailler. La liste est un vrai `ls` de
//  `/root/repos` relu à chaque affichage — un dépôt cloné à l'instant par un
//  autre processus y est.
//

import SwiftUI

struct ProjectsView: View {
    @Bindable var model: AppModel

    @State private var search = ""
    @State private var isCreating = false
    @State private var newName = ""
    @FocusState private var namingProject: Bool
    @FocusState private var isFiltering: Bool

    private var visible: [ProjectListResult.Project] {
        guard !search.isEmpty else { return model.projects }
        return model.projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        ZStack {
            AmbientBackground(state: .idle)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: Hublot.unit * 1.25) {
                    if let failure = model.failure {
                        FailureNote(text: failure)
                    }

                    if isCreating {
                        NewProjectRow(name: $newName, focus: $namingProject) {
                            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !name.isEmpty else { return }
                            isCreating = false
                            newName = ""
                            Task { await model.createProject(named: name) }
                        }
                    }

                    ForEach(visible) { project in
                        ProjectRow(
                            project: project,
                            running: model.runningTurns(in: project)
                        ) {
                            Task { await model.open(project) }
                        }
                    }

                    if visible.isEmpty && !search.isEmpty {
                        Text("Aucun dépôt ne correspond à « \(search) ».")
                            .font(.hublotMeta)
                            .foregroundStyle(Hublot.meta)
                            .padding(.vertical, Hublot.unit * 4)
                    }
                }
                .padding(.horizontal, Hublot.unit * 2)
                .padding(.top, Hublot.unit * 2)
                .padding(.bottom, Hublot.unit * 12)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isFiltering && !namingProject { actions }
            }
            .refreshable { await model.loadProjects() }
        }
        .preferredColorScheme(.dark)
        // Ce qui travaille pendant qu'on regarde ailleurs. La boucle s'arrête
        // avec l'écran : une conversation ouverte reçoit déjà son propre
        // battement, elle n'a rien à demander en plus.
        .task { await model.watchRunning() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Hublot.unit) {
            HStack(spacing: Hublot.unit) {
                Text("Projets")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Hublot.prose)
                if model.isReconnecting {
                    ReconnectingBadge()
                }
                Spacer()
                Button("Déconnecter") { Task { await model.disconnect() } }
                    .font(.hublotMetaEmphasis)
                    .buttonStyle(.glass)
                    .tint(Hublot.meta)
                    .accessibilityIdentifier("disconnect")
            }

            HStack(spacing: Hublot.unit) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(Hublot.meta)
                TextField("Filtrer", text: $search)
                    .textFieldStyle(.plain)
                    .font(.hublotMono)
                    .foregroundStyle(Hublot.prose)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFiltering)
                    .accessibilityIdentifier("project-filter")
            }
            .padding(.horizontal, Hublot.unit * 1.5)
            .padding(.vertical, Hublot.unit)
            .glassEffect(.regular.interactive(), in: .capsule)
        }
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.vertical, Hublot.unit * 1.5)
        .padding(.bottom, Hublot.unit * 3)
        .background { EdgeScrim(edge: .top).ignoresSafeArea() }
    }

    private var actions: some View {
        ActionButton(title: "Nouveau projet", symbol: "plus") {
            withAnimation(.snappy(duration: 0.25)) { isCreating = true }
            namingProject = true
        }
        .disabled(model.isBusy || isCreating)
        .accessibilityIdentifier("new-project")
        // La capsule épouse son texte et se centre, au lieu de barrer l'écran :
        // le verre n'existe que si on voit le fond de chaque côté.
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.top, Hublot.unit * 6)
        .padding(.bottom, Hublot.unit)
        .background { EdgeScrim(edge: .bottom).ignoresSafeArea() }
    }
}

// MARK: - Rangées

struct ProjectRow: View {
    let project: ProjectListResult.Project
    /// Les tours qui travaillent en ce moment sur ce dépôt.
    var running: [RunningResult.Turn] = []
    let action: () -> Void

    private var isWorking: Bool { !running.isEmpty }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Hublot.unit * 1.5) {
                Image(systemName: "folder")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(project.sessionCount > 0 ? Hublot.ember : Hublot.meta)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                        .font(.system(size: 15))
                        .foregroundStyle(Hublot.prose)
                    Text(subtitle)
                        .font(.hublotMeta)
                        .foregroundStyle(isWorking ? Hublot.ember : Hublot.meta)
                }
                Spacer(minLength: 0)
                // Le point vivant, à même la liste : c'est la seule chose qui
                // distingue un dépôt au repos d'un dépôt en plein travail, et
                // elle manquait — on ne l'apprenait qu'en ouvrant.
                if isWorking { PulseDot(tint: Hublot.ember) }
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
        .accessibilityLabel("\(project.name), \(subtitle)")
        // Le nom tel quel : le test connaît le dépôt par son scénario, et viser
        // une rangée par son libellé la ferait dépendre du sous-titre calculé
        // qu'elle sert justement à vérifier.
        .accessibilityIdentifier("project-row-\(project.name)")
    }

    /// Ce qu'on veut savoir avant d'ouvrir : ce qui tourne s'il y a quelque
    /// chose qui tourne, et sinon ce qu'il y a à reprendre.
    private var subtitle: String {
        if isWorking {
            let count = running.count
            let longest = running.map(\.elapsed).max() ?? 0
            return count > 1
                ? "\(count) conversations en cours · \(ActivityCapsule.clock(longest))"
                : "en cours · \(ActivityCapsule.clock(longest))"
        }
        let count = project.sessionCount
        let conversations = count == 0
            ? "aucune conversation"
            : "\(count) conversation\(count > 1 ? "s" : "")"
        guard let updatedAt = project.updatedAt, count > 0 else { return conversations }
        return "\(conversations) · \(Relative.since(updatedAt))"
    }
}

struct NewProjectRow: View {
    @Binding var name: String
    @FocusState.Binding var focus: Bool
    let onCreate: () -> Void

    var body: some View {
        HStack(spacing: Hublot.unit * 1.5) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 14, weight: .light))
                .foregroundStyle(Hublot.ember)
                .frame(width: 20)

            TextField("nom-du-projet", text: $name)
                .textFieldStyle(.plain)
                .font(.hublotMono)
                .foregroundStyle(Hublot.prose)
                .focused($focus)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit(onCreate)

            Button("Créer", action: onCreate)
                .font(.hublotMetaEmphasis)
                .buttonStyle(.glassProminent)
                .tint(Hublot.ember)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("create-project")
        }
        .padding(.horizontal, Hublot.unit * 1.75)
        .padding(.vertical, Hublot.unit * 1.25)
        .glassEffect(.regular, in: .rect(cornerRadius: 16, style: .continuous))
    }
}

/// Une opération peut échouer — dossier disparu, processus mort. Le taire
/// laissait l'utilisateur devant un écran muet.
struct FailureNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.hublotMeta)
            .foregroundStyle(Hublot.removed)
            .fixedSize(horizontal: false, vertical: true)
            .padding(Hublot.unit * 1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Hublot.removed.opacity(0.08), in: .rect(cornerRadius: Hublot.radius))
    }
}

/// La reprise est silencieuse mais pas invisible : on ne cache pas qu'on a
/// perdu la liaison, on évite juste de renvoyer vers un formulaire.
struct ReconnectingBadge: View {
    @State private var pulse = false

    var body: some View {
        HStack(spacing: Hublot.unit * 0.5) {
            Circle()
                .fill(Hublot.ember)
                .frame(width: 5, height: 5)
                .opacity(pulse ? 0.3 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            Text("reconnexion")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
        }
        .onAppear { pulse = true }
    }
}

/// « il y a 4 min ». Bornée au présent : l'horloge du serveur peut devancer
/// celle du téléphone de quelques secondes.
enum Relative {
    static func since(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "fr_FR")
        return formatter.localizedString(for: min(date, .now), relativeTo: .now)
    }
}
