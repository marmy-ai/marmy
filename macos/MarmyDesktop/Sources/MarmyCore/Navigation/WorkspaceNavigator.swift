import Foundation

/// An agent, and the team it belongs to.
public struct AgentLocation: Hashable, Sendable {
    public var topologyID: UUID
    public var nodeID: UUID

    public init(topologyID: UUID, nodeID: UUID) {
        self.topologyID = topologyID
        self.nodeID = nodeID
    }
}

/// Keyboard navigation across every saved team.
///
/// Two layers, and which one you are on depends only on whether the selected
/// agent reports to someone:
///
/// - **Roots** — an agent with no manager. Its peers are every root in every
///   team, in the order the teams are shown. Cycling there moves between the
///   orchestrators you are running, which is usually what "next" means when you
///   are looking at a top-level agent.
/// - **Reports** — an agent with a manager. Its peers are only its siblings
///   under that manager, so cycling stays inside the team you are working in.
///
/// A manager nested under another manager is a report, and cycles among its
/// siblings; move it to the root layer and it joins the global cycle. A root
/// worker is a root like any other, so nothing is unreachable.
public enum WorkspaceNavigator {

    /// Every agent at the same layer as `location`, in display order.
    public static func peers(of location: AgentLocation, in topologies: [Topology]) -> [AgentLocation] {
        guard let topology = topologies.first(where: { $0.id == location.topologyID }),
              let node = topology.node(location.nodeID)
        else { return [] }

        if let parentID = node.parentID, topology.contains(parentID) {
            return topology.children(of: parentID)
                .map { AgentLocation(topologyID: topology.id, nodeID: $0.id) }
        }
        return roots(in: topologies)
    }

    /// Every root agent across every team, teams in order, nodes in team order.
    public static func roots(in topologies: [Topology]) -> [AgentLocation] {
        topologies.flatMap { topology in
            topology.roots.map { AgentLocation(topologyID: topology.id, nodeID: $0.id) }
        }
    }

    /// Where a move lands, or `nil` when there is nowhere to go.
    ///
    /// `rememberedChildren` maps a manager to the report last selected under it,
    /// so coming back to a team returns you to where you were.
    public static func destination(
        for move: NavigationMove,
        from location: AgentLocation?,
        in topologies: [Topology],
        rememberedChildren: [UUID: UUID] = [:]
    ) -> AgentLocation? {
        guard let location, let topology = topologies.first(where: { $0.id == location.topologyID }),
              let node = topology.node(location.nodeID)
        else {
            // Nothing sensible is selected: start at the first root anywhere.
            if case .select(let nodeID) = move {
                return locate(nodeID, in: topologies)
            }
            return roots(in: topologies).first ?? firstNode(in: topologies)
        }

        switch move {
        case .select(let nodeID):
            return locate(nodeID, in: topologies)

        case .nextPeer, .previousPeer:
            let peers = peers(of: location, in: topologies)
            guard peers.count > 1, let index = peers.firstIndex(of: location) else { return location }
            let offset = (move == .nextPeer) ? 1 : -1
            return peers[(index + offset + peers.count) % peers.count]

        case .parent:
            guard let parentID = node.parentID, topology.contains(parentID) else { return location }
            return AgentLocation(topologyID: topology.id, nodeID: parentID)

        case .child:
            let children = topology.children(of: node.id)
            guard !children.isEmpty else { return location }
            let remembered = rememberedChildren[node.id]
            let target = children.first { $0.id == remembered } ?? children[0]
            return AgentLocation(topologyID: topology.id, nodeID: target.id)
        }
    }

    public static func locate(_ nodeID: UUID, in topologies: [Topology]) -> AgentLocation? {
        guard let topology = topologies.first(where: { $0.contains(nodeID) }) else { return nil }
        return AgentLocation(topologyID: topology.id, nodeID: nodeID)
    }

    private static func firstNode(in topologies: [Topology]) -> AgentLocation? {
        for topology in topologies {
            if let node = topology.nodes.first {
                return AgentLocation(topologyID: topology.id, nodeID: node.id)
            }
        }
        return nil
    }
}

extension NavigationMove {
    /// Peer moves are the ones that can cross from one team to another.
    public var isPeerMove: Bool {
        self == .nextPeer || self == .previousPeer
    }
}
