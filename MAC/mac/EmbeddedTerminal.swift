import SwiftUI
import AppKit
import SwiftTerm

// One embedded Claude session: an in-app terminal running the CLI via a PTY.
final class TermTab: ObservableObject, Identifiable {
    let id: String
    let folder: String
    let headroom: Bool
    let rtk: Bool
    let caveman: Bool
    @Published var title: String
    @Published var status: String = "ready"   // ready | working | waiting | idle | exited
    let view: LocalProcessTerminalView
    let startedAt = Date()
    // Strong owner for the process delegate (SwiftTerm holds it weakly, so the tab must retain it).
    var coordinator: AnyObject?

    init(id: String, folder: String, headroom: Bool, rtk: Bool, caveman: Bool) {
        self.id = id
        self.folder = folder
        self.headroom = headroom
        self.rtk = rtk
        self.caveman = caveman
        self.title = "T · " + FS.base(folder)
        self.view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
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
               headroom: Bool, rtk: Bool, caveman: Bool) {
        let t = TermTab(id: id, folder: folder, headroom: headroom, rtk: rtk, caveman: caveman)
        let coord = Coordinator(manager: self, tabId: id)
        t.coordinator = coord                 // retain it — processDelegate below is weak
        t.view.processDelegate = coord
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
        tabs.removeAll { $0.id == id }
        if selectedId == id { selectedId = tabs.last?.id }
    }

    func setStatus(_ id: String, _ ev: String) {
        guard let t = tab(id) else { return }
        switch ev {
        case "work": t.status = "working"
        case "stop": t.status = "idle"
        case "notify": t.status = "waiting"
        default: break
        }
    }

    // Bridges SwiftTerm process callbacks back to the manager.
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        weak var manager: TerminalManager?
        let tabId: String
        init(manager: TerminalManager, tabId: String) { self.manager = manager; self.tabId = tabId }

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            DispatchQueue.main.async { self.manager?.tab(self.tabId)?.status = "exited" }
        }
        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            guard !title.isEmpty else { return }
            DispatchQueue.main.async {
                // keep our folder-based label; only adopt CLI titles that look meaningful
                if let t = self.manager?.tab(self.tabId), title.count < 40, !title.hasPrefix("Claude ") {
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
