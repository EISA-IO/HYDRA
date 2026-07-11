import SwiftUI
import AppKit
import Combine

@main
struct HydraApp: App {
    @StateObject private var app = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(app)
                .environmentObject(app.terminals)
                .frame(minWidth: 940, minHeight: 640)
                .preferredColorScheme(.dark)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands { CommandGroup(replacing: .newItem) {} }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct NavItem: Identifiable {
    let id: Int
    let title: String
    let icon: String
}

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var terminals: TerminalManager
    @State private var tab = initialTab()

    static func initialTab() -> Int {
        // Allow `open -n "Hydra.app" --args --tab 3` to preselect a tab (used for QA).
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--tab"), i + 1 < args.count, let n = Int(args[i + 1]), (0...6).contains(n) {
            return n
        }
        return 0
    }

    let items = [
        NavItem(id: 0, title: "Workspace", icon: "terminal.fill"),
        NavItem(id: 1, title: "Settings", icon: "slider.horizontal.3"),
        NavItem(id: 2, title: "SaaS", icon: "shippingbox.fill"),
        NavItem(id: 3, title: "Skills", icon: "puzzlepiece.extension.fill"),
        NavItem(id: 4, title: "Glossary", icon: "book.fill"),
        NavItem(id: 5, title: "Ollama", icon: "cpu.fill"),
        NavItem(id: 6, title: "MCP", icon: "point.3.connected.trianglepath.dotted")
    ]

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().overlay(Color.black.opacity(0.5))
            ZStack {
                Theme.bg.ignoresSafeArea()
                content
            }
        }
        .background(Theme.bg)
        .ignoresSafeArea(.container, edges: .top)
        .onChange(of: app.pendingTab) {
            if let t = app.pendingTab { tab = t; app.pendingTab = nil }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            app.ollama.shutdown()
        }
        .onAppear {
            // QA hook: `--demoterm` auto-opens one embedded terminal so the Workspace can be
            // screenshotted running a real session without clicking.
            if CommandLine.arguments.contains("--demoterm") {
                let dir = FS.isDir(Paths.home + "/Desktop/HYDRA") ? Paths.home + "/Desktop/HYDRA" : Paths.home
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    app.folder = dir
                    app.launch(folder: dir)
                }
            }
            // QA hook for the native multi-session Hermes path. Each call creates a separate
            // PTY/tab and snapshots the launch defaults at that moment.
            if CommandLine.arguments.contains("--demohermes") {
                let dir = FS.isDir(Paths.home + "/Desktop/HYDRA") ? Paths.home + "/Desktop/HYDRA" : Paths.home
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    app.folder = dir
                    app.setAgent("Hermes")
                    app.launch(folder: dir)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        app.launch(folder: dir)
                    }
                }
            }
            // QA: `--qa <caveman|video|agent-skills|update|everything>` runs an installer method so the log
            // pipeline can be observed deterministically.
            if let i = CommandLine.arguments.firstIndex(of: "--qa"), i + 1 < CommandLine.arguments.count {
                let what = CommandLine.arguments[i + 1]
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    switch what {
                    case "caveman": app.installCaveman()
                    case "video": app.installClaudeVideo()
                    case "agent-skills": app.installAgentSkills()
                    case "update": app.updateCore()
                    case "everything": app.installEverything()
                    default: break
                    }
                }
            }
        }
    }

    @ViewBuilder var content: some View {
        switch tab {
        case 0: WorkspaceView()
        case 1: SettingsHubView()
        case 2: SaaSView()
        case 3: SkillsView()
        case 4: GlossaryView()
        case 5: OllamaTabView()
        case 6: MCPView()
        default: WorkspaceView()
        }
    }

    var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                logo
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text("Hydra").font(.system(size: 14.5, weight: .bold)).foregroundStyle(.white)
                        Text("v1").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.accent)
                    }
                    Text("By Ahmed Al-Eissa")
                        .font(.system(size: 10.5)).italic().foregroundStyle(Theme.textFaint)
                }
            }
            .padding(.horizontal, 14).padding(.top, 26).padding(.bottom, 18)

            ForEach(items) { item in
                Button {
                    tab = item.id
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: item.icon).font(.system(size: 13)).frame(width: 18)
                        Text(item.title).font(.system(size: 13, weight: tab == item.id ? .semibold : .regular))
                        Spacer()
                    }
                    .foregroundStyle(tab == item.id ? .white : Theme.textDim)
                    .padding(.vertical, 8).padding(.horizontal, 12)
                    .background(tab == item.id ? Theme.accent.opacity(0.16) : Color.clear)
                    .overlay(alignment: .leading) {
                        if tab == item.id {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: 3, height: 20)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(KeyEquivalent(Character("\(item.id + 1)")), modifiers: .command)
                .padding(.horizontal, 8)
            }

            Divider()
                .overlay(Color.white.opacity(0.06))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            OllamaSidebarControl(ollama: app.ollama)

            Spacer()

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle().fill(app.proxyRunning ? Theme.green : Theme.textFaint).frame(width: 7, height: 7)
                    Text(app.proxyRunning ? "Headroom proxy up" : "Proxy idle")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
                }
                Text("\(app.countSkills()) skills · \(terminals.tabs.count) terminals")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.textFaint)
            }
            .padding(.horizontal, 16).padding(.bottom, 16)
        }
        .frame(width: 190)
        .frame(maxHeight: .infinity)
        .background(Theme.titleBg)
    }

    var logo: some View {
        Group {
            if let img = loadLogo() {
                Image(nsImage: img).resizable().interpolation(.high)
                    .frame(width: 30, height: 30)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            } else {
                RoundedRectangle(cornerRadius: 7).fill(Theme.accent).frame(width: 30, height: 30)
                    .overlay(Image(systemName: "sparkle").foregroundStyle(.black))
            }
        }
    }

    func loadLogo() -> NSImage? {
        // Bundled resource ONLY — probing ~/Desktop at startup fires a macOS privacy prompt.
        if let p = Bundle.main.path(forResource: "bot", ofType: "png"), let img = NSImage(contentsOfFile: p) { return img }
        return nil
    }
}

