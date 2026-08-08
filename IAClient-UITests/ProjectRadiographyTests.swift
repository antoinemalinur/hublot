//
//  ProjectRadiographyTests.swift
//  HublotTests
//

import Foundation
import SwiftUI
import Testing

@testable import IAClient_UI

@Suite("Radiographie du projet")
struct ProjectRadiographyTests {

    @Test("Une action unique ne fabrique pas une plage de slider vide")
    func singleActionHasNoScrubberRange() throws {
        let turns: [Turn] = [
            .toolCall(.init(
                id: "only", title: "pwd", kind: .execute, status: .completed
            )),
        ]

        let map = ProjectRadiography(turns: turns)
        #expect(map.lastStep == 0)
        #expect(map.scrubberRange == nil)

        let second = turns + [
            .toolCall(.init(
                id: "second", title: "rg --files", kind: .search, status: .completed
            )),
        ]
        #expect(ProjectRadiography(turns: second).scrubberRange == 0.0...1.0)
    }

    @Test("La vue rend une action unique sans assertion SwiftUI")
    @MainActor
    func singleActionViewRenders() throws {
        let view = RadiographyView(
            projectName: "Office Chess",
            turns: [
                .toolCall(.init(
                    id: "only", title: "pwd", kind: .execute, status: .completed
                )),
            ]
        )
        .frame(width: 390, height: 844)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        #expect(renderer.uiImage != nil)
    }

    @Test("Les fichiers deviennent des régions sans inventer de couverture")
    func regionsComeFromObservedLocations() throws {
        let turns: [Turn] = [
            .toolCall(.init(
                id: "read", title: "ChatSession.swift", kind: .read, status: .completed,
                location: "/root/repos/Hublot/IAClient-UI/Domain/ChatSession.swift"
            )),
            .toolCall(.init(
                id: "edit", title: "Turn.swift", kind: .edit, status: .completed,
                location: "/root/repos/Hublot/IAClient-UI/Domain/Turn.swift"
            )),
            .toolCall(.init(
                id: "ui", title: "ConversationView.swift", kind: .edit, status: .inProgress,
                location: "/root/repos/Hublot/IAClient-UI/UI/ConversationView.swift"
            )),
            .toolCall(.init(
                id: "test", title: "xcodebuild test", kind: .execute, status: .completed
            )),
        ]

        let snapshot = ProjectRadiography(turns: turns).snapshot()
        #expect(snapshot.regions.map(\.name) == ["Domain", "UI", "Terminal"])
        #expect(snapshot.regions[0].state == .changed)
        #expect(snapshot.regions[1].state == .active)
        // Une commande réussie est observée ; elle ne prouve pas que les deux
        // régions de fichiers sont couvertes par ce test.
        #expect(snapshot.regions[2].state == .observed)
        #expect(snapshot.events[0].displayPath == "IAClient-UI/Domain/ChatSession.swift")
    }

    @Test("Un échec ancien disparaît lorsqu'une action ultérieure réussit")
    func recoveredFailureDoesNotStayRed() throws {
        let turns: [Turn] = [
            .toolCall(.init(
                id: "failure", title: "premier essai", kind: .edit, status: .failed,
                location: "/root/repos/Hublot/Server/acp_server.py"
            )),
            .toolCall(.init(
                id: "recovery", title: "second essai", kind: .edit, status: .completed,
                location: "/root/repos/Hublot/Server/acp_server.py"
            )),
        ]

        let map = ProjectRadiography(turns: turns)
        #expect(map.snapshot(through: 0).regions.first?.state == .failed)
        #expect(map.snapshot().regions.first?.state == .changed)
    }

    @Test("La chronologie garde les régions à leur place")
    func timelineUsesStableSlots() throws {
        let turns: [Turn] = [
            .toolCall(.init(
                id: "a", title: "A.swift", kind: .read, status: .completed,
                location: "/root/repos/P/App/A.swift"
            )),
            .toolCall(.init(
                id: "b", title: "B.swift", kind: .read, status: .completed,
                location: "/root/repos/P/Server/B.swift"
            )),
            .toolCall(.init(
                id: "c", title: "C.swift", kind: .edit, status: .completed,
                location: "/root/repos/P/App/C.swift"
            )),
        ]

        let map = ProjectRadiography(turns: turns)
        let past = map.snapshot(through: 0)
        let present = map.snapshot()
        #expect(past.totalSlots == present.totalSlots)
        #expect(past.regions.first?.slot == present.regions.first { $0.name == "App" }?.slot)
        #expect(present.links.count == 2)
    }

    // MARK: La carte tient dans l'écran

    /// La taille utile du champ sur un iPhone : la largeur pleine moins la
    /// marge, la hauteur entre le chrome du haut et les commandes du bas.
    private static let field = CGSize(width: 377, height: 460)

    /// Deux régions se recouvrent tant que leurs écarts sont inférieurs à leur
    /// encombrement **sur les deux axes** : c'est le critère de deux
    /// rectangles, et un rectangle est bien ce qu'occupe un disque surmontant
    /// son nom.
    private func overlaps(
        _ layout: RegionLayout.Layout, tolerance: CGFloat = 0.5
    ) -> [(Int, Int)] {
        let box = RegionLayout.footprint(
            diameter: layout.diameter, labelWidth: layout.labelWidth
        )
        var found: [(Int, Int)] = []
        for i in layout.slots.indices {
            for j in layout.slots.indices where j > i {
                let dx = abs(layout.slots[i].x - layout.slots[j].x)
                let dy = abs(layout.slots[i].y - layout.slots[j].y)
                if dx < box.width - tolerance && dy < box.height - tolerance {
                    found.append((i, j))
                }
            }
        }
        return found
    }

