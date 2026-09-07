import Foundation
import MarmyCore
import MarmyRuntime
import Observation

/// Keeps every agent's picture of its own team up to date.
///
/// Each agent is told the team as it stands — the whole picture, not a list of
/// edits — so an update that waits while an agent is busy can simply be replaced
/// by a newer one without anything being lost along the way. An agent is told
/// again only when what it would be told has actually changed: renaming an agent
/// letter by letter produces one message once things settle, and a refresh that
/// finds nothing new produces none.
///
/// Every message is written to the journal before it is sent, and Marmy submits
/// it only when the agent can be positively established as sitting at an empty
/// prompt — checked at the moment of sending, inside the pane's own queue.
/// Anything else waits, visibly, with a button.
///
/// Plain terminals never receive any of this: a shell would run it.
@MainActor
@Observable
public final class RosterCoordinator {

    /// An update that has not gone yet.
    public struct Pending: Identifiable, Equatable, Sendable {
        public var id: UUID { entry.id }
        public var entry: JournalEntry
        public var nodeID: UUID
        public var topologyID: UUID
        /// What the recipient would be told, in stable form. Carried so a newer
        /// description of the same team can replace this one.
        public var fingerprint: String
        public var reason: String
        public var isSending: Bool = false
        /// Why it is still here. Marmy acts on this, never on the wording shown
        /// to the user.
        public var hold: Hold = .waitingForPrompt

        public enum Hold: Equatable, Sendable {
            /// The agent was busy, or Marmy could not establish that it was not.
            /// Worth trying again by itself.
            case waitingForPrompt
            /// Something the user has to decide: it failed, or nobody can say
            /// whether it arrived.
            case needsUser
        }

        /// Whether a newer description may quietly take its place. An attempt
        /// that failed, or one nobody can account for, is history: it stays
        /// until the user deals with it.
        public var isReplaceable: Bool {
            entry.status == .prepared && !isSending
        }

        /// Whether nobody can say if the agent got this.
        ///
        /// `uncertain` is the recorded form. An attempt that has stopped while
        /// still written down as `sending` means the same thing and is worse:
        /// even the record of what happened could not be kept.
        public var isUnconfirmed: Bool {
            entry.status == .uncertain || (entry.status == .sending && !isSending)
        }
    }

    public private(set) var pending: [UUID: Pending] = [:]
    /// Called whenever the journal has changed for an agent, so an open history
    /// refreshes itself.
    @ObservationIgnored public var onJournalChanged: ((UUID) -> Void)?
    /// How long to wait after the last edit before telling anyone.
    public var settleDelay: Duration = .seconds(2)

    @ObservationIgnored private weak var model: AppModel?
    /// What each agent was last told, by fingerprint. An agent with no entry
    /// here has never been told anything and is not told now: it will hear the
    /// team in its own starting prompt.
    @ObservationIgnored private var told: [UUID: String] = [:]
    @ObservationIgnored private var debounceTask: Task<Void, Never>?
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored private var needsAnotherPass = false
    @ObservationIgnored private var hasSeenState = false
    /// Stands in for "this agent's picture of the team is out of date, and Marmy
    /// cannot say what it thinks the team is". It matches no real fingerprint,
    /// so the next pass composes a fresh description and sends that.
    private static let outOfDate = "\u{0}out-of-date"

    public init() {}

    public func attach(model: AppModel) {
        self.model = model
        // Whatever is on screen at startup is the agreed picture: agents were
        // told when it happened, or were never running to be told.
        for topology in model.workspace.topologies {
            takeBaseline(topology, keepingOutOfDate: true)
        }
    }

    /// Takes the current shape as the agreed one for the agents that were just
    /// started, and drops anything that was waiting to be said to them: their
    /// starting prompts describe the team, so an older description of it is not
    /// worth sending.
    ///
    /// Only those agents. Starting one new worker on a running team says nothing
    /// to the manager, and an update queued for that manager is still owed.
    public func adoptBaseline(_ topology: Topology, nodeIDs: Set<UUID>? = nil) {
        let started = nodeIDs ?? Set(topology.nodes.map(\.id))
        takeBaseline(topology, keepingOutOfDate: false, limitedTo: started)
        Task { [weak self] in await self?.dropWaiting(for: started) }
    }

