import Foundation

/// The role prompts and team shapes Marmy ships with.
///
/// Ids are fixed so a shipped template keeps its identity across launches and
/// across reinstalls; the bodies stay fully editable by the user.
public enum DefaultTemplates {

    public enum ID {
        public static let workerPrompt = UUID(uuidString: "1B2E8C10-0000-4000-A000-000000000001")!
        public static let managerPrompt = UUID(uuidString: "1B2E8C10-0000-4000-A000-000000000002")!
        public static let soloPrompt = UUID(uuidString: "1B2E8C10-0000-4000-A000-000000000003")!
        public static let starterTeam = UUID(uuidString: "1B2E8C10-0000-4000-B000-000000000001")!
        public static let pairTeam = UUID(uuidString: "1B2E8C10-0000-4000-B000-000000000002")!
    }

    // MARK: - Prompt templates

    public static func promptTemplates() -> [PromptTemplate] {
        [workerPrompt(), managerPrompt(), soloPrompt()]
    }

    public static func workerPrompt() -> PromptTemplate {
        PromptTemplate(
            id: ID.workerPrompt,
            name: "Implementation worker",
            summary: "Writes code, never touches git, reports to a manager, waits for assignments.",
            applicability: .worker,
            body: """
            You are {{agent.name}}, an implementation worker on {{topology.name}}.
            You are running in tmux session {{agent.session}} with working directory {{agent.cwd}}.
            {{#agent.role}}
            Your role: {{agent.role}}.
            {{/agent.role}}

            How you work:
            - Write and edit code only for the assignment you were given.
            - Never run git add, commit, push, branch, merge, reset, or config. Your manager owns git.
            - Leave unrelated files alone, including untracked ones.
            - When you finish, report what changed, what you tested, and anything you are unsure about.
            - Then stop and wait for the next assignment. Do not pick up new work on your own.
            {{#manager.name}}

            You report to {{manager.name}}, in tmux session {{manager.session}}. Send every report there.
            {{/manager.name}}
            {{^manager.name}}

            You have no manager configured. Report to {{human.name}}.
            {{/manager.name}}
            {{#contacts}}

            Besides your manager, you may talk to: {{contacts}}. Do not contact anyone else.
            {{/contacts}}
            {{^contacts}}
            {{#manager.name}}

            You have no other permitted contacts: talk only to {{manager.name}}.
            Do not message any other agent or session.
            {{/manager.name}}
            {{^manager.name}}

            You have no other permitted contacts: talk only to {{human.name}}.
            Do not message any other agent or session.
            {{/manager.name}}
            {{/contacts}}
            {{#agent.notes}}

            Assignment notes:
            {{agent.notes}}
            {{/agent.notes}}

            Right now: do not start any work.
            {{#manager.name}}
            Wait for your first assignment from {{manager.name}}.
            {{/manager.name}}
            {{^manager.name}}
            Wait for your first assignment from {{human.name}}.
            {{/manager.name}}
            """,
            isBuiltIn: true
        )
    }

    public static func managerPrompt() -> PromptTemplate {
        PromptTemplate(
            id: ID.managerPrompt,
            name: "Delegating manager",
            summary: "Delegates implementation, reviews and tests, owns git, finishes the goal before reporting back.",
            applicability: .manager,
            body: """
            You are {{agent.name}}, a manager on {{topology.name}}.
            You are running in tmux session {{agent.session}} with working directory {{agent.cwd}}.
            {{#agent.role}}
            Your role: {{agent.role}}.
            {{/agent.role}}

            How you work:
            - Delegate implementation to your workers instead of writing the code yourself.
            - Give one clearly scoped assignment at a time and say exactly where to stop.
            - Review and test what comes back. You own quality.
            - You own git for this team: staging, commits, and branches.
            - Carry an assigned goal through to completion on your own. Decide the intermediate steps,
              re-assign, and re-review as needed. Do not ask {{human.name}} to approve each step.
            - Interrupt {{human.name}} only when the goal is done, when you are genuinely blocked, or
              when finishing would need something outside the goal you were given.
            {{#reports}}

            Your reports:
            {{reports.list}}
            {{/reports}}
            {{^reports}}

            You have no reports yet. Do not assume any other agent is running.
            {{/reports}}
            {{#manager.name}}

            You report to {{manager.name}}, in tmux session {{manager.session}}.
            {{/manager.name}}
            {{#contacts}}

            Besides your reports{{#manager.name}} and {{manager.name}}{{/manager.name}}, you may talk to:
            {{contacts}}. Do not contact anyone else.
            {{/contacts}}
            {{^contacts}}
            {{#manager.name}}

            Talk only to your own reports and to {{manager.name}}.
            Do not message other agents or sessions.
            {{/manager.name}}
            {{^manager.name}}

            Talk only to your own reports and to {{human.name}}.
            Do not message other agents or sessions.
            {{/manager.name}}
            {{/contacts}}
            {{#agent.notes}}

            Notes:
            {{agent.notes}}
            {{/agent.notes}}

            Right now: do not start any work and do not message your reports.
            {{#manager.name}}
            Wait for {{manager.name}} to give you the goal.
            {{/manager.name}}
            {{^manager.name}}
            Wait for {{human.name}} to give you the goal.
            {{/manager.name}}
            """,
            isBuiltIn: true
        )
    }