struct OllamaSidebarControl: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var ollama: OllamaService

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Status row below is the single source of truth; the Start/Stop button only
            // shows when there's an action to take (an external server has nothing to press).
            if ollama.state != .runningExternal {
                Button {
                    if ollama.state == .runningOwned {
                        ollama.stop()
                    } else {
                        ollama.start()
                        if let message = ollama.errorMessage {
                            app.alert("Ollama", message)
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: ollama.state == .runningOwned ? "stop.fill" : "play.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 18)
                        Text(ollama.buttonTitle)
                            .font(.system(size: 12.5, weight: .semibold))
                        Spacer()
                    }
                    .foregroundStyle(ollama.isRunning ? Theme.green : Theme.textDim)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 12)
                    .background(ollama.isRunning ? Theme.green.opacity(0.10) : Color.white.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(ollama.buttonDisabled)
                .accessibilityLabel(ollama.buttonTitle)
                .help(ollamaHelp)
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)
                Text(ollama.statusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.textFaint)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)

            Button {
                app.openOllamaChat()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                    Text("Ollama Chat")
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(Theme.textFaint)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .help("Chat with the picked local model in an embedded terminal; starts the built-in server when needed")
        }
        .padding(.horizontal, 8)
    }

    private var statusColor: Color {
        if ollama.isRunning { return Theme.green }
        if ollama.state == .starting { return Theme.yellow }
        return Theme.textFaint
    }

    private var ollamaHelp: String {
        switch ollama.state {
        case .runningOwned: return "Stop the local Ollama server started by Hydra"
        case .runningExternal: return "Ollama is already running from another terminal or app"
        default: return "Run ollama serve locally on 127.0.0.1:\(OllamaPort); off until you click"
        }
    }
}
