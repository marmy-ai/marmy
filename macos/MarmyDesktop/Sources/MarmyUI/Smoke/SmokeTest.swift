import AppKit
import Foundation
import MarmyCore
import MarmyRuntime
import SwiftUI

/// A deterministic, self-contained run of the real views.
///
///     MarmyDesktop --ui-smoke-test <output directory>
///
/// It builds the actual app views over an isolated workspace and its own
/// private tmux server, drives selection, navigation, drafts and dictation
/// through the same code paths the UI uses, renders its own window to PNG files
/// with `cacheDisplay`, and exits. It never touches the user's tmux server, the
/// real application-support directory, the microphone, or the screen-capture and
/// accessibility permissions.
public enum SmokeTest {
    public static let flag = "--ui-smoke-test"

    public static func run(arguments: [String]) -> Never {
        guard arguments.count >= 2 else {
            FileHandle.standardError.write(Data("usage: MarmyDesktop \(flag) <output directory>\n".utf8))
            exit(64)
        }
        let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        MainActor.assumeIsolated {
            SmokeHarness(outputDirectory: outputDirectory).start()
            // Runs the app loop; the harness exits when it is done.
            NSApplication.shared.run()
        }
        exit(0)
    }
}

/// Drives the smoke run on the main actor.
@MainActor
final class SmokeHarness: NSObject {
    private let outputDirectory: URL
    private let root: URL
    private let socketName: String
    private var window: NSWindow?
    private var env: AppEnvironment?
    private var tmux: TmuxClient?
    private var log: [String] = []
    private var failures: [String] = []

    init(outputDirectory: URL) {
        self.outputDirectory = outputDirectory
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("marmy-ui-smoke-\(UUID().uuidString)", isDirectory: true)
        self.socketName = "marmy-smoke-\(UUID().uuidString.prefix(8).lowercased())"
    }

    func start() {
        // A regular, active app: sidebar materials and the window toolbar only
        // draw the way a user sees them when the app is frontmost.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        Task { await self.execute() }
    }

