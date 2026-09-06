import Foundation

/// A single problem found in a topology, addressed to a specific node where
/// possible so the UI can point at it instead of showing a wall of text.
public struct ValidationIssue: Hashable, Sendable, Identifiable {
    public enum Severity: String, Hashable, Sendable, Comparable {
        /// Blocks launching the topology.
        case error
        /// Worth surfacing, but the topology can still start.
        case warning

        private var rank: Int { self == .error ? 1 : 0 }
        public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
    }

    public enum Kind: Hashable, Sendable {
        case emptyTopologyName
        case duplicateNodeID(UUID)
        case invalidSessionName(nodeID: UUID, name: String, problem: TmuxName.Problem)
        case duplicateSessionName(name: String, nodeIDs: [UUID])
        case emptyDisplayName(nodeID: UUID)
        case missingParent(nodeID: UUID, parentID: UUID)
        case selfParent(nodeID: UUID)
        case reportingCycle(nodeIDs: [UUID])
        case parentIsNotManager(nodeID: UUID, parentID: UUID)
        case missingContact(nodeID: UUID, contactID: UUID)
        case selfContact(nodeID: UUID)
        case missingPromptTemplate(nodeID: UUID, templateID: UUID)
        case malformedPromptTemplate(templateID: UUID, detail: String)
        case malformedPromptVariable(templateID: UUID, variable: String)
        case emptyWorkingDirectory(nodeID: UUID)
        case relativeWorkingDirectory(nodeID: UUID, path: String)
        case noNodes
        case noManager
        case unassignedPromptTemplate(nodeID: UUID)
    }

    public let kind: Kind
    public let severity: Severity
    public let message: String
    /// Node the issue is about, when it is about one.
    public let nodeID: UUID?

    public var id: Kind { kind }

    public init(kind: Kind, severity: Severity, message: String, nodeID: UUID? = nil) {
        self.kind = kind
        self.severity = severity
        self.message = message
        self.nodeID = nodeID
    }
}

extension Array where Element == ValidationIssue {
    public var errors: [ValidationIssue] { filter { $0.severity == .error } }
    public var warnings: [ValidationIssue] { filter { $0.severity == .warning } }
    /// True when nothing blocks a launch. Warnings do not block.
    public var isLaunchable: Bool { errors.isEmpty }
}
