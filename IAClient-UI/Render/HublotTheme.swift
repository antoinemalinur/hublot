//
//  HublotTheme.swift
//  Hublot
//
//  Direction « Gouttière ». Source unique de vérité pour les couleurs, la
//  typographie et la grille : aucune de ces valeurs ne doit être écrite en dur
//  ailleurs dans l'app.
//

import MarkdownUI
import SwiftUI

// MARK: - Jetons

enum Hublot {

    // MARK: Couleurs
    //
    // Sombre uniquement en v1. La grammaire visuelle tient en deux règles :
    // un seul accent (le laiton du cerclage), et le monospace réservé à ce qui
    // vient de la machine.

    /// Le noir le plus profond, tout au fond du maillage.
    static let abyss = Color(hex: 0x07080A)

    /// La braise : la source de lumière du fond, le halo du point vivant, le
    /// rail. Plus chaude et plus claire que l'accent typographique, parce
    /// qu'elle doit se lire à travers du verre.
    static let ember = Color(hex: 0xE8A33D)

    /// Les surfaces sont translucides : posées opaques, elles feraient des
    /// trous noirs dans la lueur et le verre n'aurait plus rien à réfracter
    /// autour d'elles.
    static let surface = Color(hex: 0x13_1519).opacity(0.72)
    static let rule = Color(hex: 0x2A2E36).opacity(0.8)
    static let prose = Color(hex: 0xEDEAE5)
    static let meta = Color(hex: 0x8A9099)

    /// L'accent typographique : liens, code en ligne, marqueurs. Volontairement
    /// plus sourd que `ember` — il se pose sur du texte, pas sur du verre.
    static let accent = Color(hex: 0xD9A441)

    /// Les seules couleurs sémantiques admises hors de l'accent.
    static let added = Color(hex: 0x4ADE80)
    static let removed = Color(hex: 0xF87171)
    static let failed = Color(hex: 0xF87171)

    // MARK: Grille

    /// Base du rythme vertical. Tout espacement en est un multiple.
    static let unit: CGFloat = 8

    /// Largeur de la gouttière d'état. Les glyphes y sont centrés, alignés sur
    /// la première ligne de base du bloc qu'ils annoncent.
    static let gutter: CGFloat = 28

    /// Rayon des surfaces élevées (blocs de code, cartes d'outil).
    static let radius: CGFloat = 10

    // MARK: Typographie
    //
    // SF Pro et SF Mono, rien d'autre : zéro dépendance, zéro poids ajouté, et
    // un rendu que le système garantit sur toutes les tailles Dynamic Type.

    static let proseSize: CGFloat = 17
    static let proseLine: CGFloat = 26
    static let monoSize: CGFloat = 13
    static let monoLine: CGFloat = 20
    static let metaSize: CGFloat = 12
}

extension Font {
    /// La prose — ce que le modèle dit.
    static let hublotProse = Font.system(size: Hublot.proseSize)

    /// Le code — ce que la machine produit.
    static let hublotMono = Font.system(size: Hublot.monoSize, design: .monospaced)

    /// Les métadonnées : chemins, durées, compteurs. Monospace pour que les
    /// chiffres s'alignent d'une ligne à l'autre.
    static let hublotMeta = Font.system(size: Hublot.metaSize, design: .monospaced)

    static let hublotMetaEmphasis = Font.system(
        size: Hublot.metaSize, weight: .medium, design: .monospaced
    )
}

extension Color {
    /// `0xRRGGBB`. Les jetons ci-dessus sont les seuls appelants légitimes.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

// MARK: - Thème MarkdownUI

extension Theme {