    private func execute() async {
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try await build()
            await exercise()
            try finish()
        } catch {
            FileHandle.standardError.write(Data("smoke test failed: \(error)\n".utf8))
            cleanUp()
            exit(70)
        }
        cleanUp()
        exit(failures.isEmpty ? 0 : 65)
    }

    // MARK: - Setup

    private func build() async throws {
        let workDirectory = root.appendingPathComponent("work", isDirectory: true)
        let binDirectory = root.appendingPathComponent("bin", isDirectory: true)
        for url in [workDirectory, binDirectory] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        // A stand-in CLI: it prints its arguments and then keeps the pane alive.
        // No agent CLI is ever started, and no model is ever called.
        let fixture = binDirectory.appendingPathComponent("claude")
        try """
        #!/bin/sh
        printf 'marmy smoke agent\\n%s\\n' "$*"
        exec /bin/cat
        """.write(to: fixture, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)

        guard let tmuxPath = ExecutableLocator().locate("tmux") else {
            throw SmokeError.missingTmux
        }
        let server = TmuxServerAddress.named(socketName, configFile: "/dev/null")
        let tmux = TmuxClient(executablePath: tmuxPath, server: server, runner: SystemCommandRunner())
        self.tmux = tmux
        let runtimeStore = RuntimeStore(directoryURL: root.appendingPathComponent("runtime", isDirectory: true))
        let runtime = try AgentRuntime(
            tmux: tmux,
            locator: ExecutableLocator(searchDirectories: [binDirectory.path]),
            store: runtimeStore,
            trampoline: TrampolineCommand.resolveDefault())

        // A session that belongs to nobody, so the sidebar has one to list.
        _ = try await tmux.newSession(
            name: "existing_shell", directory: workDirectory.path,
            executable: "/bin/cat", arguments: [])

        var workspace = Workspace.starter()
        workspace.operatorName = "Marwan"
        var configured = workspace.topologyTemplate(DefaultTemplates.ID.starterTeam)!
            .instantiate(name: "Mac workbench")
        for index in configured.nodes.indices {
            configured.nodes[index].workingDirectory = workDirectory.path
        }
        workspace.upsert(configured)

        let workspaceStore = WorkspaceStore(directoryURL: root.appendingPathComponent("workspace", isDirectory: true))
        try workspaceStore.save(workspace)

        let model = AppModel(store: workspaceStore, runtime: runtime)
        let env = AppEnvironment(model: model, speechEngine: ScriptedSpeechEngine())
        self.env = env

        // Hosted the way the app hosts it, so the toolbar and the sidebar's
        // material are real rather than an approximation.
        let controller = NSHostingController(rootView: RootView(env: env))
        let window = NSWindow(contentViewController: controller)
        window.setContentSize(NSSize(width: 1280, height: 820))
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.toolbarStyle = .unified
        window.title = "Marmy Desktop"
        window.makeKeyAndOrderFront(nil)
        self.window = window

        await model.refresh()
        await settle(seconds: 1.0)
    }

    // MARK: - Exercise

    private func exercise() async {
        guard let env else { return }
        let model = env.model

        await model.launchSelectedTeam()
        await model.refresh()
        let total = model.selectedTopology?.nodes.count ?? 0
        let running = model.selectedTopology?.nodes.filter { model.state(of: $0.id).isRunning }.count ?? 0
        record("launched \(running) of \(total) agents")
        expect(running == total && total > 0, "every agent in the team started")

        guard let topology = model.selectedTopology, let manager = topology.roots.first else {
            fail("the fixture team has no manager")
            return
        }
        let workers = topology.children(of: manager.id)
        guard workers.count >= 2 else {
            fail("the fixture team has fewer than two workers")
            return
        }

        env.select(node: manager.id)
        env.syncTerminal()
        await settle(seconds: 1.4)
        expect(env.currentPane?.connection == .attached, "a terminal attached to the manager")
        expect(terminalHasFocus, "the manager's terminal has keyboard focus after selection")

        // Clicking the row that is already selected must leave its terminal
        // alone. Nothing is re-synced by hand here: the view has to survive on
        // its own, exactly as it would after a click in the sidebar.
        let paneBeforeReselect = env.currentPane
        let clientBeforeReselect = env.currentPane?.clientPID ?? 0
        env.select(node: manager.id)
        await settle(seconds: 0.8)
        expect(
            env.currentPane === paneBeforeReselect
                && env.currentPane?.clientPID == clientBeforeReselect
                && clientBeforeReselect != 0
                && env.currentPane?.connection == .attached,
            "re-selecting the agent that is already selected keeps its terminal attached")

        await snapshot("work-manager")
        // The sidebar is drawn by AppKit into a vibrant "glass" layer that a
        // window-level cacheDisplay does not always pick up, so it is captured
        // on its own as well.
        await snapshotSidebar()

        // Navigation through the real keyboard path, not by calling the model.
        pressKey(KeyboardCoordinator.downArrowKeyCode, modifiers: .command)
        expect(model.selectedNodeID == workers[0].id, "Command-Down selects the first report")
        pressKey(KeyboardCoordinator.tabKeyCode, modifiers: .control)
        expect(model.selectedNodeID == workers[1].id, "Control-Tab moves to the next peer")
        await settle(seconds: 1.0)
        expect(terminalHasFocus, "the terminal keeps keyboard focus after Control-Tab")

        // Dictation belongs to the agent it was spoken to, even when the
        // recogniser answers late.
        let engine = env.voice.engineForTesting as? ScriptedSpeechEngine
        env.select(node: workers[0].id)
        await settle(seconds: 0.6)
        env.micPressed()
        engine?.emit(.volatile(text: "check the build", start: 0, duration: 2))
        let retiredHandler = engine?.captureHandler()
        env.select(node: workers[1].id)
        engine?.emitFromRetiredRun(
            .finalized(text: "check the build twice", start: 0, duration: 2), using: retiredHandler)
        await settle(seconds: 0.5)
        expect(env.dictation.item(for: .node(workers[1].id)) == nil,
               "a late transcript never reaches the newly selected agent")

        env.syncTerminal()
        await settle(seconds: 1.0)
        await snapshot("work-worker")

        // Dictation lands in the agent's own prompt, without being sent.
        env.select(node: workers[1].id)
        env.syncTerminal()
        await settle(seconds: 1.2)
        env.micPressed()
        engine?.emit(.finalized(text: "smoke dictation ✅", start: 0, duration: 2))
        env.micReleased()
        engine?.emit(.finished)
        await settle(seconds: 1.0)

        if let paneID = env.currentPane?.identity.paneID,
           let contents = try? await tmux?.capturePane(paneID, lines: 500, joinWrapped: true) {
            expect(contents.contains("smoke dictation ✅"), "what was dictated is in the agent's prompt")
        } else {
            fail("could not read the agent's pane back")
        }
        expect(env.dictation.item(for: .node(workers[1].id)) == nil, "and nothing is left waiting")

        // The graph.
        model.mode = .topology
        model.inspectedNodeID = manager.id
        await settle(seconds: 0.6)
        await snapshot("topology")

        // Templates, captured from the sheet itself.
        model.mode = .work
        env.showsTemplates = true
        await settle(seconds: 1.0)
        await snapshotSheet("templates")
        env.showsTemplates = false
        await settle(seconds: 0.5)

        // A local session the user never added to a team.
        await model.refresh()
        if let session = model.unassignedSessions.first {
            env.select(localSession: session)
            env.syncTerminal()
            await settle(seconds: 1.0)
            expect(env.currentPane?.connection == .attached, "a local session opens its own terminal")

            let localPaneBefore = env.currentPane
            env.select(localSession: session)
            await settle(seconds: 0.6)
            expect(
                env.currentPane === localPaneBefore && env.currentPane?.connection == .attached,
                "re-selecting the same local session keeps its terminal attached")

            await snapshot("local-session")
        } else {
            fail("the unassigned session was not listed")
        }

        // Reconnecting keeps the agent alive and produces a new client.
        env.select(node: manager.id)
        env.syncTerminal()
        await settle(seconds: 0.8)
        let firstClient = env.currentPane?.clientPID ?? 0
        env.reconnectTerminal()
        await settle(seconds: 1.2)
        let secondClient = env.currentPane?.clientPID ?? 0
        expect(firstClient != 0 && secondClient != 0 && firstClient != secondClient,
               "reconnect starts a fresh terminal client")
        expect(terminalHasFocus, "the reconnected terminal takes keyboard focus")
        await model.refresh()
        expect(model.state(of: manager.id).isRunning, "the agent survived its terminal reconnecting")

        // A wide team: the peer strip must stay one row, and Fit must fit.
        await exerciseLargeTeam()

        // The smallest supported window, and both appearances.
        window?.setContentSize(NSSize(width: 960, height: 640))
        await settle(seconds: 0.8)
        await snapshot("work-minimum-size")

        window?.setContentSize(NSSize(width: 1280, height: 820))
        window?.appearance = NSAppearance(named: .aqua)
        await settle(seconds: 0.8)
        await snapshot("work-light")

        model.mode = .topology
        await settle(seconds: 0.6)
        await snapshot("topology-light")
        window?.appearance = NSAppearance(named: .darkAqua)
        model.mode = .work
        await settle(seconds: 0.5)
    }

    /// Captures the sidebar column by itself.
    private func snapshotSidebar() async {
        await settle(seconds: 0.3)
        guard let sidebar = findSidebar() else {
            record("note: no split view sidebar found to capture")
            return
        }
        capture(sidebar, named: "sidebar")
        // On macOS 26 the sidebar's vibrant material does not always come
        // through cacheDisplay, so its layer tree is rendered as well.
        captureLayer(sidebar, named: "sidebar-layer")
        // And the same view hosted on its own, which proves the content renders
        // even where the split view's material cannot be captured.
        await snapshotSidebarContent()
    }

    /// Hosts the real sidebar view in its own window and captures it.
    private func snapshotSidebarContent() async {
        guard let env else { return }
        let controller = NSHostingController(
            rootView: SidebarView(env: env, showsNewTeam: .constant(false))
                .frame(width: 218, height: 700)
                .background(Theme.paper))
        let fixture = NSWindow(contentViewController: controller)
        fixture.setContentSize(NSSize(width: 218, height: 700))
        fixture.styleMask = [.titled]
        fixture.appearance = window?.appearance
        fixture.orderFront(nil)
        await settle(seconds: 0.6)
        if let view = fixture.contentView {
            capture(view, named: "sidebar-content")
        }
        fixture.orderOut(nil)
        fixture.close()
        // The fixture window took key status; give it back so the focus
        // assertions that follow are about the real window.
        window?.makeKeyAndOrderFront(nil)
        env.focusTerminal()
        await settle(seconds: 0.4)
    }

    private func findSidebar() -> NSView? {
        guard let root = window?.contentView else { return nil }
        var stack: [NSView] = [root]
        while let view = stack.popLast() {
            if let split = view as? NSSplitView, let first = split.arrangedSubviews.first {
                return first
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }

    /// Builds a twelve-worker team and captures the two places width matters.
    private func exerciseLargeTeam() async {
        guard let env else { return }
        let model = env.model
        let directory = root.appendingPathComponent("work", isDirectory: true).path

        var allocator = SessionNameAllocator(existingNames: model.allClaimedSessionNames)
        let managerID = UUID()
        var nodes = [AgentNode(
            id: managerID, sessionName: allocator.allocate("wide-lead"), displayName: "Wide lead",
            kind: .manager, roleTitle: "Coordinates a large team", workingDirectory: directory,
            promptTemplateID: DefaultTemplates.ID.managerPrompt)]
        for index in 1...12 {
            nodes.append(AgentNode(
                sessionName: allocator.allocate("worker-\(index)"),
                displayName: "Worker number \(index)",
                kind: .worker,
                roleTitle: "Implementation",
                workingDirectory: directory,
                parentID: managerID,
                promptTemplateID: DefaultTemplates.ID.workerPrompt))
        }
        let wide = Topology(name: "Wide team", nodes: nodes)
        model.addTeam(wide)
        env.selectTopology(wide.id)
        env.select(node: nodes[6].id)
        await settle(seconds: 0.8)
        await snapshot("work-many-peers")

        model.mode = .topology
        model.inspectedNodeID = nodes[6].id
        await settle(seconds: 0.6)
        await snapshot("topology-many-nodes-unfitted")
        env.fitCanvasToken += 1
        await settle(seconds: 0.8)
        await snapshot("topology-many-nodes-fit")

        // The same arithmetic the canvas uses, checked against the graph area.
        let inspectorWidth: CGFloat = 290
        let sidebarWidth: CGFloat = 218
        let viewport = CGSize(
            width: (window?.frame.width ?? 1280) - inspectorWidth - sidebarWidth,
            height: (window?.frame.height ?? 820) - 160)
        let positions = AutoLayout.positions(for: wide)
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        let bounds = CGRect(
            x: xs.min() ?? 0, y: ys.min() ?? 0,
            width: (xs.max() ?? 0) - (xs.min() ?? 0) + AutoLayout.nodeSize.width,
            height: (ys.max() ?? 0) - (ys.min() ?? 0) + AutoLayout.nodeSize.height)
        let fit = CanvasFit.compute(bounds: bounds, viewport: viewport)
        let right = bounds.minX * fit.scale + fit.offset.width + bounds.width * fit.scale
        let bottom = bounds.minY * fit.scale + fit.offset.height + bounds.height * fit.scale
        expect(right <= viewport.width + 1 && bottom <= viewport.height + 1,
               "Fit brings a twelve-worker graph fully inside the window")

        model.mode = .work
        await settle(seconds: 0.4)
    }

    private var terminalHasFocus: Bool {
        guard let responder = window?.firstResponder, let pane = env?.currentPane else { return false }
        return responder === pane.view
    }

    /// Sends a key through the same monitor the app installs.
    private func pressKey(_ code: UInt16, modifiers: NSEvent.ModifierFlags) {
        guard let env else { return }
        _ = env.keyboard.handleKeyDown(code: code, modifiers: modifiers, isRepeat: false)
        _ = env.keyboard.handleKeyUp(code: code, modifiers: modifiers)
    }

    // MARK: - Output

    /// Captures the window including its titlebar and toolbar.
    private func snapshot(_ name: String) async {
        await settle(seconds: 0.4)
        guard let window, let view = window.contentView?.superview ?? window.contentView else {
            fail("no window to capture for \(name)")
            return
        }
        capture(view, named: name)
    }

    /// Captures an attached sheet, failing when the sheet never appeared.
    private func snapshotSheet(_ name: String) async {
        await settle(seconds: 0.4)
        guard let sheet = window?.attachedSheet else {
            fail("expected a sheet on screen for \(name), but none was attached")
            return
        }
        guard let view = sheet.contentView else {
            fail("the sheet for \(name) had no content")
            return
        }
        capture(view, named: name)
    }

    private func capture(_ view: NSView, named name: String) {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        guard view.bounds.width > 1, view.bounds.height > 1 else {
            fail("nothing to draw for \(name)")
            return
        }
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            fail("could not prepare a bitmap for \(name)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            fail("could not encode \(name) as PNG")
            return
        }
        let url = outputDirectory.appendingPathComponent("\(name).png")
        do {
            try data.write(to: url)
            record("wrote \(url.lastPathComponent) (\(Int(view.bounds.width))×\(Int(view.bounds.height)))")
        } catch {
            fail("could not write \(name).png: \(error)")
        }
    }

    /// Renders a view's layer tree, which picks up content that `cacheDisplay`
    /// leaves out of vibrant material views.
    private func captureLayer(_ view: NSView, named name: String) {
        guard let layer = view.layer else {
            record("note: \(name) has no layer to render")
            return
        }
        let scale = window?.backingScaleFactor ?? 2
        let width = Int(view.bounds.width * scale)
        let height = Int(view.bounds.height * scale)
        guard width > 1, height > 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else {
            record("note: could not prepare a layer bitmap for \(name)")
            return
        }
        context.cgContext.scaleBy(x: scale, y: scale)
        layer.render(in: context.cgContext)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: outputDirectory.appendingPathComponent("\(name).png"))
        record("wrote \(name).png (layer render)")
    }

    private func settle(seconds: Double) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            await Task.yield()
        }
        window?.contentView?.layoutSubtreeIfNeeded()
    }

    private func record(_ line: String) {
        log.append(line)
        print("smoke: \(line)")
    }

    private func expect(_ condition: Bool, _ description: String) {
        if condition {
            record("ok — \(description)")
        } else {
            fail(description)
        }
    }

    private func fail(_ description: String) {
        failures.append(description)
        log.append("FAILED — \(description)")
        FileHandle.standardError.write(Data("smoke FAILED: \(description)\n".utf8))
    }

    private func finish() throws {
        let expected = [
            "work-manager", "work-worker", "topology", "templates", "sidebar",
            "local-session", "work-minimum-size", "work-light", "topology-light",
            "work-many-peers", "topology-many-nodes-fit",
        ]
        for name in expected {
            let url = outputDirectory.appendingPathComponent("\(name).png")
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            if (size ?? 0) < 1024 {
                fail("\(name).png is missing or empty")
            }
        }
        let summary = (log + ["", failures.isEmpty ? "result: passed" : "result: \(failures.count) failed"])
            .joined(separator: "\n")
        try summary.write(
            to: outputDirectory.appendingPathComponent("smoke-report.txt"),
            atomically: true, encoding: .utf8)
        print(summary)
    }

    private func cleanUp() {
        env?.shutDown()
        // Ends the private server and everything on it. Nothing else is touched.
        if let tmuxPath = ExecutableLocator().locate("tmux") {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tmuxPath)
            process.arguments = ["-L", socketName, "-f", "/dev/null", "kill-server"]
            try? process.run()
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }

    enum SmokeError: Error, CustomStringConvertible {
        case missingTmux

        var description: String {
            switch self {
            case .missingTmux: return "tmux is not installed, so the smoke test cannot run."
            }
        }
    }
}

