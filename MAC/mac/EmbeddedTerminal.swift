import SwiftUI
import AppKit
import SwiftTerm

// Terminal view that timestamps PTY output, so hook-less agents (Hermes) can get a
// live Working/Ready status inferred from output activity.
final class ActivityTerminalView: LocalProcessTerminalView {
    var onOutput: (() -> Void)?
    override func dataReceived(slice: ArraySlice<UInt8>) {
        onOutput?()
        super.dataReceived(slice: slice)
    }
}

// One embedded Claude session: an in-app terminal running the CLI via a PTY.
final class TermTab: ObservableObject, Identifiable {
    let id: String
    let folder: String
    let agent: String
    @Published var model: String
    @Published var task: String
    let headroom: Bool
    let rtk: Bool
    let caveman: Bool
    @Published var title: String
    @Published var status: TerminalStatus = .ready
    let cleanupPaths: [String]
    let view: LocalProcessTerminalView
    let startedAt = Date()
    /// Last PTY output timestamp — drives the activity heuristic for hook-less agents.
    var lastOutputAt: Date?
    // Strong owner for the process delegate (SwiftTerm holds it weakly, so the tab must retain it).
    var coordinator: AnyObject?

    init(id: String, folder: String, agent: String, model: String, task: String,
         headroom: Bool, rtk: Bool, caveman: Bool, cleanupPaths: [String]) {
        let taskLabel = task.isEmpty ? "Interactive session" : task
        self.id = id
        self.folder = folder
        self.agent = agent
        self.model = TerminalPresentation.modelLabel(configured: model)
        self.task = taskLabel
        self.headroom = headroom
        self.rtk = rtk
        self.caveman = caveman
        self.cleanupPaths = cleanupPaths
        self.title = TerminalPresentation.tabHint(task: taskLabel, folder: folder)
        self.view = ActivityTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.nativeBackgroundColor = NSColor(srgbRed: 16/255, green: 16/255, blue: 18/255, alpha: 1)
        view.nativeForegroundColor = NSColor(srgbRed: 235/255, green: 235/255, blue: 240/255, alpha: 1)
        if let f = NSFont(name: "SF Mono", size: 12.5) ?? NSFont(name: "Menlo", size: 12.5) {
            view.font = f
        }
    }
}

final class TerminalManager: ObservableObject {
    @Published var tabs: [TermTab] = []
    @Published var selectedId: String?
    weak var app: AppState?
    private var activityTimer: Timer?

    init() {
        // Claude/Codex report turn state through real lifecycle hooks; Hermes has none,
        // so its tabs would sit on "Ready" forever. Infer Working/Ready from PTY output:
        // a thinking/streaming TUI keeps emitting, an idle prompt goes quiet.
        activityTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.pollHookLessActivity()
        }
    }

    private func pollHookLessActivity() {
        for t in tabs where t.agent == "Hermes" && t.status != .stoppedOrTokenLimit {
            guard let last = t.lastOutputAt else { continue }   // no output yet — keep launch state
            let next: TerminalStatus = Date().timeIntervalSince(last) < 2.5 ? .working : .ready
            if t.status != next { t.status = next }
        }
    }

    func tab(_ id: String?) -> TermTab? { tabs.first { $0.id == id } }
    var selected: TermTab? { tab(selectedId) }

    func select(_ id: String) {
        selectedId = id
        if let t = tab(id) {
            DispatchQueue.main.async { t.view.window?.makeFirstResponder(t.view) }
        }
    }

    /// Spawn a Claude session in a new embedded tab.
    func spawn(id: String, folder: String, shellCommand: String, env: [String],
               agent: String = "Claude", model: String = "Default", task: String = "Interactive session",
               headroom: Bool, rtk: Bool, caveman: Bool, cleanupPaths: [String] = []) {
        let t = TermTab(id: id, folder: folder, agent: agent, model: model, task: task,
                        headroom: headroom, rtk: rtk, caveman: caveman, cleanupPaths: cleanupPaths)
        let coord = Coordinator(manager: self, tabId: id)
        t.coordinator = coord                 // retain it — processDelegate below is weak
        t.view.processDelegate = coord
        if agent == "Hermes" {
            (t.view as? ActivityTerminalView)?.onOutput = { [weak t] in t?.lastOutputAt = Date() }
        }
        tabs.append(t)
        selectedId = id
        // Run the command through a login shell so PATH + shims resolve inside the PTY.
        t.view.startProcess(executable: "/bin/zsh",
                            args: ["-l", "-c", shellCommand],
                            environment: env,
                            execName: nil)
        DispatchQueue.main.async { t.view.window?.makeFirstResponder(t.view) }
    }

    func close(_ id: String) {
        guard let t = tab(id) else { return }
        t.view.terminate()
        t.view.removeFromSuperview()
        cleanup(t)
        tabs.removeAll { $0.id == id }
        if selectedId == id { selectedId = tabs.last?.id }
    }

    func setStatus(_ id: String, _ ev: String) {
        applyEvent(id: id, event: ev, payload: nil)
    }

    func applyEvent(id: String, event: String, payload: SessionEventPayload?) {
        guard let t = tab(id) else { return }
        if let model = payload?.model {
            t.model = TerminalPresentation.modelLabel(configured: model)
        }
        t.status = t.status.applying(event: event)
    }

    private func cleanup(_ tab: TermTab) {
        for path in tab.cleanupPaths {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    // Bridges SwiftTerm process callbacks back to the manager.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var manager: TerminalManager?
        let tabId: String
        init(manager: TerminalManager, tabId: String) { self.manager = manager; self.tabId = tabId }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async {
                guard let tab = self.manager?.tab(self.tabId) else { return }
                tab.status = tab.status.applying(event: "exited")
                self.manager?.cleanup(tab)
            }
        }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            guard !title.isEmpty else { return }
            DispatchQueue.main.async {
                // keep our folder-based label; only adopt CLI titles that look meaningful
                if let t = self.manager?.tab(self.tabId), title.count < 40, !title.hasPrefix("Claude "), !title.hasPrefix("Codex ") {
                    t.title = title
                }
            }
        }
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    }
}

// SwiftUI wrapper that shows the currently-selected tab's live terminal view.
struct TerminalContainer: NSViewRepresentable {
    @ObservedObject var manager: TerminalManager

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor(srgbRed: 16/255, green: 16/255, blue: 18/255, alpha: 1).cgColor
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let sel = manager.selected
        // Detach any non-selected terminal views (kept alive by the manager).
        for sub in nsView.subviews where sub !== sel?.view { sub.removeFromSuperview() }
        guard let v = sel?.view else { return }
        if v.superview !== nsView {
            v.frame = nsView.bounds
            v.autoresizingMask = [.width, .height]
            nsView.addSubview(v)
        }
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
    }
}
