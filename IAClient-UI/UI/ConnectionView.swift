//
//  ConnectionView.swift
//  Hublot
//
//  L'adresse du serveur et le jeton. Trois champs, et rien d'autre : pas de
//  compte, pas de service tiers, pas de télémétrie.
//

import SwiftUI

struct ConnectionView: View {
    @Bindable var model: AppModel
    @FocusState private var focus: Field?

    private enum Field { case url, token }

    var body: some View {
        ZStack {
            AmbientBackground(state: model.failure == nil ? .idle : .failed)

            ScrollView {
                VStack(alignment: .leading, spacing: Hublot.unit * 3) {
                    header

                    field(
                        "Serveur",
                        hint: "wss://… en production, ws:// sur le réseau local",
                        text: $model.serverURL,
                        focus: .url
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                    secureField
                    // Pas de champ « répertoire » ici : le dossier de travail
                    // est celui du projet qu'on choisit à l'écran suivant.
                    // Le demander avant de savoir sur quoi on va travailler
                    // n'avait aucun sens.

                    if let failure = model.failure {
                        Label(failure, systemImage: "bolt.horizontal.circle")
                            .font(.hublotMeta)
                            .foregroundStyle(Hublot.removed)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await model.connect() }
                    } label: {
                        HStack {
                            Spacer()
                            Text(model.isBusy ? "Connexion…" : "Se connecter")
                                .font(.system(size: 15, weight: .medium))
                            Spacer()
                        }
                        .padding(.vertical, Hublot.unit * 1.25)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Hublot.ember)
                    .disabled(!model.isConfigured || model.isBusy)
                }
                .padding(Hublot.unit * 3)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .preferredColorScheme(.dark)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Hublot.unit) {
            Circle()
                .strokeBorder(Hublot.ember, lineWidth: 2)
                .frame(width: 34, height: 34)
                .shadow(color: Hublot.ember.opacity(0.6), radius: 10)
            Text("Hublot")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Hublot.prose)
            Text("Le jeton reste dans le trousseau de cet appareil.")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
        }
        .padding(.bottom, Hublot.unit * 2)
    }

    private func field(
        _ label: String, hint: String, text: Binding<String>, focus field: Field
    ) -> some View {
        VStack(alignment: .leading, spacing: Hublot.unit * 0.75) {
            Text(label.uppercased())
                .font(.hublotMeta)
                .tracking(1.2)
                .foregroundStyle(Hublot.meta)
            TextField(hint, text: text)
                .textFieldStyle(.plain)
                .font(.hublotMono)
                .foregroundStyle(Hublot.prose)
                .focused($focus, equals: field)
                .padding(Hublot.unit * 1.5)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }

    private var secureField: some View {
        VStack(alignment: .leading, spacing: Hublot.unit * 0.75) {
            Text("JETON")
                .font(.hublotMeta)
                .tracking(1.2)
                .foregroundStyle(Hublot.meta)
            SecureField("Le porteur attendu par le serveur", text: $model.token)
                .textFieldStyle(.plain)
                .font(.hublotMono)
                .foregroundStyle(Hublot.prose)
                .focused($focus, equals: .token)
                .padding(Hublot.unit * 1.5)
                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14, style: .continuous))
        }
    }
}
