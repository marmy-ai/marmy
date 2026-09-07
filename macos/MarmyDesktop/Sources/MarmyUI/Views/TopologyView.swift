import MarmyCore
import SwiftUI

/// Tidy positions for nodes that have never been dragged: a level per depth,
/// siblings spread across it.
enum AutoLayout {
    static let nodeSize = CGSize(width: 176, height: 56)
    static let horizontalGap: CGFloat = 40
    static let verticalGap: CGFloat = 86

    static func positions(for topology: Topology) -> [UUID: CGPoint] {
        var levels: [[AgentNode]] = []
        var seen: Set<UUID> = []
        var current = topology.roots

        while !current.isEmpty {
            levels.append(current)
            var next: [AgentNode] = []
            for node in current where seen.insert(node.id).inserted {
                next += topology.children(of: node.id).filter { !seen.contains($0.id) }
            }
            current = next
        }
        // Anything unreachable (a corrupt link) still gets a place.
        let placed = Set(levels.flatMap { $0 }.map(\.id))
        let orphans = topology.nodes.filter { !placed.contains($0.id) }
        if !orphans.isEmpty { levels.append(orphans) }

        func width(of count: Int) -> CGFloat {
            CGFloat(count) * nodeSize.width + CGFloat(max(0, count - 1)) * horizontalGap
        }
        // Levels are centred on the widest one, so the tree sits together and the
        // left edge is always on screen whatever the window size.
        let widest = width(of: levels.map(\.count).max() ?? 1)

        var result: [UUID: CGPoint] = [:]
        for (depth, level) in levels.enumerated() {
            let startX = 40 + (widest - width(of: level.count)) / 2
            for (index, node) in level.enumerated() {
                result[node.id] = CGPoint(
                    x: startX + CGFloat(index) * (nodeSize.width + horizontalGap),
                    y: 40 + CGFloat(depth) * (nodeSize.height + verticalGap))
            }
        }
        return result
    }
}

/// Works out how to show a whole team inside the window.
///
/// Fit means fit: the scale is whatever brings the real node bounds inside the
/// viewport, and the result is centred. Hand-placed positions are never changed
/// — only the view is scaled.
enum CanvasFit {
    static func compute(
        bounds: CGRect,
        viewport: CGSize,
        margin: CGFloat = 24
    ) -> (scale: CGFloat, offset: CGSize) {
        guard bounds.width > 0, bounds.height > 0, viewport.width > margin * 2, viewport.height > margin * 2
        else { return (1, .zero) }

        let available = CGSize(width: viewport.width - margin * 2, height: viewport.height - margin * 2)
        // No floor: the guards above already keep the ratio positive, and a
        // clamp would leave a very wide graph hanging off the edge — which is
        // exactly what Fit is for.
        let scale = min(1, min(available.width / bounds.width, available.height / bounds.height))
        let offset = CGSize(
            width: (viewport.width - bounds.width * scale) / 2 - bounds.minX * scale,
            height: (viewport.height - bounds.height * scale) / 2 - bounds.minY * scale)
        return (scale, offset)
    }
}

/// The editing mode: a spacious graph plus an inspector.
struct TopologyView: View {
    @Bindable var env: AppEnvironment

    private var model: AppModel { env.model }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                if let topology = model.selectedTopology {
                    TopologyCanvas(env: env, topology: topology)
                } else {
                    EmptyStateView(
                        title: "No team selected",
                        message: "Create a team to lay out managers and workers."
                    ) {
                        Button("New team") { env.showsNewTeamSheet = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
            Divider()
            InspectorView(env: env)
                .frame(width: 290)
        }
        .background(Theme.paper)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Button {
                _ = model.addNode(kind: .manager, parentID: nil)
            } label: {
                Label("Add manager", systemImage: "plus.circle")
            }
            Button {
                // Under whatever is selected. Nobody selected means a new root.
                _ = model.addNode(kind: .worker, parentID: model.selectedNodeID)
            } label: {
                Label("Add worker", systemImage: "plus.rectangle")
            }
            .help(model.selectedNode.map { "Adds a worker reporting to \($0.displayName)" }
                ?? "Adds a worker with no manager")
            Divider().frame(height: 16)
            Button("Auto layout") { autoLayout() }
                .help("Tidies every node into a level per depth")
            Button("Fit") { env.fitCanvasToken += 1 }
                .help("Scales the graph so the whole team is visible")
            Toggle("Contacts", isOn: Binding(
                get: { model.showsContactConnections },
                set: { model.showsContactConnections = $0 }))
                .toggleStyle(.checkbox)
                .help("Show dashed lines for agents that may talk to each other")
            Spacer()
            Button("Save as team template…") { env.showsSaveTemplateSheet = true }
                .disabled(model.selectedTopology == nil)
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.surface)
    }

