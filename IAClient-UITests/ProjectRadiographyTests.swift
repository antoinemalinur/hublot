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
