//
//  RadiographyView.swift
//  Hublot
//
//  La conversation dépliée en espace : où l'agent est allé, dans quel ordre,
//  et quel état chaque région a réellement annoncé.
//

import SwiftUI

struct RadiographyView: View {
    let projectName: String
    let turns: [Turn]

    @Environment(\.dismiss) private var dismiss
    /// `nil` suit le direct. Une valeur fige la carte dans son passé.
    @State private var frozenStep: Int?
    @State private var selectedRegionID: String?

    private var radiography: ProjectRadiography { ProjectRadiography(turns: turns) }
    private var snapshot: ProjectRadiography.Snapshot {
        radiography.snapshot(through: frozenStep)
    }

    private var machine: MachineState {
        if snapshot.hasActiveWork { return .working }
        if snapshot.hasFailure { return .failed }
        return .idle
    }

    private var selectedRegion: ProjectRadiography.Region? {
        snapshot.regions.first { $0.id == selectedRegionID }
    }

    var body: some View {
        ZStack {
            AmbientBackground(state: machine)

            if snapshot.regions.isEmpty {
                emptyState
            } else {
                RadiographyField(
                    snapshot: snapshot,
                    selectedRegionID: selectedRegionID,
                    onSelect: { region in
                        withAnimation(.snappy(duration: 0.24)) {
                            selectedRegionID = selectedRegionID == region.id ? nil : region.id
                        }
                    }
                )
                .padding(.horizontal, Hublot.unit)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) { header }
        .safeAreaInset(edge: .bottom, spacing: 0) { controls }
        .preferredColorScheme(.dark)
        .onChange(of: snapshot.regions.map(\.id)) { _, visible in
            guard let selectedRegionID, !visible.contains(selectedRegionID) else { return }
            self.selectedRegionID = nil
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: Hublot.unit) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Hublot.prose)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)

            VStack(alignment: .leading, spacing: 2) {
                Text("RADIOGRAPHIE")
                    .font(.hublotMetaEmphasis)
                    .foregroundStyle(Hublot.ember)
                Text(projectName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Hublot.prose)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            HStack(spacing: Hublot.unit * 0.75) {
                Circle()
                    .fill(frozenStep == nil ? Hublot.ember : Hublot.meta)
                    .frame(width: 6, height: 6)
                Text(frozenStep == nil ? "direct" : "passé")
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)
            }
            .padding(.horizontal, Hublot.unit * 1.25)
            .padding(.vertical, Hublot.unit * 0.75)
            .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.vertical, Hublot.unit * 1.25)
        .padding(.bottom, Hublot.unit * 2)
        .background { EdgeScrim(edge: .top).ignoresSafeArea() }
    }

    private var controls: some View {
        VStack(spacing: Hublot.unit) {
            if let selectedRegion {
                RegionInspector(region: selectedRegion)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if !snapshot.regions.isEmpty {
                RadiographyLegend(snapshot: snapshot)
            }

            if !radiography.events.isEmpty {
                timeline
            }
        }
        .padding(.horizontal, Hublot.unit * 2)
        .padding(.top, Hublot.unit * 3)
        .padding(.bottom, Hublot.unit)
        .background { EdgeScrim(edge: .bottom).ignoresSafeArea() }
        .animation(.snappy(duration: 0.24), value: selectedRegionID)
    }

    private var timeline: some View {
        VStack(spacing: Hublot.unit * 0.75) {
            HStack {
                Text(stepCaption)
                    .font(.hublotMetaEmphasis)
                    .foregroundStyle(Hublot.meta)
                Spacer()
                if frozenStep != nil {
                    Button("Revenir au direct") {
                        withAnimation(.snappy(duration: 0.25)) { frozenStep = nil }
                    }
                    .font(.hublotMetaEmphasis)
                    .foregroundStyle(Hublot.ember)
                    .buttonStyle(.plain)
                }
            }

            if let range = radiography.scrubberRange {
                Slider(
                    value: Binding(
                        get: { Double(frozenStep ?? radiography.lastStep) },
                        set: { value in
                            let step = Int(value.rounded())
                            frozenStep = step >= radiography.lastStep ? nil : step
                        }
                    ),
                    in: range,
                    step: 1
                )
                .tint(Hublot.ember)
                .accessibilityLabel("Chronologie de la radiographie")

                HStack {
                    Text("première action")
                    Spacer()
                    Text("maintenant")
                }
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta.opacity(0.75))
            } else {
                HStack(spacing: Hublot.unit * 0.75) {
                    Circle()
                        .fill(Hublot.ember)
                        .frame(width: 5, height: 5)
                    Text("Première action observée")
                    Spacer()
                    Text("maintenant")
                }
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta.opacity(0.75))
            }
        }
        .padding(Hublot.unit * 1.5)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18, style: .continuous))
    }

    private var stepCaption: String {
        let step = frozenStep ?? radiography.lastStep
        return "ACTION \(step + 1) / \(radiography.events.count)"
    }

    private var emptyState: some View {
        VStack(spacing: Hublot.unit * 1.5) {
            Image(systemName: "scope")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Hublot.ember)
                .shadow(color: Hublot.ember.opacity(0.7), radius: 12)
            Text("Aucune région observée")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Hublot.prose)
            Text("La carte apparaîtra dès qu’un outil touchera un fichier ou un service.")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .padding(.bottom, Hublot.unit * 8)
    }
}