    /// Le thème appliqué à toute prose venant de l'agent.
    ///
    /// Les marges sont exprimées en points plutôt qu'en `em` : le rythme
    /// vertical doit rester celui de la grille de 8, indépendamment de la
    /// taille de police choisie par Dynamic Type.
    static let hublot = Theme()
        .text {
            ForegroundColor(Hublot.prose)
            FontSize(Hublot.proseSize)
        }
        .code {
            FontFamilyVariant(.monospaced)
            FontSize(.em(0.85))
            ForegroundColor(Hublot.accent)
        }
        .strong {
            FontWeight(.semibold)
        }
        .emphasis {
            FontStyle(.italic)
        }
        .strikethrough {
            StrikethroughStyle(.single)
            ForegroundColor(Hublot.meta)
        }
        .link {
            ForegroundColor(Hublot.accent)
            UnderlineStyle(.single)
        }
        .paragraph { configuration in
            configuration.label
                .relativeLineSpacing(.em(0.28))
                .markdownMargin(top: 0, bottom: Hublot.unit * 1.5)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(Hublot.proseSize * 1.35)
                }
                .markdownMargin(top: Hublot.unit * 3, bottom: Hublot.unit)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(Hublot.proseSize * 1.15)
                }
                .markdownMargin(top: Hublot.unit * 3, bottom: Hublot.unit)
        }
        .heading3 { configuration in
            // Au-delà du niveau 3, un titre dans une réponse de chat n'apporte
            // plus de hiérarchie lisible : on le traite comme une amorce.
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    ForegroundColor(Hublot.meta)
                }
                .markdownMargin(top: Hublot.unit * 2, bottom: Hublot.unit * 0.5)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Hublot.accent.opacity(0.5))
                    .frame(width: 2)
                configuration.label
                    .markdownTextStyle { ForegroundColor(Hublot.meta) }
                    .padding(.leading, Hublot.unit * 1.5)
                    // Sans ce ressort, la citation prend sa largeur idéale — donc
                    // celle d'une seule ligne — et sort de l'écran par la droite
                    // au lieu de passer à la ligne. Vu sur l'annonce de moteur,
                    // coupée net à « reprise d'une conversation que ».
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .markdownMargin(top: 0, bottom: Hublot.unit * 1.5)
        }
        .listItem { configuration in
            configuration.label
                .labelStyle(ListItemLabelStyle())
                .markdownMargin(top: Hublot.unit * 0.5)
        }
        .table { configuration in
            // Le critère d'acceptation du brief : un tableau GFM s'affiche en
            // tableau, avec des colonnes qui se dimensionnent seules — pas en
            // monospace simulé comme le fait render.py faute de mieux.
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .markdownTableBorderStyle(.init(color: Hublot.rule, strokeStyle: .init(lineWidth: 1)))
                .markdownTableBackgroundStyle(
                    .alternatingRows(.clear, Hublot.surface)
                )
                .markdownMargin(top: 0, bottom: Hublot.unit * 2)
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    FontSize(Hublot.monoSize + 1)
                    if configuration.row == 0 {
                        FontWeight(.semibold)
                        ForegroundColor(Hublot.prose)
                    } else {
                        ForegroundColor(Hublot.prose.opacity(0.9))
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, Hublot.unit)
                .padding(.horizontal, Hublot.unit * 1.5)
        }
        .thematicBreak {
            Divider()
                .overlay(Hublot.rule)
                .markdownMargin(top: Hublot.unit * 3, bottom: Hublot.unit * 3)
        }
        .codeBlock { configuration in
            CodeBlockView(language: configuration.language, content: configuration.content)
                .markdownMargin(top: 0, bottom: Hublot.unit * 2)
        }
}

// MARK: - Défilement horizontal

extension View {
    /// Un fondu sur le bord droit : c'est le seul signal qui dit qu'une ligne
    /// continue au-delà du cadre. Sur du contenu court la zone est déjà de la
    /// couleur de la surface, donc le fondu ne se voit pas — pas besoin de
    /// mesurer si le contenu déborde.
    func trailingScrollFade() -> some View {
        overlay(alignment: .trailing) {
            LinearGradient(
                colors: [Hublot.surface.opacity(0), Hublot.surface],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: Hublot.unit * 3)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Puces

/// MarkdownUI compose ses items de liste avec un `Label`. Le style par défaut
/// de SwiftUI y tronque le texte au lieu de le renvoyer à la ligne dès qu'on
/// imbrique un niveau — la bibliothèque contourne d'ailleurs le même problème
/// avec un `LabelStyle` maison, mais uniquement sur visionOS. On applique le
/// correctif partout : une puce imbriquée doit se lire en entier.
struct ListItemLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            configuration.icon
            configuration.title
        }
    }
}

// MARK: - Bloc de code

/// Un bloc de code avec sa langue et son bouton de copie.
///
/// Le défilement horizontal est interne au bloc : une ligne longue ne doit
/// jamais faire défiler la page entière — c'est précisément le défaut que
/// `render.py` ne pouvait pas corriger dans Telegram.
struct CodeBlockView: View {
    let language: String?
    let content: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            ScrollView(.horizontal, showsIndicators: false) {
                HighlightedCode(code: content, language: language)
                    .padding(.horizontal, Hublot.unit * 1.5)
                    .padding(.bottom, Hublot.unit * 1.5)
                    .textSelection(.enabled)
            }
            .trailingScrollFade()
        }
        .background(Hublot.surface)
        .clipShape(RoundedRectangle(cornerRadius: Hublot.radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Hublot.radius, style: .continuous)
                .strokeBorder(Hublot.rule, lineWidth: 1)
        )
    }

    private var header: some View {
        HStack {
            Text(language?.isEmpty == false ? language! : "texte")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
            Spacer()
            Button {
                UIPasteboard.general.string = content
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "square.on.square")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? Hublot.accent : Hublot.meta)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("copy-code")
            .accessibilityLabel("Copier le bloc de code")
        }
        .padding(.horizontal, Hublot.unit * 1.5)
        .padding(.vertical, Hublot.unit)
    }
}