    /// Records what each agent on a team would be told, without telling anyone.
    ///
    /// `keepingOutOfDate` leaves alone any agent Marmy knows has been left
    /// behind — one with an update from a previous run that never went. Taking
    /// a baseline over that would forget it silently.
    private func takeBaseline(
        _ topology: Topology, keepingOutOfDate: Bool, limitedTo nodeIDs: Set<UUID>? = nil
    ) {
        guard let model else { return }
        for (nodeID, snapshot) in RosterUpdate.snapshots(
            in: topology, states: states(of: topology, model),
            operatorName: model.workspace.operatorName) {
            if let nodeIDs, !nodeIDs.contains(nodeID) { continue }
            if keepingOutOfDate, told[nodeID] == Self.outOfDate { continue }
            told[nodeID] = snapshot.fingerprint
        }
    }

    /// Stands down updates for agents that have just been told the team another
    /// way. Only ones that were never attempted.
    private func dropWaiting(for nodeIDs: Set<UUID>) async {
        guard let model else { return }
        for item in pending.values where nodeIDs.contains(item.nodeID) && item.isReplaceable {
            if await model.runtime.supersede(
                item.entry, reason: "This agent was started again and told the team in its "
                    + "starting prompt.") {
                pending.removeValue(forKey: item.id)
                onJournalChanged?(item.nodeID)
            }
        }
    }

    /// Called after any edit to a team. Cheap, and safe to call on every
    /// keystroke: the work happens once things settle.
    public func teamChanged(_ topologyID: UUID) {
        guard let model, model.workspace.topology(topologyID) != nil else { return }
        scheduleReconcile()
    }

    /// Called after each look at the tmux server: an agent coming up, dying,
    /// being adopted, or moving to another session all change what its team
    /// should be told.
    public func observeState() async {
        guard let model else { return }
        guard hasSeenState else {
            // The first look is what "now" means; nobody is told about it —
            // except an agent left behind by a previous run, which is still
            // owed the team as it stands.
            for topology in model.workspace.topologies {
                takeBaseline(topology, keepingOutOfDate: true)
            }
            hasSeenState = true
            return
        }
        await reconcile()
        await retryWaiting()
    }

    /// Brings back updates a previous run wrote down but never sent, and
    /// anything it could not account for.
    public func restorePending() async {
        guard let model else { return }
        do {
            _ = try await model.runtime.reconcileJournal()
            for entry in try await model.runtime.journal.all()
            where entry.kind == .rosterUpdate && (entry.status == .prepared || entry.status == .uncertain) {
                guard let nodeID = entry.nodeID, let topologyID = entry.topologyID else { continue }
                let isUncertain = entry.status == .uncertain
                pending[entry.id] = Pending(
                    entry: entry, nodeID: nodeID, topologyID: topologyID,
                    fingerprint: "",
                    reason: isUncertain
                        ? "Marmy stopped while this was being sent, so it is not known whether the "
                            + "agent received it. Look at its terminal before sending it again."
                        : "Waiting since Marmy last ran.",
                    hold: isUncertain ? .needsUser : .waitingForPrompt)
                if !isUncertain {
                    // This one never went, so whatever this agent thinks the
                    // team is, it is not what Marmy last worked out. The next
                    // pass describes the team as it is now — which may have
                    // changed again while Marmy was not running — and this
                    // stale one stands down in favour of it.
                    told[nodeID] = Self.outOfDate
                }
            }
        } catch {
            model.banner = .failure("Could not read the message history", "\(error)")
        }
    }

    public func pendingItems(forNode nodeID: UUID) -> [Pending] {
        pending.values.filter { $0.nodeID == nodeID }.sorted { $0.entry.createdAt < $1.entry.createdAt }
    }

    public var hasPending: Bool { !pending.isEmpty }

    // MARK: - Working out who needs telling

