import Foundation

/// Where the user is inside a team, and which child they last looked at under
/// each manager.
///
/// This is a value, not a controller: the UI hands it to `TopologyNavigator` and
/// stores whatever comes back, which keeps selection behavior testable without
/// any AppKit involvement.
public struct NavigationState: Codable, Hashable, Sendable {
    public var selectedNodeID: UUID?
    /// Manager id → the child that was selected under it most recently, so
    /// moving down returns to where you were rather than to the first report.
    public var lastVisitedChild: [UUID: UUID]

    public init(selectedNodeID: UUID? = nil, lastVisitedChild: [UUID: UUID] = [:]) {
        self.selectedNodeID = selectedNodeID
        self.lastVisitedChild = lastVisitedChild
    }
}

/// Keyboard navigation moves. The key bindings live in the UI layer
/// (Control-Tab / Control-Shift-Tab for peers, Command-Up for the manager,
/// Command-Down for reports); this type only says what each move means.
public enum NavigationMove: Hashable, Sendable {
    case nextPeer
    case previousPeer
    case parent
    case child
    case select(UUID)
}

/// Pure selection movement across a topology.
public enum TopologyNavigator {

    /// Applies a move and returns the new state. Moves that have nowhere to go
    /// return the state unchanged, so holding a key never wraps into nonsense.
    public static func apply(_ move: NavigationMove, to state: NavigationState, in topology: Topology) -> NavigationState {
        var state = normalized(state, in: topology)

        switch move {
        case .select(let id):
            guard topology.contains(id) else { return state }
            return select(id, in: topology, from: state)

        case .nextPeer:
            return movePeer(offset: 1, state: state, topology: topology)

        case .previousPeer:
            return movePeer(offset: -1, state: state, topology: topology)

        case .parent:
            guard let selected = state.selectedNodeID,
                  let parentID = topology.node(selected)?.parentID,
                  topology.contains(parentID)
            else { return state }
            state.lastVisitedChild[parentID] = selected
            state.selectedNodeID = parentID
            return state

        case .child:
            guard let selected = state.selectedNodeID else {
                return select(topology.roots.first?.id, in: topology, from: state)
            }
            let children = topology.children(of: selected)
            guard !children.isEmpty else { return state }
            let remembered = state.lastVisitedChild[selected]
            let target = children.first { $0.id == remembered } ?? children[0]
            return select(target.id, in: topology, from: state)
        }
    }

    /// The peers of the selection: everyone sharing its manager, in topology
    /// order. Root managers are peers of each other.
    public static func peers(of nodeID: UUID, in topology: Topology) -> [AgentNode] {
        guard let node = topology.node(nodeID) else { return [] }
        return topology.children(of: node.parentID)
    }

    /// Drops a selection or remembered child that no longer exists, so a deleted
    /// agent never leaves the UI pointing at nothing.
    public static func normalized(_ state: NavigationState, in topology: Topology) -> NavigationState {
        var state = state
        if let selected = state.selectedNodeID, !topology.contains(selected) {
            state.selectedNodeID = nil
        }
        state.lastVisitedChild = state.lastVisitedChild.filter { parentID, childID in
            guard topology.contains(parentID), let child = topology.node(childID) else { return false }
            return child.parentID == parentID
        }
        return state
    }

    // MARK: - Private

    private static func movePeer(offset: Int, state: NavigationState, topology: Topology) -> NavigationState {
        guard let selected = state.selectedNodeID else {
            return select(topology.roots.first?.id ?? topology.nodes.first?.id, in: topology, from: state)
        }
        let peers = peers(of: selected, in: topology)
        guard peers.count > 1, let index = peers.firstIndex(where: { $0.id == selected }) else { return state }
        let next = (index + offset + peers.count) % peers.count
        return select(peers[next].id, in: topology, from: state)
    }

    /// Selects a node and records it as the remembered child of its manager.
    private static func select(_ id: UUID?, in topology: Topology, from state: NavigationState) -> NavigationState {
        var state = state
        guard let id, let node = topology.node(id) else {
            state.selectedNodeID = nil
            return state
        }
        state.selectedNodeID = id
        if let parentID = node.parentID, topology.contains(parentID) {
            state.lastVisitedChild[parentID] = id
        }
        return state
    }
}