// MARK: - Le champ

private struct RadiographyField: View {
    let snapshot: ProjectRadiography.Snapshot
    let selectedRegionID: String?
    let onSelect: (ProjectRadiography.Region) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let positions = RegionLayout.positions(
                for: snapshot.regions,
                totalSlots: snapshot.totalSlots,
                in: geometry.size
            )

            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { time in
                Canvas { context, size in
                    drawOrbits(in: &context, size: size)
                    drawLinks(in: &context, positions: positions)
                    drawCurrent(
                        in: &context,
                        positions: positions,
                        date: time.date,
                        paused: reduceMotion
                    )
                }
            }
            .allowsHitTesting(false)

            ForEach(snapshot.regions) { region in
                if let point = positions[region.id] {
                    RegionNode(
                        region: region,
                        isSelected: selectedRegionID == region.id,
                        action: { onSelect(region) }
                    )
                    .position(point)
                    .transition(.scale(scale: 0.65).combined(with: .opacity))
                }
            }
        }
    }

    private func drawOrbits(in context: inout GraphicsContext, size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        for fraction in [0.36, 0.62, 0.88] {
            let rect = CGRect(
                x: center.x - size.width * fraction / 2,
                y: center.y - size.height * fraction / 2,
                width: size.width * fraction,
                height: size.height * fraction
            )
            context.stroke(
                Path(ellipseIn: rect),
                with: .color(Hublot.rule.opacity(0.22)),
                style: .init(lineWidth: 0.6, dash: [2, 7])
            )
        }
    }

    private func drawLinks(
        in context: inout GraphicsContext,
        positions: [String: CGPoint]
    ) {
        for link in snapshot.links {
            guard let start = positions[link.from], let end = positions[link.to] else { continue }
            let control = CGPoint(
                x: (start.x + end.x) / 2,
                y: (start.y + end.y) / 2 - min(32, abs(end.x - start.x) * 0.16)
            )
            var path = Path()
            path.move(to: start)
            path.addQuadCurve(to: end, control: control)
            context.stroke(
                path,
                with: .color(Hublot.ember.opacity(min(0.48, 0.14 + Double(link.count) * 0.08))),
                style: .init(lineWidth: min(2.4, 0.7 + CGFloat(link.count) * 0.3), lineCap: .round)
            )
        }
    }

    /// Une braise voyage sur la dernière transition observée. Ce n'est pas une
    /// prédiction : elle relit simplement l'ordre des deux derniers outils.
    private func drawCurrent(
        in context: inout GraphicsContext,
        positions: [String: CGPoint],
        date: Date,
        paused: Bool
    ) {
        guard snapshot.events.count > 1 else { return }
        let end = snapshot.events[snapshot.events.count - 1]
        let start = snapshot.events[snapshot.events.count - 2]
        guard start.regionID != end.regionID,
            let from = positions[start.regionID], let to = positions[end.regionID]
        else { return }

        let raw = paused ? 1 : date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 1.8) / 1.8
        let progress = CGFloat(raw)
        let point = CGPoint(
            x: from.x + (to.x - from.x) * progress,
            y: from.y + (to.y - from.y) * progress
        )
        let halo = CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)
        let core = CGRect(x: point.x - 2.5, y: point.y - 2.5, width: 5, height: 5)
        context.fill(Path(ellipseIn: halo), with: .color(Hublot.ember.opacity(0.12)))
        context.fill(Path(ellipseIn: core), with: .color(Hublot.ember))
    }
}

// MARK: - Régions

private struct RegionNode: View {
    let region: ProjectRadiography.Region
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    private var tint: Color {
        switch region.state {
        case .observed: Hublot.meta
        case .changed, .active: Hublot.ember
        case .failed: Hublot.removed
        }
    }

    private var diameter: CGFloat {
        48 + min(CGFloat(region.count) * 3, 16)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: Hublot.unit * 0.5) {
                ZStack {
                    if region.state == .active {
                        Circle()
                            .stroke(tint.opacity(0.5), lineWidth: 1)
                            .frame(width: diameter, height: diameter)
                            .scaleEffect(pulse ? 1.4 : 1)
                            .opacity(pulse ? 0 : 0.8)
                            .animation(
                                reduceMotion ? nil : .easeOut(duration: 1.4).repeatForever(autoreverses: false),
                                value: pulse
                            )
                    }

                    Circle()
                        .fill(tint.opacity(region.state == .observed ? 0.08 : 0.14))
                        .overlay {
                            Circle().stroke(tint.opacity(isSelected ? 0.95 : 0.45), lineWidth: isSelected ? 1.8 : 0.8)
                        }
                        .shadow(color: tint.opacity(region.state == .observed ? 0.12 : 0.65), radius: isSelected ? 14 : 8)
                        .frame(width: diameter, height: diameter)

                    Image(systemName: region.latest.kind.symbol)
                        .font(.system(size: 14, weight: .light))
                        .foregroundStyle(tint)

                    if region.state == .failed {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Hublot.prose)
                            .offset(x: diameter * 0.28, y: -diameter * 0.28)
                    }
                }
                .glassEffect(.regular.interactive(), in: .circle)