    private func states(of topology: Topology, _ model: AppModel) -> [UUID: AgentRuntimeState] {
        Dictionary(uniqueKeysWithValues: topology.nodes.map { ($0.id, model.state(of: $0.id)) })
    }

    private func scheduleReconcile() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.settleDelay)
            guard !Task.isCancelled else { return }
            // Past the point where cancelling is safe: from here on a message
            // may be dispatched, and a cancelled dispatch is not a clean
            // failure. A later edit starts a fresh wait and is picked up by the
            // pass this one triggers.
            self.debounceTask = nil
            await self.reconcile()
        }
    }

    /// Tells everyone whose picture of the team has changed.
    ///
    /// Reentrant by design: an edit that lands while this is awaiting a send
    /// sets another pass going rather than being forgotten.
    public func reconcile() async {
        guard !isReconciling else {
            needsAnotherPass = true
            return
        }
        isReconciling = true
        defer { isReconciling = false }

        repeat {
            needsAnotherPass = false
            guard let model else { return }
            for topology in model.workspace.topologies {
                let snapshots = RosterUpdate.snapshots(
                    in: topology, states: states(of: topology, model),
                    operatorName: model.workspace.operatorName)
                for (nodeID, snapshot) in snapshots.sorted(by: {
                    (topology.index(of: $0.key) ?? 0) < (topology.index(of: $1.key) ?? 0)
                }) {
                    guard let last = told[nodeID] else {
                        // First sight of this agent. Its starting prompt is
                        // where it learns the team, so nothing is sent — but
                        // from now on Marmy knows what it has been told, and
                        // the next change reaches it.
                        told[nodeID] = snapshot.fingerprint
                        continue
                    }
                    guard last != snapshot.fingerprint else { continue }
                    let recorded = await prepareAndSend(snapshot, to: nodeID, in: topology)
                    // Only once it is at least written down is this the agreed
                    // picture. Otherwise the change would be forgotten.
                    if recorded { told[nodeID] = snapshot.fingerprint }
                }
            }
        } while needsAnotherPass
    }

    /// Records an update and tries to send it. False when it could not even be
    /// written down.
    @discardableResult
    private func prepareAndSend(
        _ snapshot: RosterSnapshot, to nodeID: UUID, in topology: Topology
    ) async -> Bool {
        guard let model else { return false }
        // Only a running agent has anywhere to receive it. One that is not
        // started yet is told when it starts: its prompt is built fresh.
        guard case .running = model.state(of: nodeID),
              let binding = model.binding(for: nodeID),
              let server = model.readout.server
        else { return true }

        let expected = AgentRuntime.DeliveryTarget(
            sessionID: binding.sessionID, paneID: binding.paneID,
            server: server, generation: binding.generation)

        let entry: JournalEntry
        do {
            entry = try await model.runtime.recordPrepared(
                snapshot.message, kind: .rosterUpdate, toNode: nodeID,
                topologyID: topology.id, expecting: expected)
        } catch {
            model.banner = .failure(
                "A team update was not recorded, so it was not sent",
                "Marmy will try again. \(error)")
            return false
        }

        // The newer description replaces older ones that never went anywhere.
        // Only those: an attempt that failed, or one nobody can account for,
        // stays where the user can see it.
        for old in pendingItems(forNode: nodeID) where old.isReplaceable && old.id != entry.id {
            if await model.runtime.supersede(
                old.entry, reason: "Replaced by a newer description of the team.") {
                pending.removeValue(forKey: old.id)
            }
        }

        onJournalChanged?(nodeID)
        await send(
            Pending(
                entry: entry, nodeID: nodeID, topologyID: topology.id,
                fingerprint: snapshot.fingerprint, reason: ""),
            expected: expected, automatic: true)
        return true
    }

    /// Sends a prepared update. Automatic sends require an empty prompt, which
    /// the runtime checks while holding the pane.
    private func send(_ item: Pending, expected: AgentRuntime.DeliveryTarget, automatic: Bool) async {
        guard let model, let topology = model.workspace.topology(item.topologyID) else { return }
        var item = item
        item.isSending = true
        pending[item.id] = item

        do {
            let finished = try await model.runtime.sendPrepared(
                item.entry, expecting: expected, delivery: .submit,
                requireIdle: automatic, in: topology)
            _ = finished
            pending.removeValue(forKey: item.id)
            onJournalChanged?(item.nodeID)
        } catch let error as RuntimeError {
            switch error {
            case .agentBusy(let detail):
                await hold(
                    item, reason: "Waiting until this agent is at an empty prompt: \(detail)",
                    hold: .waitingForPrompt)
            case .deliveryUncertain:
                await hold(
                    item,
                    reason: "Marmy could not confirm this reached the agent. Look at its terminal "
                        + "before sending it again.",
                    hold: .needsUser)
            default:
                await hold(item, reason: "\(error)", hold: .needsUser)
            }
        } catch {
            await hold(item, reason: "\(error)", hold: .needsUser)
        }
    }

    /// Keeps an update where the user can see it, with the status the journal
    /// actually holds — that status is what says whether a newer description
    /// may take its place.
    private func hold(_ item: Pending, reason: String, hold: Pending.Hold) async {
        onJournalChanged?(item.nodeID)
        var item = item
        item.isSending = false
        item.reason = reason
        item.hold = hold
        if let model, let stored = try? await model.runtime.journal.entry(id: item.entry.id) {
            item.entry = stored
        }
        pending[item.id] = item
    }

    /// The user asking for a waiting update to go now, whatever the agent is
    /// doing.
    public func sendNow(_ id: UUID) async {
        guard var item = pending[id], !item.isSending, let model else { return }
        guard let binding = model.binding(for: item.nodeID), let server = model.readout.server else {
            await hold(item, reason: "This agent is not running.", hold: .needsUser)
            return
        }
        let expected = AgentRuntime.DeliveryTarget(
            sessionID: binding.sessionID, paneID: binding.paneID,
            server: server, generation: binding.generation)

        // A fresh attempt is recorded rather than an old one being re-aimed or
        // rewritten: the agent may be a different launch now, and an attempt
        // that failed — or one nobody can account for — keeps its own recipient
        // and its own outcome exactly as they were.
        if !item.entry.matches(expected) || item.entry.status != .prepared {
            do {
                let retry = try await model.runtime.prepareRetry(of: item.entry, expecting: expected)
                pending.removeValue(forKey: item.id)
                item = Pending(
                    entry: retry, nodeID: item.nodeID, topologyID: item.topologyID,
                    fingerprint: item.fingerprint, reason: "")
                pending[item.id] = item
            } catch {
                await hold(item, reason: "\(error)", hold: .needsUser)
                return
            }
        }
        await send(item, expected: expected, automatic: false)
    }

    /// The user deciding an update is not worth sending.
    ///
    /// One that never went is recorded as thrown away. One that failed, or one
    /// nobody can account for, is only taken off the screen: what became of it
    /// is a fact about the agent, and dismissing it here does not change it.
    public func discard(_ id: UUID) async {
        guard let item = pending[id], let model else { return }
        if item.entry.status == .prepared {
            do {
                _ = try await model.runtime.discard(item.entry, reason: "Thrown away before it was sent.")
            } catch {
                // It is still on record as waiting, so it stays on screen.
                await hold(
                    item,
                    reason: "Marmy could not record that this was thrown away, so it is still here. "
                        + "\(error)",
                    hold: .needsUser)
                return
            }
        }
        pending.removeValue(forKey: id)
        onJournalChanged?(item.nodeID)
    }

    /// Anything held because an agent was busy is worth another try once it is
    /// not.
    private func retryWaiting() async {
        guard let model else { return }
        for item in pending.values where item.isReplaceable && item.hold == .waitingForPrompt {
            guard let binding = model.binding(for: item.nodeID), let server = model.readout.server
            else { continue }
            let expected = AgentRuntime.DeliveryTarget(
                sessionID: binding.sessionID, paneID: binding.paneID,
                server: server, generation: binding.generation)
            // Same terminal, same launch, or it is not the same recipient.
            guard item.entry.matches(expected) else { continue }
            await send(item, expected: expected, automatic: true)
        }
    }
}