    private func autoLayout() {
        guard var topology = model.selectedTopology else { return }
        topology.layout = [:]
        for (id, point) in AutoLayout.positions(for: topology) {
            topology.setPosition(.init(x: point.x, y: point.y), for: id)
        }
        model.update(topology)
    }
}

/// Draggable nodes with reporting lines between them.
struct TopologyCanvas: View {
    @Bindable var env: AppEnvironment
    let topology: Topology

    @State private var dragOffsets: [UUID: CGSize] = [:]
    @State private var connectDrag: (from: UUID, point: CGPoint)?
    /// 1 unless the graph has been scaled down to fit the window.
    @State private var scale: CGFloat = 1
    @State private var fitOffset: CGSize = .zero
    @State private var viewportSize: CGSize = .zero

    private var model: AppModel { env.model }

    private var positions: [UUID: CGPoint] {
        let automatic = AutoLayout.positions(for: topology)
        var result: [UUID: CGPoint] = [:]
        for node in topology.nodes {
            if let saved = topology.position(of: node.id) {
                result[node.id] = CGPoint(x: saved.x, y: saved.y)
            } else {
                result[node.id] = automatic[node.id] ?? CGPoint(x: 60, y: 60)
            }
        }
        return result
    }

    private func origin(_ nodeID: UUID) -> CGPoint {
        let base = positions[nodeID] ?? .zero
        let offset = dragOffsets[nodeID] ?? .zero
        return CGPoint(x: base.x + offset.width, y: base.y + offset.height)
    }

