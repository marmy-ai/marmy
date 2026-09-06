import Foundation
@testable import MarmyCore

/// Deterministic ids so a failing test prints a stable value.
func makeID(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", n))!
}

/// Counter-backed id source for template instantiation tests.
final class IDSequence {
    private var next: Int
    init(start: Int = 900) { self.next = start }
    func callAsFunction() -> UUID {
        defer { next += 1 }
        return makeID(next)
    }
}

enum Fixtures {
    static let managerID = makeID(1)
    static let workerAID = makeID(2)
    static let workerBID = makeID(3)

    /// One manager with two workers who may talk to each other.
    static func team(
        name: String = "Team",
        workingDirectory: String = "/tmp/marmy-tests",
        promptTemplateID: UUID? = nil
    ) -> Topology {
        let manager = AgentNode(
            id: managerID,
            sessionName: "lead",
            displayName: "Lead",
            kind: .manager,
            roleTitle: "Reviews and commits",
            workingDirectory: workingDirectory,
            promptTemplateID: promptTemplateID)
        let workerA = AgentNode(
            id: workerAID,
            sessionName: "build",
            displayName: "Build",
            kind: .worker,
            workingDirectory: workingDirectory,
            parentID: managerID,
            contactIDs: [workerBID],
            promptTemplateID: promptTemplateID)
        let workerB = AgentNode(
            id: workerBID,
            sessionName: "verify",
            displayName: "Verify",
            kind: .worker,
            workingDirectory: workingDirectory,
            parentID: managerID,
            contactIDs: [workerAID],
            promptTemplateID: promptTemplateID)
        return Topology(id: makeID(100), name: name, nodes: [manager, workerA, workerB])
    }

    static func node(
        _ n: Int,
        kind: AgentKind = .worker,
        session: String? = nil,
        parent: UUID? = nil
    ) -> AgentNode {
        AgentNode(
            id: makeID(n),
            sessionName: session ?? "agent\(n)",
            displayName: "Agent \(n)",
            kind: kind,
            workingDirectory: "/tmp/marmy-tests",
            parentID: parent)
    }
}