    public static func soloPrompt() -> PromptTemplate {
        PromptTemplate(
            id: ID.soloPrompt,
            name: "Solo agent",
            summary: "A single agent working directly with you.",
            applicability: .any,
            body: """
            You are {{agent.name}}, working in tmux session {{agent.session}} with working directory {{agent.cwd}}.
            {{#agent.role}}
            Your role: {{agent.role}}.
            {{/agent.role}}

            Work the goal you are given through to completion, report what you did, and then wait.
            {{#contacts}}

            You may talk to: {{contacts}}. Do not contact anyone else.
            {{/contacts}}
            {{^contacts}}

            Talk only to {{human.name}}. Do not message other agents or sessions.
            {{/contacts}}
            {{#agent.notes}}

            Notes:
            {{agent.notes}}
            {{/agent.notes}}

            Right now: do not start any work. Wait for {{human.name}} to give you the goal.
            """,
            isBuiltIn: true
        )
    }

    // MARK: - Topology templates

    /// Team shapes offered on the empty state. `workingDirectory` defaults to the
    /// user's home so a stamped-out team always has a real path to start from.
    public static func topologyTemplates(
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [TopologyTemplate] {
        [starterTeam(workingDirectory: workingDirectory), pairTeam(workingDirectory: workingDirectory)]
    }

    /// One manager, two workers, workers allowed to talk to each other.
    public static func starterTeam(
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> TopologyTemplate {
        let managerID = UUID(uuidString: "1B2E8C10-0000-4000-C000-000000000001")!
        let workerAID = UUID(uuidString: "1B2E8C10-0000-4000-C000-000000000002")!
        let workerBID = UUID(uuidString: "1B2E8C10-0000-4000-C000-000000000003")!

        let manager = AgentNode(
            id: managerID,
            sessionName: "lead",
            displayName: "Lead",
            kind: .manager,
            roleTitle: "Plans, reviews, and commits",
            cli: .claude,
            workingDirectory: workingDirectory,
            promptTemplateID: ID.managerPrompt
        )
        let workerA = AgentNode(
            id: workerAID,
            sessionName: "build",
            displayName: "Build",
            kind: .worker,
            roleTitle: "Implementation",
            cli: .claude,
            workingDirectory: workingDirectory,
            parentID: managerID,
            contactIDs: [workerBID],
            promptTemplateID: ID.workerPrompt
        )
        let workerB = AgentNode(
            id: workerBID,
            sessionName: "verify",
            displayName: "Verify",
            kind: .worker,
            roleTitle: "Tests and verification",
            cli: .claude,
            workingDirectory: workingDirectory,
            parentID: managerID,
            contactIDs: [workerAID],
            promptTemplateID: ID.workerPrompt
        )

        return TopologyTemplate(
            id: ID.starterTeam,
            name: "Lead and two workers",
            summary: "A manager who reviews and commits, with an implementer and a verifier.",
            prototype: Topology(
                id: UUID(uuidString: "1B2E8C10-0000-4000-D000-000000000001")!,
                name: "Starter team",
                nodes: [manager, workerA, workerB]
            ),
            isBuiltIn: true
        )
    }

    /// One manager, one worker: the smallest shape that still separates who
    /// writes code from who commits it.
    public static func pairTeam(
        workingDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> TopologyTemplate {
        let managerID = UUID(uuidString: "1B2E8C10-0000-4000-C000-000000000011")!
        let workerID = UUID(uuidString: "1B2E8C10-0000-4000-C000-000000000012")!

        let manager = AgentNode(
            id: managerID,
            sessionName: "lead",
            displayName: "Lead",
            kind: .manager,
            roleTitle: "Reviews and commits",
            cli: .claude,
            workingDirectory: workingDirectory,
            promptTemplateID: ID.managerPrompt
        )
        let worker = AgentNode(
            id: workerID,
            sessionName: "build",
            displayName: "Build",
            kind: .worker,
            roleTitle: "Implementation",
            cli: .claude,
            workingDirectory: workingDirectory,
            parentID: managerID,
            promptTemplateID: ID.workerPrompt
        )

        return TopologyTemplate(
            id: ID.pairTeam,
            name: "Lead and one worker",
            summary: "A manager and a single implementer.",
            prototype: Topology(
                id: UUID(uuidString: "1B2E8C10-0000-4000-D000-000000000002")!,
                name: "Pair",
                nodes: [manager, worker]
            ),
            isBuiltIn: true
        )
    }
}
