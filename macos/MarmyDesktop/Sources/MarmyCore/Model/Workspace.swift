import Foundation

/// Everything Marmy Desktop persists: saved topologies plus the prompt and
/// topology templates they refer to, carried together behind one version field
/// so a file is always internally consistent.
public struct Workspace: Codable, Hashable, Sendable {
    /// Bump when the on-disk shape changes in a way older builds cannot read.
    public static let currentVersion = 1

    public var version: Int
    public var topologies: [Topology]
    public var promptTemplates: [PromptTemplate]
    public var topologyTemplates: [TopologyTemplate]
    /// What agents should call the human who owns this Mac, rendered as
    /// `{{human.name}}`. Blank falls back to "your human".
    public var operatorName: String

    public init(
        version: Int = Workspace.currentVersion,
        topologies: [Topology] = [],
        promptTemplates: [PromptTemplate] = [],
        topologyTemplates: [TopologyTemplate] = [],
        operatorName: String = ""
    ) {
        self.version = version
        self.topologies = topologies
        self.promptTemplates = promptTemplates
        self.topologyTemplates = topologyTemplates
        self.operatorName = operatorName
    }

    // Decoded field by field so a field added after v1 still loads. The three
    // collections have existed since v1: a file missing one is truncated, not
    // old, and defaulting it to [] would quietly present the user with an empty
    // workspace over the top of their real data.
    private enum CodingKeys: String, CodingKey {
        case version, topologies, promptTemplates, topologyTemplates, operatorName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        topologies = try container.decode([Topology].self, forKey: .topologies)
        promptTemplates = try container.decode([PromptTemplate].self, forKey: .promptTemplates)
        topologyTemplates = try container.decode([TopologyTemplate].self, forKey: .topologyTemplates)
        operatorName = try container.decodeIfPresent(String.self, forKey: .operatorName) ?? ""
    }

    /// A first-run workspace: shipped role prompts and starter team shapes, no
    /// live topologies yet.
    public static func starter() -> Workspace {
        Workspace(
            topologies: [],
            promptTemplates: DefaultTemplates.promptTemplates(),
            topologyTemplates: DefaultTemplates.topologyTemplates(),
            operatorName: NSFullUserName()
        )
    }

    public func topology(_ id: UUID) -> Topology? {
        topologies.first { $0.id == id }
    }

    public func promptTemplate(_ id: UUID) -> PromptTemplate? {
        promptTemplates.first { $0.id == id }
    }

    public func topologyTemplate(_ id: UUID) -> TopologyTemplate? {
        topologyTemplates.first { $0.id == id }
    }

    /// Session names claimed by saved topologies, used when instantiating a
    /// template so a new team never reuses a name already spoken for.
    public var claimedSessionNames: Set<String> {
        var names: Set<String> = []
        for topology in topologies {
            for node in topology.nodes {
                names.insert(node.sessionName)
                if let attached = node.attachedSessionName {
                    names.insert(attached)
                }
            }
        }
        return names
    }

    public mutating func upsert(_ topology: Topology) {
        if let index = topologies.firstIndex(where: { $0.id == topology.id }) {
            topologies[index] = topology
        } else {
            topologies.append(topology)
        }
    }

    /// Removes a topology. Prompt templates are shared and are left alone.
    @discardableResult
    public mutating func removeTopology(_ id: UUID) -> Bool {
        guard let index = topologies.firstIndex(where: { $0.id == id }) else { return false }
        topologies.remove(at: index)
        return true
    }

    public mutating func upsert(_ template: PromptTemplate) {
        if let index = promptTemplates.firstIndex(where: { $0.id == template.id }) {
            promptTemplates[index] = template
        } else {
            promptTemplates.append(template)
        }
    }

    /// Removes a prompt template and clears it from every node that used it, so
    /// no topology is left pointing at a template that is gone.
    @discardableResult
    public mutating func removePromptTemplate(_ id: UUID) -> Bool {
        guard let index = promptTemplates.firstIndex(where: { $0.id == id }) else { return false }
        promptTemplates.remove(at: index)
        for t in topologies.indices {
            for n in topologies[t].nodes.indices where topologies[t].nodes[n].promptTemplateID == id {
                topologies[t].nodes[n].promptTemplateID = nil
            }
        }
        for t in topologyTemplates.indices {
            for n in topologyTemplates[t].prototype.nodes.indices
            where topologyTemplates[t].prototype.nodes[n].promptTemplateID == id {
                topologyTemplates[t].prototype.nodes[n].promptTemplateID = nil
            }
        }
        return true
    }

    public mutating func upsert(_ template: TopologyTemplate) {
        if let index = topologyTemplates.firstIndex(where: { $0.id == template.id }) {
            topologyTemplates[index] = template
        } else {
            topologyTemplates.append(template)
        }
    }

    @discardableResult
    public mutating func removeTopologyTemplate(_ id: UUID) -> Bool {
        guard let index = topologyTemplates.firstIndex(where: { $0.id == id }) else { return false }
        topologyTemplates.remove(at: index)
        return true
    }

    /// Creates a live topology from a saved template, avoiding session names
    /// already claimed anywhere in the workspace, and adds it.
    @discardableResult
    public mutating func instantiateTopologyTemplate(
        _ id: UUID,
        name: String? = nil,
        makeID: () -> UUID = UUID.init
    ) -> Topology? {
        guard let template = topologyTemplate(id) else { return nil }
        let topology = template.instantiate(
            name: name,
            existingSessionNames: claimedSessionNames,
            makeID: makeID
        )
        topologies.append(topology)
        return topology
    }
}
