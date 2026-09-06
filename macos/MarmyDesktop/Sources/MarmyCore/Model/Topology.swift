import Foundation

/// Errors raised by structural mutations that cannot be expressed as a value.
public enum TopologyMutationError: Error, Equatable, Sendable {
    case unknownNode(UUID)
    case unknownParent(UUID)
    case selfParent(UUID)
    case cycle(childID: UUID, parentID: UUID)
    case parentIsNotManager(parentID: UUID)
}

/// A named, saved team of agents.
///
/// Node order is meaningful: it drives sidebar order, peer cycling, and the
/// order names appear in rendered prompts, so every derived list is stable.
public struct Topology: Identifiable, Codable, Hashable, Sendable {
    /// Where a node sits on the topology canvas.
    public struct CanvasPosition: Codable, Hashable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    public var id: UUID
    public var name: String
    /// Ordered agents. Order is preserved across edits.
    public var nodes: [AgentNode]
    public var notes: String
    /// Hand-placed canvas positions, keyed by node id. Nodes without an entry
    /// are laid out automatically.
    public var layout: [String: CanvasPosition]

    public init(
        id: UUID = UUID(),
        name: String,
        nodes: [AgentNode] = [],
        notes: String = "",
        layout: [String: CanvasPosition] = [:]
    ) {
        self.id = id
        self.name = name
        self.nodes = nodes
        self.notes = notes
        self.layout = layout
    }

    // Layout arrived after the first release, so a file without it still loads.
    private enum CodingKeys: String, CodingKey {
        case id, name, nodes, notes, layout
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        nodes = try container.decode([AgentNode].self, forKey: .nodes)
        notes = try container.decode(String.self, forKey: .notes)
        layout = try container.decodeIfPresent([String: CanvasPosition].self, forKey: .layout) ?? [:]
    }

    public func position(of nodeID: UUID) -> CanvasPosition? {
        layout[nodeID.uuidString]
    }

    public mutating func setPosition(_ position: CanvasPosition?, for nodeID: UUID) {
        layout[nodeID.uuidString] = position
    }

    // MARK: - Lookup

    public func node(_ id: UUID) -> AgentNode? {
        nodes.first { $0.id == id }
    }

    public func contains(_ id: UUID) -> Bool {
        nodes.contains { $0.id == id }
    }

    public func index(of id: UUID) -> Int? {
        nodes.firstIndex { $0.id == id }
    }

    /// Direct reports of `parentID`, in topology order. Pass `nil` for roots.
    public func children(of parentID: UUID?) -> [AgentNode] {
        nodes.filter { $0.parentID == parentID }
    }

    public var roots: [AgentNode] {
        children(of: nil)
    }

    /// Chain from the node's parent up to its root, nearest first.
    /// Stops if it ever revisits a node so a corrupt cycle cannot hang callers.
    public func ancestors(of id: UUID) -> [AgentNode] {
        var result: [AgentNode] = []
        var seen: Set<UUID> = [id]
        var cursor = node(id)?.parentID
        while let current = cursor, seen.insert(current).inserted, let parent = node(current) {
            result.append(parent)
            cursor = parent.parentID
        }
        return result
    }

    /// All descendants of `id`, breadth-first, in topology order per level.
    public func descendants(of id: UUID) -> [AgentNode] {
        var result: [AgentNode] = []
        var seen: Set<UUID> = [id]
        var queue: [UUID] = [id]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            for child in children(of: current) where seen.insert(child.id).inserted {
                result.append(child)
                queue.append(child.id)
            }
        }
        return result
    }

    /// Contacts of a node resolved to nodes, in topology order.
    /// References to nodes that no longer exist are skipped; the validator
    /// reports them separately.
    public func contacts(of id: UUID) -> [AgentNode] {
        guard let node = node(id) else { return [] }
        return nodes.filter { node.contactIDs.contains($0.id) && $0.id != id }
    }

    // MARK: - Mutation

    /// Inserts a node, or replaces the existing node with the same id in place.
    public mutating func upsert(_ node: AgentNode) {
        if let index = index(of: node.id) {
            nodes[index] = node
        } else {
            nodes.append(node)
        }
    }

    /// Removes a node and cleans up every reference to it.
    ///
    /// Children are lifted to the removed node's parent when that parent is a
    /// manager, and otherwise become roots, so deletion never leaves dangling
    /// parents or a worker supervising anyone. Contact references are dropped.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Bool {
        guard let index = index(of: id) else { return false }
        let removed = nodes.remove(at: index)
        layout.removeValue(forKey: id.uuidString)

        let inheritedParent: UUID? = {
            guard let parentID = removed.parentID, let parent = node(parentID) else { return nil }
            return parent.kind == .manager ? parent.id : nil
        }()

        for i in nodes.indices {
            if nodes[i].parentID == id {
                nodes[i].parentID = inheritedParent
            }
            nodes[i].contactIDs.remove(id)
        }
        return true
    }

    /// True when `newParentID` may become the parent of `id`.
    public func canReparent(_ id: UUID, to newParentID: UUID?) -> Bool {
        do {
            try validateReparent(id, to: newParentID)
            return true
        } catch {
            return false
        }
    }

    /// Moves a node under a new parent, refusing self-parenting, cycles at any
    /// depth, and workers acting as parents.
    public mutating func reparent(_ id: UUID, to newParentID: UUID?) throws {
        try validateReparent(id, to: newParentID)
        guard let index = index(of: id) else { throw TopologyMutationError.unknownNode(id) }
        nodes[index].parentID = newParentID
    }

    private func validateReparent(_ id: UUID, to newParentID: UUID?) throws {
        guard contains(id) else { throw TopologyMutationError.unknownNode(id) }
        guard let newParentID else { return }
        if newParentID == id { throw TopologyMutationError.selfParent(id) }
        guard let parent = node(newParentID) else { throw TopologyMutationError.unknownParent(newParentID) }
        if parent.kind != .manager { throw TopologyMutationError.parentIsNotManager(parentID: newParentID) }
        if descendants(of: id).contains(where: { $0.id == newParentID }) {
            throw TopologyMutationError.cycle(childID: id, parentID: newParentID)
        }
    }

    /// Adds a mutual contact permission between two nodes.
    public mutating func linkContacts(_ a: UUID, _ b: UUID) {
        guard a != b, contains(a), contains(b) else { return }
        if let i = index(of: a) { nodes[i].contactIDs.insert(b) }
        if let i = index(of: b) { nodes[i].contactIDs.insert(a) }
    }

    public mutating func unlinkContacts(_ a: UUID, _ b: UUID) {
        if let i = index(of: a) { nodes[i].contactIDs.remove(b) }
        if let i = index(of: b) { nodes[i].contactIDs.remove(a) }
    }

    /// Drops references that point at nodes which no longer exist.
    /// Cheap repair used after bulk edits and after loading older files.
    public mutating func pruneDanglingReferences() {
        let ids = Set(nodes.map(\.id))
        for i in nodes.indices {
            if let parentID = nodes[i].parentID, !ids.contains(parentID) {
                nodes[i].parentID = nil
            }
            let selfID = nodes[i].id
            nodes[i].contactIDs = nodes[i].contactIDs.filter { ids.contains($0) && $0 != selfID }
        }
    }
}
