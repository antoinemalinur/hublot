//
//  AmbientBackground.swift
//  Hublot
//
//  La signature de l'app.
//
//  Un hublot donne sur une salle des machines : ce qu'on voit à travers, c'est
//  la lueur de ce qui travaille. Ici la lueur n'est pas un décor — son
//  intensité et sa teinte *sont* l'état du moteur. On sait d'un coup d'œil, à
//  un mètre du téléphone, si l'agent réfléchit, exécute, ou s'est planté.
//
//  C'est aussi ce qui rend le Liquid Glass visible : du verre posé sur un noir
//  plat rend exactement comme un matériau opaque. Il lui faut une source de
//  lumière à réfracter.
//

import SwiftUI

// MARK: - État de la machine

/// Ce que le moteur est en train de faire, réduit à ce qui mérite d'être vu de
/// loin. Dérivé du fil, jamais réglé à la main.
enum MachineState: Equatable {
    /// Rien en cours : la braise est presque éteinte.
    case idle
    /// Le modèle écrit ou raisonne : la lueur respire.
    case thinking
    /// Un outil tourne : la lueur monte et se resserre.
    case working
    /// Quelque chose a échoué : la braise vire au rouge.
    case failed

    /// Les neuf couleurs du maillage, de haut en bas.
    ///
    /// Elles restent volontairement sombres : la prose passe par-dessus et doit
    /// rester le contraste le plus fort de l'écran. La lueur se lit dans les
    /// coins et sous le verre, pas au milieu du texte.
    var mesh: [Color] {
        switch self {
        case .idle:
            [
                .init(hex: 0x07080A), .init(hex: 0x08090C), .init(hex: 0x07080A),
                .init(hex: 0x0A0C11), .init(hex: 0x0D0E12), .init(hex: 0x08090C),
                .init(hex: 0x14100C), .init(hex: 0x1A140D), .init(hex: 0x0C0D10),
            ]
        case .thinking:
            [
                .init(hex: 0x07080A), .init(hex: 0x0A0B10), .init(hex: 0x08090C),
                .init(hex: 0x0B0C11), .init(hex: 0x100E12), .init(hex: 0x090A0E),
                .init(hex: 0x241A0E), .init(hex: 0x32240F), .init(hex: 0x120F0C),
            ]
        case .working:
            [
                .init(hex: 0x07080A), .init(hex: 0x0B0B10), .init(hex: 0x08090C),
                .init(hex: 0x0D0D12), .init(hex: 0x151116), .init(hex: 0x0A0B0F),
                .init(hex: 0x342207), .init(hex: 0x4A2E0C), .init(hex: 0x17120E),
            ]
        case .failed:
            [
                .init(hex: 0x08080A), .init(hex: 0x0C090C), .init(hex: 0x08080A),
                .init(hex: 0x0E0B0E), .init(hex: 0x160E12), .init(hex: 0x0A090C),
                .init(hex: 0x330F15), .init(hex: 0x431419), .init(hex: 0x150C0F),
            ]
        }
    }

    /// Durée d'un cycle de respiration. Plus la machine travaille, plus le
    /// souffle est court.
    var breath: Duration {
        switch self {
        case .idle: .seconds(14)
        case .thinking: .seconds(7)
        case .working: .seconds(4)
        case .failed: .seconds(11)
        }
    }

    /// Dérive l'état du fil. C'est la seule source : rien n'est réglé à la main.
    static func derive(from turns: [Turn]) -> MachineState {
        for turn in turns {
            switch turn {
            case .toolCall(let tool) where tool.status == .inProgress:
                return .working
            case .assistant(let message) where message.isStreaming:
                return .thinking
            case .thought(let thought) where thought.isStreaming:
                return .thinking
            case .permission(let request) where request.chosen == nil:
                // Une question en attente est un arrêt, pas un travail.
                return .idle
            default:
                continue
            }
        }

        // Rien ne travaille : c'est le **dernier** événement qui décide, pas le
        // pire de tout l'historique. Une commande ratée en cours de route puis
        // rattrapée laissait l'écran rouge pour le reste de la conversation,
        // alors que l'agent avait répondu et que tout allait bien. L'alarme doit
        // dire ce qui est, pas ce qui a été.
        for turn in turns.reversed() {
            switch turn {
            case .toolCall(let tool):
                return tool.status == .failed ? .failed : .idle
            case .assistant:
                return .idle
            default:
                continue
            }
        }
        return .idle
    }
}

// MARK: - Le fond

struct AmbientBackground: View {
    let state: MachineState

    @State private var phase: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        MeshGradient(
            width: 3,
            height: 3,
            points: points,
            colors: state.mesh,
            smoothsColors: true
        )
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 1.2), value: state)
        .onAppear(perform: startBreathing)
        .onChange(of: state) { _, _ in startBreathing() }
    }

    /// Le maillage respire en déplaçant seulement les points du bas : la lueur
    /// monte et redescend comme un tirage de four, sans que le haut de l'écran
    /// bouge sous le texte.
    private var points: [SIMD2<Float>] {
        let drift = Float(phase)
        return [
            .init(0.0, 0.0), .init(0.5, 0.0), .init(1.0, 0.0),
            .init(0.0, 0.5), .init(0.5 + drift * 0.10, 0.45 - drift * 0.06), .init(1.0, 0.5),
            .init(0.0, 1.0), .init(0.5 - drift * 0.14, 1.0), .init(1.0, 1.0),
        ]
    }

    private func startBreathing() {
        // Respecter « réduire les animations » : la lueur reste, elle ne bouge
        // plus. L'information d'état est portée par la couleur, pas par le
        // mouvement — on ne perd rien en la figeant.
        guard !reduceMotion else {
            phase = 0.5
            return
        }
        phase = 0
        withAnimation(
            .easeInOut(duration: state.breath.seconds).repeatForever(autoreverses: true)
        ) {
            phase = 1
        }
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
