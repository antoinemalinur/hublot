//
//  InstructionsSheet.swift
//  Hublot
//
//  Le `CLAUDE.md` d'un dépôt, lu comme un document.
//
//  C'est le seul écran de l'app qui n'est pas une conversation, et il est
//  traité comme tel : pas de chrome flottant, pas de lueur qui respire, pas de
//  gouttière. Une feuille sombre, une colonne de texte, et le même thème
//  typographique que la prose de l'agent — parce que c'est exactement le même
//  travail de lecture.
//

import MarkdownUI
import SwiftUI

struct InstructionsSheet: View {
    let project: String
    let document: InstructionsResult.Document

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            // Un fond plat, volontairement : la lueur du fond sert à dire ce
            // que la machine fait. Ici elle ne fait rien, et un fond qui
            // respire sous un règlement à lire serait du bruit.
            Hublot.abyss.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Markdown(document.content)
                        .markdownTheme(.hublot)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, Hublot.unit * 3)
                .padding(.top, Hublot.unit * 2)
                .padding(.bottom, Hublot.unit * 8)
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
        }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
        .presentationBackground(Hublot.abyss)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Hublot.unit) {
            VStack(alignment: .leading, spacing: 2) {
                Text(document.path)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Hublot.prose)
                Text(subtitle)
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)
            }
            Spacer(minLength: 0)
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Hublot.meta)
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityIdentifier("close-instructions")
        }
        .padding(.horizontal, Hublot.unit * 3)
        .padding(.top, Hublot.unit * 2)
        .padding(.bottom, Hublot.unit * 2)
        .background {
            // Un simple dégradé plutôt qu'un matériau : le texte doit
            // disparaître sous l'en-tête sans que celui-ci s'éclaircisse.
            LinearGradient(
                colors: [Hublot.abyss, Hublot.abyss, Hublot.abyss.opacity(0)],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        }
    }

    private var subtitle: String {
        var parts = [project]
        if !document.size.isEmpty { parts.append(document.size) }
        if let updatedAt = document.updatedAt { parts.append(Relative.since(updatedAt)) }
        return parts.joined(separator: " · ")
    }
}

/// Le bouton qui l'ouvre. Discret par construction : il n'existe que si le
/// dépôt a bien un fichier d'instructions.
struct InstructionsButton: View {
    let document: InstructionsResult.Document?
    let action: () -> Void

    var body: some View {
        if document != nil {
            Button(action: action) {
                Image(systemName: "text.document")
                    .font(.system(size: 13, weight: .light))
                    .foregroundStyle(Hublot.meta)
                    .frame(width: 30, height: 30)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityIdentifier("instructions-button")
            .accessibilityLabel("Voir les instructions du dépôt")
        }
    }
}
