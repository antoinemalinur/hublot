//
//  ProjectRadiography.swift
//  Hublot
//
//  Une lecture spatiale de ce que le fil sait réellement du projet.
//
//  La radiographie ne prétend pas connaître la couverture des tests, les
//  dépendances du dépôt ni l'effet futur d'une commande : ACP ne nous donne
//  pas encore ces preuves. Elle ne dessine donc que des faits observés — les
//  outils, leurs emplacements, leur ordre et leur statut.
//

import Foundation

/// La projection déterministe d'un fil en régions et en liaisons causales.
///
/// Elle ne dépend pas de SwiftUI : les tests peuvent vérifier que la carte ne
/// transforme jamais une simple lecture en modification ou un ancien échec en
/// alarme permanente.
struct ProjectRadiography {

    struct Event: Identifiable, Equatable {
        let id: String
        let sequence: Int
        let title: String
        let kind: ToolKind
        let status: ToolStatus
        let location: String?
        let displayPath: String?
        let regionID: String
        let regionName: String

        var changesProject: Bool {
            guard status == .completed else { return false }
            return kind == .edit || kind == .delete || kind == .move
        }
    }

    struct Region: Identifiable, Equatable {
        enum State: Equatable {
            case observed
            case changed
            case active
            case failed
        }

        let id: String
        let name: String
        let slot: Int
        let events: [Event]
        let state: State

        var latest: Event { events[events.count - 1] }
        var count: Int { events.count }
    }

    struct Link: Identifiable, Equatable {
        let from: String
        let to: String
        let count: Int

        var id: String { "\(from)→\(to)" }
    }

    struct Snapshot: Equatable {
        let regions: [Region]
        let links: [Link]
        let events: [Event]
        /// Nombre total de places, y compris celles qui n'existent pas encore
        /// au point choisi dans la chronologie. Les régions ne changent ainsi
        /// pas de position lorsqu'on remonte le temps.
        let totalSlots: Int

        var hasActiveWork: Bool { regions.contains { $0.state == .active } }
        var hasFailure: Bool { regions.contains { $0.state == .failed } }
    }

    let events: [Event]

    init(turns: [Turn]) {
        let tools: [ToolCallTurn] = turns.compactMap { turn in
            guard case .toolCall(let tool) = turn else { return nil }
            return tool
        }
        events = tools.enumerated().map { sequence, tool in
            let place = Self.place(for: tool.location, kind: tool.kind)
            return Event(
                id: tool.id,
                sequence: sequence,
                title: tool.title,
                kind: tool.kind,
                status: tool.status,
                location: tool.location,
                displayPath: place.displayPath,
                regionID: place.id,
                regionName: place.name
            )
        }
    }

    var lastStep: Int { max(0, events.count - 1) }

    /// Une chronologie ne devient navigable qu'à partir de deux actions.
    ///
    /// SwiftUI refuse un `Slider` dont les deux bornes sont identiques. Garder
    /// cette précondition dans le modèle empêche la vue de fabriquer `0...0`
    /// pendant le bref instant où le premier outil est seul dans le fil.
    var scrubberRange: ClosedRange<Double>? {
        guard events.count > 1 else { return nil }
        return 0...Double(lastStep)
    }

    /// L'état de la carte après l'événement demandé. `nil` signifie le direct.
    func snapshot(through step: Int? = nil) -> Snapshot {
        guard !events.isEmpty else {
            return Snapshot(regions: [], links: [], events: [], totalSlots: 0)
        }

        let end = min(max(step ?? lastStep, 0), lastStep)
        let visible = Array(events.prefix(end + 1))

        // Les places sont calculées sur le fil entier, et non sur l'instant
        // visible : sans ça les continents tournent autour de l'écran pendant
        // qu'on déplace la chronologie, et la mémoire spatiale disparaît.
        var slotByRegion: [String: Int] = [:]
        for event in events where slotByRegion[event.regionID] == nil {
            slotByRegion[event.regionID] = slotByRegion.count
        }

        let grouped = Dictionary(grouping: visible, by: \.regionID)
        let regions = grouped.compactMap { id, regionEvents -> Region? in
            guard let latest = regionEvents.last, let slot = slotByRegion[id] else { return nil }
            let state: Region.State
            if regionEvents.contains(where: { $0.status == .inProgress }) {
                state = .active
            } else if latest.status == .failed {
                // Même règle que le fond ambiant : un ancien échec rattrapé ne
                // condamne pas une région au rouge pour toute son existence.
                state = .failed
            } else if regionEvents.contains(where: \.changesProject) {
                state = .changed
            } else {
                state = .observed
            }
            return Region(
                id: id, name: latest.regionName, slot: slot,
                events: regionEvents, state: state
            )
        }.sorted { $0.slot < $1.slot }

        var linkCounts: [String: (from: String, to: String, count: Int)] = [:]
        for pair in zip(visible, visible.dropFirst()) where pair.0.regionID != pair.1.regionID {
            let key = "\(pair.0.regionID)→\(pair.1.regionID)"
            let previous = linkCounts[key]?.count ?? 0
            linkCounts[key] = (pair.0.regionID, pair.1.regionID, previous + 1)
        }
        let links = linkCounts.values.map {
            Link(from: $0.from, to: $0.to, count: $0.count)
        }.sorted { $0.id < $1.id }

        return Snapshot(
            regions: regions, links: links, events: visible,
            totalSlots: slotByRegion.count
        )
    }

    // MARK: - Géographie

    private struct Place {
        let id: String
        let name: String
        let displayPath: String?
    }

    private static func place(for rawPath: String?, kind: ToolKind) -> Place {
        guard let rawPath, !rawPath.isEmpty else { return fallback(for: kind) }

        var components = rawPath.split(separator: "/").map(String.init)
        // `/root/repos/mon-projet/UI/Foo.swift` devient `UI/Foo.swift`.
        // Le nom du dépôt varie ; le marqueur `repos` est la partie stable.
        if let repos = components.lastIndex(of: "repos"), components.count > repos + 2 {
            components = Array(components.dropFirst(repos + 2))
        }
        while components.first == "." { components.removeFirst() }

        guard !components.isEmpty else {
            return Place(id: "path:/", name: "Racine", displayPath: rawPath)
        }

        let displayPath = components.joined(separator: "/")
        let parents = Array(components.dropLast())
        let name = parents.last ?? "Racine"
        let identity = parents.isEmpty ? "/" : parents.joined(separator: "/")
        return Place(id: "path:\(identity)", name: name, displayPath: displayPath)
    }

    private static func fallback(for kind: ToolKind) -> Place {
        let name: String
        let identity: String
        switch kind {
        case .execute: (name, identity) = ("Terminal", "terminal")
        case .search: (name, identity) = ("Recherche", "search")
        case .fetch: (name, identity) = ("Réseau", "network")
        case .think: (name, identity) = ("Raisonnement", "thought")
        case .read, .edit, .delete, .move: (name, identity) = ("Fichiers", "files")
        case .other: (name, identity) = ("Agent", "agent")
        }
        return Place(id: "kind:\(identity)", name: name, displayPath: nil)
    }
}
