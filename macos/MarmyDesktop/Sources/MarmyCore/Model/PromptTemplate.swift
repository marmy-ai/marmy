import Foundation

/// A reusable role prompt, rendered per agent with that agent's real name,
/// manager, reports, permitted contacts, and working directory.
///
/// Templates are instructions given to an agent. They are not enforced by the
/// OS and make no security claim.
public struct PromptTemplate: Identifiable, Codable, Hashable, Sendable {
    /// Which kinds of agent a template is offered for.
    public enum Applicability: String, Codable, CaseIterable, Hashable, Sendable {
        case manager
        case worker
        case any

        public func matches(_ kind: AgentKind) -> Bool {
            switch self {
            case .any: return true
            case .manager: return kind == .manager
            case .worker: return kind == .worker
            }
        }
    }

    public var id: UUID
    public var name: String
    public var summary: String
    public var applicability: Applicability
    /// Template source using `{{variable}}` and `{{#section}}…{{/section}}` tags.
    public var body: String
    /// True for the templates Marmy ships. Shipped templates stay editable; the
    /// flag only lets the UI offer "reset to shipped text".
    public var isBuiltIn: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String = "",
        applicability: Applicability = .any,
        body: String,
        isBuiltIn: Bool = false
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.applicability = applicability
        self.body = body
        self.isBuiltIn = isBuiltIn
    }

    /// A copy with a fresh identity, suitable for "Duplicate".
    public func duplicated(id: UUID = UUID(), name: String? = nil) -> PromptTemplate {
        var copy = self
        copy.id = id
        copy.name = name ?? "\(self.name) copy"
        copy.isBuiltIn = false
        return copy
    }
}
