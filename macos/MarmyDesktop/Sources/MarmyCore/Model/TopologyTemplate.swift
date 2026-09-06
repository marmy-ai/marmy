import Foundation

/// Hands out tmux session names that do not collide with names already in use.
///
/// Collisions are resolved with a numeric suffix (`build`, `build-2`, `build-3`)
/// so instantiating a template twice never reuses a live session name.
public struct SessionNameAllocator: Sendable {
    private var taken: Set<String>

    public init(existingNames: Set<String> = []) {
        self.taken = existingNames
    }

    public var allocatedNames: Set<String> { taken }

    public mutating func reserve(_ name: String) {
        taken.insert(name)
    }

    /// Returns a valid, unused tmux session name derived from `base`.
    public mutating func allocate(_ base: String) -> String {
        let sanitized = TmuxName.sanitize(base)
        if !taken.contains(sanitized) {
            taken.insert(sanitized)
            return sanitized
        }
        var suffix = 2
        while true {
            let candidate = Self.candidate(stem: sanitized, suffix: suffix)
            if !taken.contains(candidate) {
                taken.insert(candidate)
                return candidate
            }
            suffix += 1
        }
    }

    /// Builds `stem-N`, trimming the stem rather than the suffix when the two
    /// together would exceed the tmux name limit. Trimming the suffix instead
    /// would keep producing the same already-taken name forever.
    static func candidate(stem: String, suffix: Int) -> String {
        let tail = "-\(suffix)"
        let room = max(1, TmuxName.maxLength - tail.count)
        var trimmed = String(stem.prefix(room))
        while let last = trimmed.last, last == "-" || last == "_" {
            trimmed.removeLast()
        }
        if trimmed.isEmpty { trimmed = "a" }
        return trimmed + tail
    }
}

extension Topology {
    /// Structural copy with fresh identities.
    ///
    /// Every node gets a new UUID, parent and contact references are remapped to
    /// the new ids, and session names are re-allocated against
    /// `existingSessionNames`. Node order, kinds, roles, models, directories, and
    /// edge structure are preserved exactly.
    public func instantiated(
        id newID: UUID = UUID(),
        name newName: String? = nil,
        existingSessionNames: Set<String> = [],
        makeID: () -> UUID = UUID.init
    ) -> Topology {
        var idMap: [UUID: UUID] = [:]
        for node in nodes {
            idMap[node.id] = makeID()
        }
        var allocator = SessionNameAllocator(existingNames: existingSessionNames)

        var copy = self
        copy.id = newID
        copy.name = newName ?? name
        copy.nodes = nodes.map { node in
            var fresh = node
            fresh.id = idMap[node.id] ?? makeID()
            fresh.sessionName = allocator.allocate(node.sessionName)
            fresh.parentID = node.parentID.flatMap { idMap[$0] }
            fresh.contactIDs = Set(node.contactIDs.compactMap { idMap[$0] })
            // An attached live session belongs to the original, never the copy.
            fresh.attachedSessionName = nil
            return fresh
        }
        copy.layout = [:]
        for node in nodes {
            if let position = position(of: node.id), let fresh = idMap[node.id] {
                copy.layout[fresh.uuidString] = position
            }
        }
        return copy
    }
}

/// A saved whole-team shape that can be stamped out repeatedly.
public struct TopologyTemplate: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var summary: String
    /// The shape to copy. Its own ids are template-local and never reused by
    /// instantiation.
    public var prototype: Topology
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        prototype: Topology,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.prototype = prototype
        self.isBuiltIn = isBuiltIn
    }

    /// Captures an existing topology as a reusable template.
    public init(capturing topology: Topology, id: UUID = UUID(), name: String? = nil, summary: String = "") {
        self.id = id
        self.name = name ?? topology.name
        self.summary = summary
        var prototype = topology
        prototype.notes = topology.notes
        for i in prototype.nodes.indices {
            prototype.nodes[i].attachedSessionName = nil
        }
        self.prototype = prototype
        self.isBuiltIn = false
    }

    /// Creates a live topology from this template with fresh UUIDs and
    /// non-colliding session names.
    public func instantiate(
        name: String? = nil,
        existingSessionNames: Set<String> = [],
        makeID: () -> UUID = UUID.init
    ) -> Topology {
        prototype.instantiated(
            id: makeID(),
            name: name ?? prototype.name,
            existingSessionNames: existingSessionNames,
            makeID: makeID
        )
    }
}