    @Test("Une carte chargée ne superpose jamais deux régions", arguments: [
        1, 2, 3, 5, 8, 11, 14, 18, 24, 31, 40,
    ])
    func denseLayoutNeverOverlaps(count: Int) throws {
        // Quatorze régions, c'est ce qu'une vraie séance produit — et c'est là
        // que l'ancienne disposition, une seule ellipse, empilait les disques
        // les uns sur les autres.
        let layout = RegionLayout.layout(totalSlots: count, in: Self.field)
        #expect(layout.slots.count == count)
        #expect(overlaps(layout).isEmpty)
    }

    @Test("Un écran étroit n'est pas une excuse pour empiler", arguments: [
        CGSize(width: 320, height: 380), CGSize(width: 377, height: 460),
        CGSize(width: 430, height: 620),
    ])
    func narrowFieldsStillSeparate(field: CGSize) throws {
        let layout = RegionLayout.layout(totalSlots: 14, in: field)
        #expect(overlaps(layout).isEmpty)
    }

    @Test("Aucune région ne déborde du champ")
    func layoutStaysInsideTheField() throws {
        let layout = RegionLayout.layout(totalSlots: 14, in: Self.field)
        let box = RegionLayout.footprint(
            diameter: layout.diameter, labelWidth: layout.labelWidth
        )
        for point in layout.slots {
            #expect(point.x >= box.width / 2 - 0.5)
            #expect(point.x <= Self.field.width - box.width / 2 + 0.5)
            #expect(point.y >= box.height / 2 - 0.5)
            #expect(point.y <= Self.field.height - box.height / 2 + 0.5)
        }
    }

    @Test("Les disques rétrécissent plutôt que de se chevaucher")
    func crowdingShrinksTheNodes() throws {
        let sparse = RegionLayout.layout(totalSlots: 4, in: Self.field)
        let crowded = RegionLayout.layout(totalSlots: 22, in: Self.field)
        #expect(crowded.diameter < sparse.diameter)
        #expect(crowded.diameter >= RegionLayout.minDiameter)
        // Le nom suit le disque : une étiquette à taille fixe recouvrirait le
        // voisin dès que les places se resserrent.
        #expect(crowded.labelWidth < sparse.labelWidth)
    }

    @Test("Remonter la chronologie ne déplace aucune région")
    func placesDoNotMoveWhileScrubbing() throws {
        // Les places sont calculées sur le fil entier : une région apparue au
        // trentième outil occupe déjà sa case au premier.
        let early = RegionLayout.layout(totalSlots: 9, in: Self.field)
        let late = RegionLayout.layout(totalSlots: 9, in: Self.field)
        #expect(early == late)
        #expect(early.slots[3] == late.slots[3])
    }

    @Test("Une carte terminée ne rend rien d'animé")
    @MainActor
    func aFinishedMapRendersStill() throws {
        // La braise qui voyageait sur la dernière transition donnait à croire
        // que l'agent rejouait ses derniers gestes, sur un fil clos depuis des
        // heures. Elle n'existe plus que sur un tour en cours.
        let turns: [Turn] = [
            .toolCall(.init(
                id: "a", title: "A.swift", kind: .read, status: .completed,
                location: "/root/repos/P/App/A.swift"
            )),
            .toolCall(.init(
                id: "b", title: "B.swift", kind: .edit, status: .inProgress,
                location: "/root/repos/P/Server/B.swift"
            )),
        ]
        for isLive in [true, false] {
            let view = RadiographyView(projectName: "P", turns: turns, isLive: isLive)
                .frame(width: 390, height: 844)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1
            #expect(renderer.uiImage != nil)
        }
    }

    @Test("La mise à jour ACP conserve l'emplacement réel dans le fil")
    @MainActor
    func locationSurvivesToolMerging() async throws {
        let harness = try await Harness()
        let chat = await harness.session(id: harness.recordedSession)

        await harness.transport.emit(
            """
            {"jsonrpc":"2.0","method":"session/update","params":{
              "sessionId":"\(harness.recordedSession)","update":{
                "sessionUpdate":"tool_call","toolCallId":"radiography-location",
                "title":"Read File","kind":"read","status":"in_progress"}}}
            """
        )
        await harness.transport.emit(
            """
            {"jsonrpc":"2.0","method":"session/update","params":{
              "sessionId":"\(harness.recordedSession)","update":{
                "sessionUpdate":"tool_call_update","toolCallId":"radiography-location",
                "title":"ChatSession.swift","status":"completed",
                "locations":[{"path":"/root/repos/Hublot/IAClient-UI/Domain/ChatSession.swift"}]}}}
            """
        )

        #expect(await harness.until {
            chat.turns.contains {
                if case .toolCall(let tool) = $0 {
                    return tool.id == "radiography-location" && tool.status == .completed
                }
                return false
            }
        })
        let tool = try #require(chat.turns.compactMap {
            if case .toolCall(let tool) = $0, tool.id == "radiography-location" { tool }
            else { nil }
        }.first)
        #expect(tool.location == "/root/repos/Hublot/IAClient-UI/Domain/ChatSession.swift")
    }
}