    private func center(_ nodeID: UUID) -> CGPoint {
        let point = origin(nodeID)
        return CGPoint(
            x: point.x + AutoLayout.nodeSize.width / 2,
            y: point.y + AutoLayout.nodeSize.height / 2)
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    connections
                    ForEach(topology.nodes) { node in
                        nodeChip(node)
                            .position(
                                x: origin(node.id).x + AutoLayout.nodeSize.width / 2,
                                y: origin(node.id).y + AutoLayout.nodeSize.height / 2)
                    }
                }
                .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
                .background(Theme.paper)
                .contentShape(Rectangle())
                .onTapGesture { model.inspectedNodeID = nil }
                // Drags and drops are measured here, in unscaled canvas points,
                // so hit testing stays correct when the graph is scaled to fit.
                .coordinateSpace(name: Self.canvasSpace)
                .scaleEffect(scale, anchor: .topLeading)
                .offset(fitOffset)
                .frame(
                    width: max(geometry.size.width, canvasSize.width * scale + fitOffset.width),
                    height: max(geometry.size.height, canvasSize.height * scale + fitOffset.height),
                    alignment: .topLeading)
            }
            .onAppear { viewportSize = geometry.size }
            .onChange(of: geometry.size) { _, size in viewportSize = size }
            .onChange(of: env.fitCanvasToken) { _, _ in fit(in: geometry.size) }
        }
    }

    static let canvasSpace = "marmy.topology.canvas"

    /// Scales and centres the graph so the whole team is visible.
    private func fit(in viewport: CGSize) {
        let result = CanvasFit.compute(bounds: nodeBounds, viewport: viewport)
        scale = result.scale
        fitOffset = result.offset
    }

    /// The rectangle the nodes themselves occupy, which is what has to fit.
    var nodeBounds: CGRect {
        let origins = topology.nodes.map { origin($0.id) }
        guard let first = origins.first else { return .zero }
        var minX = first.x, minY = first.y, maxX = first.x, maxY = first.y
        for point in origins {
            minX = min(minX, point.x)
            minY = min(minY, point.y)
            maxX = max(maxX, point.x)
            maxY = max(maxY, point.y)
        }
        return CGRect(
            x: minX, y: minY,
            width: maxX - minX + AutoLayout.nodeSize.width,
            height: maxY - minY + AutoLayout.nodeSize.height)
    }

    private var canvasSize: CGSize {
        let maxX = positions.values.map(\.x).max() ?? 400
        let maxY = positions.values.map(\.y).max() ?? 300
        return CGSize(width: maxX + AutoLayout.nodeSize.width + 120, height: maxY + AutoLayout.nodeSize.height + 140)
    }

    private var connections: some View {
        Canvas { context, _ in
            for node in topology.nodes {
                guard let parentID = node.parentID, topology.contains(parentID) else { continue }
                let from = center(parentID)
                let to = center(node.id)
                var path = Path()
                path.move(to: CGPoint(x: from.x, y: from.y + AutoLayout.nodeSize.height / 2))
                let midY = (from.y + to.y) / 2
                path.addCurve(
                    to: CGPoint(x: to.x, y: to.y - AutoLayout.nodeSize.height / 2),
                    control1: CGPoint(x: from.x, y: midY),
                    control2: CGPoint(x: to.x, y: midY))
                context.stroke(path, with: .color(Theme.line), lineWidth: 1.5)

                // The arrow points from a manager down to each of its reports.
                let head = CGPoint(x: to.x, y: to.y - AutoLayout.nodeSize.height / 2)
                var arrow = Path()
                arrow.move(to: CGPoint(x: head.x - 4, y: head.y - 6))
                arrow.addLine(to: CGPoint(x: head.x, y: head.y))
                arrow.addLine(to: CGPoint(x: head.x + 4, y: head.y - 6))
                context.stroke(arrow, with: .color(Theme.muted), lineWidth: 1.5)
            }

            if model.showsContactConnections {
                var drawn: Set<String> = []
                for node in topology.nodes {
                    for contact in topology.contacts(of: node.id) {
                        let key = [node.id.uuidString, contact.id.uuidString].sorted().joined()
                        guard drawn.insert(key).inserted else { continue }
                        var path = Path()
                        path.move(to: center(node.id))
                        path.addLine(to: center(contact.id))
                        context.stroke(
                            path,
                            with: .color(Theme.muted.opacity(0.5)),
                            style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
            }

            if let connectDrag {
                var path = Path()
                path.move(to: center(connectDrag.from))
                path.addLine(to: connectDrag.point)
                context.stroke(
                    path, with: .color(Theme.manager),
                    style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
            }
        }
        .frame(width: canvasSize.width, height: canvasSize.height)
        .allowsHitTesting(false)
    }

    private func nodeChip(_ node: AgentNode) -> some View {
        let isSelected = model.inspectedNodeID == node.id
        let running = model.state(of: node.id).isRunning

        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                KindDot(kind: node.kind)
                Text(node.displayName)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 2)
                if running {
                    Circle().fill(Theme.worker).frame(width: 6, height: 6)
                        .help("Running")
                }
            }
            Text(node.tmuxAddress)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(width: AutoLayout.nodeSize.width, height: AutoLayout.nodeSize.height, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.surface)
                .shadow(color: .black.opacity(0.06), radius: 2, y: 1))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? node.kind.tint : Theme.line, lineWidth: isSelected ? 2 : 1))
        .overlay(alignment: .bottom) { connectPort(node) }
        .contentShape(Rectangle())
        .onTapGesture {
            model.inspectedNodeID = node.id
            env.select(node: node.id)
        }
        .contextMenu { NodeMenu(env: env, nodeID: node.id) }
        .gesture(
            DragGesture(coordinateSpace: .named(Self.canvasSpace))
                .onChanged { value in dragOffsets[node.id] = value.translation }
                .onEnded { value in
                    dragOffsets[node.id] = nil
                    commitPosition(for: node.id, translation: value.translation)
                })
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(node.displayName), \(node.kind.displayName)")
    }

    /// The handle under a node: drag it onto another agent to report to it.
    private func connectPort(_ node: AgentNode) -> some View {
        Circle()
            .fill(Theme.surface)
            .overlay(Circle().stroke(Theme.muted, lineWidth: 1.2))
            .frame(width: 12, height: 12)
            .offset(y: 6)
            .gesture(
                DragGesture(coordinateSpace: .named(Self.canvasSpace))
                    .onChanged { value in connectDrag = (node.id, value.location) }
                    .onEnded { value in
                        connectDrag = nil
                        finishConnection(from: node.id, at: value.location)
                    })
            .help("Drag onto another agent to report to them")
    }

    private func commitPosition(for nodeID: UUID, translation: CGSize) {
        guard var topology = model.selectedTopology else { return }
        let base = positions[nodeID] ?? .zero
        topology.setPosition(
            .init(x: max(0, base.x + translation.width), y: max(0, base.y + translation.height)),
            for: nodeID)
        model.update(topology)
    }

    /// One direction only: dragging a node's port onto another node means "this
    /// node now reports to that one". A loop is refused with its own
    /// explanation rather than quietly connecting the other way.
    private func finishConnection(from nodeID: UUID, at point: CGPoint) {
        let hit = topology.nodes.first { candidate in
            guard candidate.id != nodeID else { return false }
            let origin = origin(candidate.id)
            return CGRect(origin: origin, size: AutoLayout.nodeSize).insetBy(dx: -6, dy: -6).contains(point)
        }
        guard let hit else { return }
        if model.reparent(nodeID, to: hit.id) {
            model.inspectedNodeID = nodeID
        }
    }
}
