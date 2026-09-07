import Foundation
import MarmyCore

/// The team as one agent sees it, right now.
///
/// Marmy tells an agent the whole picture rather than a running commentary of
/// changes. A description of what is true now cannot go stale on the way, and it
/// cannot lose anything: if an update waits while an agent is busy and the team
/// changes again meanwhile, the newer description simply replaces the older one.
/// A list of edits could not be replaced that way — the older edits would take
/// facts with them.
public struct RosterSnapshot: Equatable, Sendable {
    public var recipientID: UUID
    /// Everything the message says, in a stable form. Two snapshots with the
    /// same fingerprint say the same thing, so nothing is sent twice.
    public var fingerprint: String
    /// One line, because a line break in a pasted message can make a shell run
    /// the part before it.
    public var message: String
}

public enum RosterUpdate {

    /// How an agent stands from the outside: what it is called, where it is, and
    /// whether it is there yet.
    struct Peer {
        var id: UUID
        var name: String
        var address: String
        var role: String?
        var isManualTerminal: Bool
        var isRunning: Bool
        var isAdopted: Bool
        /// The live pane it is in. A worker started again under the same session
        /// name is a different terminal, and its team is told so.
        var paneID: String

        /// Everything about this peer that a recipient would want to know again
        /// if it changed.
        var fingerprint: String {
            [id.uuidString, name, address, role ?? "", isManualTerminal ? "terminal" : "agent",
             isRunning ? "running" : "down", isAdopted ? "adopted" : "own", paneID]
                .joined(separator: "\u{1F}")
        }

        var described: String {
            var pieces = [address]
            if !paneID.isEmpty { pieces.append("pane \(paneID)") }
            if let role, !role.isEmpty { pieces.append(role) }
            if isManualTerminal {
                pieces.append("a manual terminal a person uses; do not message it")
            } else {
                pieces.append(isRunning ? "running" : "not started yet")
            }
            return "\(name) (\(pieces.joined(separator: ", ")))"
        }
    }

    /// Where a node can actually be reached, preferring the session it is really
    /// attached to over the one the team plan plumped for. Adoption and renaming
    /// both change the first without touching the second.
    public static func address(
        of node: AgentNode,
        states: [UUID: AgentRuntimeState]
    ) -> String {
        if case .running(_, let sessionName, _) = states[node.id] {
            return sessionName
        }
        return node.tmuxAddress
    }

    static func peer(_ node: AgentNode, states: [UUID: AgentRuntimeState]) -> Peer {
        var isAdopted = false
        var paneID = ""
        if case .running(let pane, _, let adopted) = states[node.id] {
            isAdopted = adopted
            paneID = pane
        }
        return Peer(
            id: node.id,
            name: node.displayName,
            address: address(of: node, states: states),
            role: node.roleTitle.isEmpty ? nil : node.roleTitle,
            isManualTerminal: !node.acceptsAgentMessages,
            isRunning: states[node.id]?.isRunning ?? false,
            isAdopted: isAdopted,
            paneID: paneID)
    }

    /// The whole team from one agent's point of view, or `nil` for someone there
    /// is no point telling — a plain terminal, where prose would be a command.
    public static func snapshot(
        for nodeID: UUID,
        in topology: Topology,
        states: [UUID: AgentRuntimeState] = [:],
        operatorName: String = ""
    ) -> RosterSnapshot? {
        guard let node = topology.node(nodeID), node.acceptsAgentMessages else { return nil }

        let manager = node.parentID.flatMap { topology.node($0) }.map { peer($0, states: states) }
        let reports = topology.children(of: nodeID).map { peer($0, states: states) }
        let contacts = topology.contacts(of: nodeID).map { peer($0, states: states) }
        // People who may start a conversation with this one. Being messaged by
        // an agent you were never told about is confusing; so is not knowing
        // where it moved to.
        let inbound = topology.nodes
            .filter { $0.id != nodeID && $0.contactIDs.contains(nodeID) }
            .filter { other in !contacts.contains { $0.id == other.id } }
            .map { peer($0, states: states) }

        let human = operatorName.isEmpty ? "the person running Marmy" : operatorName
        var parts: [String] = [
            "Team update from Marmy. This is who is on your team and who you may contact, as it "
                + "stands now. It replaces only the team information you were given before: your "
                + "role, your instructions, and any rules you were given about committing, pushing, "
                + "or what you may change are unaffected and still apply.",
            "You are \(node.displayName)\(node.roleTitle.isEmpty ? "" : ", \(node.roleTitle)")."
        ]
        if let manager {
            parts.append("You report to \(manager.described).")
        } else {
            parts.append("You report to \(human), the person running Marmy; there is no other "
                + "agent above you on this team.")
        }
        if reports.isEmpty {
            parts.append("Nobody reports to you.")
        } else {
            parts.append("Your reports are: \(reports.map(\.described).joined(separator: "; ")).")
        }
        if !contacts.isEmpty {
            parts.append("You may also talk to: \(contacts.map(\.described).joined(separator: "; ")).")
        }
        if !inbound.isEmpty {
            parts.append("These may contact you: \(inbound.map(\.described).joined(separator: "; ")).")
        }
        parts.append(
            "Nobody else is on this team; do not contact anyone not listed here. Reach each one at "
                + "the tmux session named above; the pane is given so you can tell a restarted "
                + "agent from the one you were talking to before.")

        let fingerprint = ([
            nodeID.uuidString,
            node.displayName,
            node.roleTitle,
            manager?.fingerprint ?? "none",
        ] + reports.map(\.fingerprint) + ["|"] + contacts.map(\.fingerprint) + ["|"]
            + inbound.map(\.fingerprint)).joined(separator: "\u{1E}")

        return RosterSnapshot(
            recipientID: nodeID,
            fingerprint: fingerprint,
            message: parts.joined(separator: " "))
    }

    /// Snapshots for everyone on a team who can be told anything.
    public static func snapshots(
        in topology: Topology,
        states: [UUID: AgentRuntimeState] = [:],
        operatorName: String = ""
    ) -> [UUID: RosterSnapshot] {
        var result: [UUID: RosterSnapshot] = [:]
        for node in topology.nodes {
            if let snapshot = snapshot(
                for: node.id, in: topology, states: states, operatorName: operatorName) {
                result[node.id] = snapshot
            }
        }
        return result
    }
}
