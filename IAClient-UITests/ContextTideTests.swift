//
//  ContextTideTests.swift
//  HublotTests
//

import Foundation
import SwiftUI
import Testing

@testable import IAClient_UI

@Suite("Marée de contexte")
struct ContextTideTests {

    /// Un échantillon, sans avoir à répéter les champs qui ne servent pas au
    /// test en cours.
    private func sample(
        _ index: Int, used: Int, size: Int = 200_000, at: Date? = nil,
        model: String? = "Opus 5", engine: String? = "claude"
    ) -> ContextTide.Sample {
        .init(
            id: "ctx-\(index)", sequence: index, used: used, size: size,
            at: at, model: model, engine: engine
        )
    }

    @Test("Une mesure unique ne fabrique pas une plage de slider vide")
    func singleSampleHasNoScrubberRange() throws {
        let tide = ContextTide(samples: [sample(0, used: 12_000)])
        #expect(tide.lastStep == 0)
        #expect(tide.scrubberRange == nil)

        let second = ContextTide(samples: [
            sample(0, used: 12_000), sample(1, used: 24_000),
        ])
        #expect(second.scrubberRange == 0.0...1.0)
    }

    @Test("Une mesure impossible est écartée du tracé, jamais ramenée à cent")
    func impossibleMeasurementIsExcluded() throws {
        // Le bug réel : le serveur envoyait le total des jetons d'un tour à la
        // place du contexte porté, ce qui donnait 1540 %. Le clamper à cent
        // ferait croire à un plafond touché — un mensonge différent, pas une
        // correction.
        let tide = ContextTide(samples: [
            sample(0, used: 84_000),
            sample(1, used: 900_000),
            sample(2, used: 96_000),
        ])

        #expect(tide.plottable.map(\.used) == [84_000, 96_000])
        #expect(tide.samples.count == 3)
        #expect(tide.snapshot().current?.percent == 48)
    }

    @Test("Une mesure sans fenêtre connue ne se trace pas")
    func unknownWindowIsNotPlotted() throws {
        // Codex n'annonce parfois aucune taille : `send_status` envoie alors
        // `used=0, size=0`. Zéro pour cent serait une mesure ; ce n'en est pas
        // une.
        let tide = ContextTide(samples: [
            sample(0, used: 0, size: 0),
            sample(1, used: 12_000, size: 0),
            sample(2, used: 0, size: 200_000),
            sample(3, used: 12_000, size: 200_000),
        ])

        #expect(tide.plottable.map(\.id) == ["ctx-3"])
        #expect(tide.scrubberRange == nil)
    }

    @Test("Le pourcentage suit la fenêtre du moment, pas celle du début")
    func windowChangeIsHonoured() throws {
        // Changer de modèle en cours de conversation change la fenêtre. Garder
        // la première taille en cache donnerait un tracé faux à partir de là.
        let tide = ContextTide(samples: [
            sample(0, used: 100_000, size: 200_000, model: "Opus 5"),
            sample(1, used: 100_000, size: 1_000_000, model: "Sonnet 5"),
        ])

        let plotted = tide.plottable
        #expect(plotted[0].percent == 50)
        #expect(plotted[1].percent == 10)
    }

    @Test("La chronologie s'arrête où on la fige, et se borne toute seule")
    func snapshotIsBounded() throws {
        let tide = ContextTide(samples: (0..<5).map {
            sample($0, used: (($0 + 1) * 20_000))
        })

        #expect(tide.snapshot(through: 2).plotted.count == 3)
        #expect(tide.snapshot(through: 2).current?.percent == 30)
        // Hors bornes des deux côtés : on ne veut ni index négatif ni
        // dépassement, la vue pouvant demander n'importe quoi pendant un geste.
        #expect(tide.snapshot(through: -4).plotted.count == 1)
        #expect(tide.snapshot(through: 99).plotted.count == 5)
        // `nil`, c'est le direct : la dernière mesure connue.
        #expect(tide.snapshot().current?.percent == 50)
    }

    @Test("Le sommet reste visible après une compaction")
    func peakSurvivesCompaction() throws {
        // Une compaction fait retomber le contexte. Le sommet franchi est un
        // fait de la conversation, pas un accident à effacer.
        let tide = ContextTide(samples: [
            sample(0, used: 60_000),
            sample(1, used: 184_000),
            sample(2, used: 24_000),
        ])

        let snapshot = tide.snapshot()
        #expect(snapshot.current?.percent == 12)
        #expect(snapshot.peak?.percent == 92)
    }

    @Test("Un fil sans aucune mesure donne un tracé vide, pas un tracé à zéro")
    func emptyHistoryStaysEmpty() throws {
        let tide = ContextTide(samples: [])
        #expect(tide.snapshot().isEmpty)
        #expect(tide.snapshot().current == nil)
        #expect(tide.scrubberRange == nil)
    }

    @Test("La vue rend une mesure unique sans assertion SwiftUI")
    @MainActor
    func singleSampleViewRenders() throws {
        let view = ContextTideView(
            projectName: "Office Chess",
            history: [sample(0, used: 84_000)]
        )
        .frame(width: 390, height: 844)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        #expect(renderer.uiImage != nil)
    }

    @Test("La vue rend un fil sans aucune mesure")
    @MainActor
    func emptyViewRenders() throws {
        let view = ContextTideView(projectName: "Office Chess", history: [])
            .frame(width: 390, height: 844)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        #expect(renderer.uiImage != nil)
    }

    @Test("La jauge rend un niveau inconnu comme un niveau nul")
    @MainActor
    func gaugeRendersWithoutMeasurement() throws {
        for percent in [nil, 0, 42, 100] as [Int?] {
            let renderer = ImageRenderer(
                content: ContextGauge(percent: percent, size: 210)
                    .frame(width: 210, height: 210)
            )
            renderer.scale = 1
            #expect(renderer.uiImage != nil)
        }
    }
}