/// A speech engine driven by the test, never by a microphone.
@MainActor
public final class ScriptedSpeechEngine: SpeechEngine {
    public var isAvailable = true
    public var supportsOnDevice = true
    public var supportsLongForm = true
    public var preparation: SpeechModelPreparation = .ready
    public var authorization: SpeechAuthorization = .authorized
    /// Which permission a refusal should be blamed on.
    public var microphoneDenied = true
    public var speechDenied = true

    public var microphoneAuthorization: SpeechAuthorization {
        authorization == .denied ? (microphoneDenied ? .denied : .authorized) : authorization
    }

    public var speechAuthorization: SpeechAuthorization {
        authorization == .denied ? (speechDenied ? .denied : .authorized) : authorization
    }
    public private(set) var isRunning = false
    public private(set) var startCount = 0
    public private(set) var cancelCount = 0
    public private(set) var stopCount = 0
    /// Set to hold the answer back until `deliverAuthorization` is called.
    public var deferAuthorization = false
    /// Some engines report the end of a capture synchronously inside `stop()`.
    public var finishesOnStop = false

    private var handler: (@MainActor (SpeechEvent) -> Void)?
    private var pendingAuthorization: (@MainActor (SpeechAuthorization) -> Void)?

    public init() {}

    public func requestAuthorization(_ completion: @escaping @MainActor (SpeechAuthorization) -> Void) {
        if deferAuthorization {
            pendingAuthorization = completion
        } else {
            completion(authorization)
        }
    }

    /// Answers a permission request that was deliberately held back.
    public func deliverAuthorization(_ value: SpeechAuthorization? = nil) {
        let completion = pendingAuthorization
        pendingAuthorization = nil
        completion?(value ?? authorization)
    }

    public var hasPendingAuthorization: Bool { pendingAuthorization != nil }

    public func start(_ handler: @escaping @MainActor (SpeechEvent) -> Void) throws {
        startCount += 1
        isRunning = true
        self.handler = handler
    }

    public func prepare() async throws { preparation = .ready }

    public func stop() {
        stopCount += 1
        isRunning = false
        if finishesOnStop { handler?(.finished) }
    }

    public func cancel() {
        cancelCount += 1
        isRunning = false
        handler = nil
    }

    /// Sends an event as the recogniser would.
    public func emit(_ event: SpeechEvent) {
        handler?(event)
    }

    /// Sends an event from a run that has already been retired.
    public func emitFromRetiredRun(_ event: SpeechEvent, using stale: (@MainActor (SpeechEvent) -> Void)?) {
        stale?(event)
    }

    public func captureHandler() -> (@MainActor (SpeechEvent) -> Void)? { handler }
}