                Text(region.name)
                    .font(.hublotMetaEmphasis)
                    .foregroundStyle(isSelected ? Hublot.prose : Hublot.meta)
                    .lineLimit(1)
                    .frame(maxWidth: 94)

                Text("\(region.count)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Hublot.meta.opacity(0.7))
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(region.name), \(region.count) actions, \(stateLabel)")
        .onAppear { pulse = true }
    }

    private var stateLabel: String {
        switch region.state {
        case .observed: "observée"
        case .changed: "modifiée"
        case .active: "active"
        case .failed: "en échec"
        }
    }
}

private enum RegionLayout {
    static func positions(
        for regions: [ProjectRadiography.Region],
        totalSlots: Int,
        in size: CGSize
    ) -> [String: CGPoint] {
        guard !regions.isEmpty else { return [:] }
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        guard totalSlots > 1 else { return [regions[0].id: center] }

        let radiusX = max(70, (size.width - 118) / 2)
        let radiusY = max(80, (size.height - 130) / 2)
        var result: [String: CGPoint] = [:]

        for region in regions {
            let angle = -Double.pi / 2 + Double(region.slot) * 2 * Double.pi / Double(totalSlots)
            // Un léger écart déterministe casse le cercle parfait sans que la
            // carte bouge d'un lancement à l'autre.
            let drift = 0.84 + stableFraction(region.id) * 0.16
            result[region.id] = CGPoint(
                x: center.x + cos(angle) * radiusX * drift,
                y: center.y + sin(angle) * radiusY * drift
            )
        }
        return result
    }

    private static func stableFraction(_ text: String) -> Double {
        let value = text.unicodeScalars.reduce(UInt64(17)) {
            ($0 &* 31 &+ UInt64($1.value)) % 10_007
        }
        return Double(value % 1_000) / 1_000
    }
}

// MARK: - Inspection

private struct RegionInspector: View {
    let region: ProjectRadiography.Region

    private var tint: Color {
        switch region.state {
        case .observed: Hublot.meta
        case .changed, .active: Hublot.ember
        case .failed: Hublot.removed
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Hublot.unit) {
            HStack(spacing: Hublot.unit) {
                Circle().fill(tint).frame(width: 7, height: 7)
                    .shadow(color: tint.opacity(0.7), radius: 5)
                Text(region.name)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Hublot.prose)
                Text("\(region.count) action\(region.count > 1 ? "s" : "")")
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)
                Spacer()
                Image(systemName: region.latest.kind.symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(tint)
            }

            Text(region.latest.title)
                .font(.hublotMono)
                .foregroundStyle(Hublot.prose)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let path = region.latest.displayPath {
                Text(path)
                    .font(.hublotMeta)
                    .foregroundStyle(Hublot.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(Hublot.unit * 1.5)
        .glassEffect(.regular, in: .rect(cornerRadius: 18, style: .continuous))
    }
}

private struct RadiographyLegend: View {
    let snapshot: ProjectRadiography.Snapshot

    var body: some View {
        HStack(spacing: Hublot.unit * 1.5) {
            item("observé", tint: Hublot.meta)
            item("modifié", tint: Hublot.ember)
            item("échec", tint: Hublot.removed)
            Spacer(minLength: 0)
            Text("\(snapshot.regions.count) région\(snapshot.regions.count > 1 ? "s" : "")")
                .font(.hublotMeta)
                .foregroundStyle(Hublot.meta)
        }
        .padding(.horizontal, Hublot.unit * 0.5)
    }

    private func item(_ label: String, tint: Color) -> some View {
        HStack(spacing: Hublot.unit * 0.5) {
            Circle().fill(tint).frame(width: 5, height: 5)
            Text(label).font(.hublotMeta).foregroundStyle(Hublot.meta)
        }
    }
}

extension RadiographyView {
    #if DEBUG
    static var demo: RadiographyView {
        RadiographyView(
        projectName: "Hublot",
        turns: [
            .toolCall(.init(
                id: "read", title: "ChatSession.swift", kind: .read, status: .completed,
                location: "/root/repos/Hublot/IAClient-UI/Domain/ChatSession.swift"
            )),
            .toolCall(.init(
                id: "edit", title: "ConversationView.swift", kind: .edit, status: .completed,
                location: "/root/repos/Hublot/IAClient-UI/UI/ConversationView.swift"
            )),
            .toolCall(.init(
                id: "test", title: "xcodebuild test", kind: .execute, status: .inProgress
            )),
            .toolCall(.init(
                id: "server", title: "acp_server.py", kind: .edit, status: .failed,
                location: "/root/repos/Hublot/Server/acp_server.py"
            )),
        ]
    )
    }
    #endif
}

#Preview("Radiographie") {
    RadiographyView.demo
}
