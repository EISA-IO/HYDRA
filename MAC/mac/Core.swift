import SwiftUI
import AppKit

// ============================================================================
// Theme — dark "liquid glass" palette, matched to the Windows Hydra.
// ============================================================================
enum Theme {
    static let bg        = Color(nsColor: NSColor(srgbRed: 22/255,  green: 22/255,  blue: 25/255,  alpha: 1))
    static let titleBg   = Color(nsColor: NSColor(srgbRed: 16/255,  green: 16/255,  blue: 18/255,  alpha: 1))
    static let card      = Color(nsColor: NSColor(srgbRed: 31/255,  green: 31/255,  blue: 37/255,  alpha: 1))
    static let field     = Color(nsColor: NSColor(srgbRed: 43/255,  green: 43/255,  blue: 51/255,  alpha: 1))
    static let fieldHi   = Color(nsColor: NSColor(srgbRed: 58/255,  green: 58/255,  blue: 68/255,  alpha: 1))
    static let panel2    = Color(nsColor: NSColor(srgbRed: 40/255,  green: 40/255,  blue: 45/255,  alpha: 1))
    static let accent    = Color(nsColor: NSColor(srgbRed: 217/255, green: 119/255, blue: 87/255,  alpha: 1))
    static let accentHi  = Color(nsColor: NSColor(srgbRed: 232/255, green: 140/255, blue: 110/255, alpha: 1))
    static let textDim   = Color(nsColor: NSColor(srgbRed: 165/255, green: 165/255, blue: 175/255, alpha: 1))
    static let textFaint = Color(nsColor: NSColor(srgbRed: 130/255, green: 130/255, blue: 140/255, alpha: 1))
    static let green     = Color(nsColor: NSColor(srgbRed: 120/255, green: 200/255, blue: 120/255, alpha: 1))
    static let yellow    = Color(nsColor: NSColor(srgbRed: 210/255, green: 185/255, blue: 110/255, alpha: 1))
}

// ============================================================================
// Paths — mirror the Windows manager's state layout so the two stay in sync.
// ============================================================================
enum Paths {
    static let home        = FileManager.default.homeDirectoryForCurrentUser.path
    static let stateDir    = home + "/.claude-manager"
    static let managedBin  = stateDir + "/bin"   // native toolchain the app provisions (on PATH)
    static let recentFile  = stateDir + "/recent.txt"
    static let settingsFile = stateDir + "/settings.txt"
    static let eventsDir    = stateDir + "/events"
    static let sessDir      = stateDir + "/sessions"
    static let skillsDir    = home + "/.claude/skills"
    static let disabledDir  = home + "/.claude/skills-disabled"
    static let codexSkillsDir = home + "/.agents/skills"
    static let codexDisabledDir = home + "/.agents/skills-disabled"
    static let pluginsFile  = home + "/.claude/plugins/installed_plugins.json"
    static let claudeSettings = home + "/.claude/settings.json"
    static let claudeJson   = home + "/.claude.json"
    static let codexDir     = (ProcessInfo.processInfo.environment["CODEX_HOME"]?.isEmpty == false)
        ? ProcessInfo.processInfo.environment["CODEX_HOME"]!
        : home + "/.codex"
    static let codexAgents  = codexDir + "/AGENTS.md"
    static let codexRtk     = codexDir + "/RTK.md"
    // Ollama is built into Hydra: a portable runtime (no installer, no login item,
    // no system service) in Hydra's own state dir, with models kept alongside it.
    static let ollamaDir       = stateDir + "/ollama"
    static let ollamaExe       = stateDir + "/ollama/ollama"
    static let ollamaModelsDir = stateDir + "/ollama/models"
    static let ollamaCtxFile   = stateDir + "/ollama/context_size.cfg"
    static let ollamaRecFile   = stateDir + "/ollama/recommended_models.txt"

    static func ensureDirs() {
        for d in [stateDir, eventsDir, sessDir, codexDir, codexSkillsDir] {
            try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
    }
}

// ============================================================================
// Shell — the crux of "runs perfectly on Mac": a Finder-launched .app inherits
// a bare PATH, so Claude / node / rtk / headroom are invisible. We resolve the
// user's real login-shell PATH once and inject it into every child process.
// ============================================================================
struct RunResult { let code: Int32; let out: String; let err: String }

final class Shell {
    static let shared = Shell()

    /// The user's real interactive PATH, plus the usual install locations as a safety net.
    let path: String

    private init() {
        var resolved = ""
        // Ask the login shell what PATH the user actually has (homebrew, nvm, ~/.local/bin…).
        let userShell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: userShell)
        p.arguments = ["-lic", "echo __CMPATH__:$PATH"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let s = String(data: data, encoding: .utf8) {
                for line in s.split(separator: "\n") {
                    if let r = line.range(of: "__CMPATH__:") {
                        resolved = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
            }
        } catch { }

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var parts = resolved.split(separator: ":").map(String.init)
        // The app's OWN managed bin comes FIRST so the natively-bundled tools (rtk, and any
        // vendored claude/headroom) always resolve — even on a machine where the user has
        // installed nothing. This is what makes Hydra self-dependent.
        let managed = home + "/.claude-manager/bin"
        parts.removeAll { $0 == managed }
        parts.insert(managed, at: 0)
        // Always include the standard install locations even if they don't exist yet — an
        // installer (Node pkg, RTK, npm -g) may create them mid-session, and the next step
        // must be able to find the freshly-installed binary.
        let extras = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin",
            "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            home + "/.local/bin", home + "/.npm-global/bin", home + "/bin",
            home + "/.bun/bin", home + "/.deno/bin"
        ]
        for e in extras where !parts.contains(e) { parts.append(e) }
        self.path = parts.joined(separator: ":")
    }

    private func childEnv(extra: [String: String] = [:]) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = path
        for (k, v) in extra { env[k] = v }
        return env
    }

    /// Locate an executable on the resolved PATH (like `which`, but honoring our PATH).
    func which(_ exe: String) -> String? {
        for dir in path.split(separator: ":") {
            let full = String(dir) + "/" + exe
            if FileManager.default.isExecutableFile(atPath: full) { return full }
        }
        return nil
    }

    func onPath(_ exe: String) -> Bool { which(exe) != nil }

    /// Run a program synchronously, capturing output. Resolves via PATH if `exe` is bare.
    @discardableResult
    func run(_ exe: String, _ args: [String], cwd: String? = nil, env: [String: String] = [:], timeout: TimeInterval = 180) -> RunResult {
        let resolved = exe.contains("/") ? exe : (which(exe) ?? exe)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: resolved)
        p.arguments = args
        p.environment = childEnv(extra: env)
        if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        var outData = Data(); var errData = Data()
        let q = DispatchQueue(label: "shell.read", attributes: .concurrent)
        let g = DispatchGroup()
        g.enter(); q.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        g.enter(); q.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); g.leave() }
        do { try p.run() } catch {
            return RunResult(code: -1, out: "", err: error.localizedDescription)
        }
        let deadline = DispatchTime.now() + timeout
        while p.isRunning && DispatchTime.now() < deadline { usleep(50_000) }
        if p.isRunning { p.terminate() }
        p.waitUntilExit()
        g.wait()
        return RunResult(code: p.terminationStatus,
                         out: String(data: outData, encoding: .utf8) ?? "",
                         err: String(data: errData, encoding: .utf8) ?? "")
    }

    /// Run a shell one-liner through the login shell (so pipes / npx / curl work).
    @discardableResult
    func bash(_ command: String, cwd: String? = nil, env: [String: String] = [:], timeout: TimeInterval = 600) -> RunResult {
        run("/bin/zsh", ["-lc", command], cwd: cwd, env: env, timeout: timeout)
    }

    /// Stream a login-shell command line-by-line to `onLine`, then call `done` with the exit code.
    func stream(_ command: String, cwd: String? = nil, env: [String: String] = [:], onLine: @escaping (String) -> Void, done: @escaping (Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", command]
            p.environment = self.childEnv(extra: env)
            if let cwd = cwd { p.currentDirectoryURL = URL(fileURLWithPath: cwd) }
            let pipe = Pipe()
            p.standardOutput = pipe; p.standardError = pipe
            let handle = pipe.fileHandleForReading
            var buffer = Data()
            handle.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { return }
                buffer.append(d)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    let line = String(data: lineData, encoding: .utf8) ?? ""
                    DispatchQueue.main.async { onLine(line) }
                }
            }
            do { try p.run() } catch {
                DispatchQueue.main.async { onLine("ERR " + error.localizedDescription); done(-1) }
                return
            }
            p.waitUntilExit()
            handle.readabilityHandler = nil
            if !buffer.isEmpty, let tail = String(data: buffer, encoding: .utf8), !tail.isEmpty {
                DispatchQueue.main.async { onLine(tail) }
            }
            DispatchQueue.main.async { done(p.terminationStatus) }
        }
    }
}

// ============================================================================
// Terminal — open a real Terminal.app (or iTerm2) tab running a command in a
// folder. This is the native Mac analogue of the Windows embedded conhost tab.
// ============================================================================
enum TerminalLauncher {
    static func usesITerm() -> Bool { FileManager.default.fileExists(atPath: "/Applications/iTerm.app") }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
    private static func osaEsc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Open a titled Claude session in a native terminal window/tab. `title` lets us
    /// later Focus or Close exactly this session from the app.
    static func open(command: String, cwd: String, title: String) {
        let full = "cd \(shellQuote(cwd)) && clear && \(command)"
        runOSA(usesITerm() ? itermOpen(full, title) : terminalOpen(full, title))
    }
    // Back-compat convenience for one-off launches that don't need tracking.
    static func open(command: String, cwd: String) {
        open(command: command, cwd: cwd, title: "Claude")
    }

    static func focus(title: String) { runOSA(usesITerm() ? itermFocus(title) : terminalFocus(title)) }
    static func close(title: String) { runOSA(usesITerm() ? itermClose(title) : terminalClose(title)) }

    // ---- Terminal.app: each session is a new window we title; no accessibility needed ----
    private static func terminalOpen(_ cmd: String, _ title: String) -> String {
        """
        tell application "Terminal"
          activate
          set t to do script "\(osaEsc(cmd))"
          set custom title of t to "\(osaEsc(title))"
        end tell
        """
    }
    private static func terminalFocus(_ title: String) -> String {
        """
        tell application "Terminal"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              try
                if custom title of t is "\(osaEsc(title))" then
                  set index of w to 1
                  set selected of t to true
                  return
                end if
              end try
            end repeat
          end repeat
        end tell
        """
    }
    private static func terminalClose(_ title: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              try
                if custom title of t is "\(osaEsc(title))" then
                  close w saving no
                  return
                end if
              end try
            end repeat
          end repeat
        end tell
        """
    }

    // ---- iTerm2: native tabs via its own API (no accessibility needed) ----
    private static func itermOpen(_ cmd: String, _ title: String) -> String {
        """
        tell application "iTerm"
          activate
          if (count of windows) is 0 then
            set w to (create window with default profile)
          else
            set w to current window
            tell w to create tab with default profile
          end if
          tell current session of current tab of w
            set name to "\(osaEsc(title))"
            write text "\(osaEsc(cmd))"
          end tell
        end tell
        """
    }
    private static func itermFocus(_ title: String) -> String {
        """
        tell application "iTerm"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if name of s contains "\(osaEsc(title))" then
                  select w
                  tell w to select t
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
    }
    private static func itermClose(_ title: String) -> String {
        """
        tell application "iTerm"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if name of s contains "\(osaEsc(title))" then
                  close t
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
    }

    private static func runOSA(_ script: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            try? p.run()
            p.waitUntilExit()
        }
    }
}

// ============================================================================
// Small helpers
// ============================================================================
enum FS {
    static func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    static func write(_ path: String, _ content: String) {
        try? content.write(toFile: path, atomically: true, encoding: .utf8)
    }
    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    static func isDir(_ path: String) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &d) && d.boolValue
    }
    static func dirs(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path))?
            .map { path + "/" + $0 }
            .filter { isDir($0) }
            .sorted() ?? []
    }
    static func base(_ path: String) -> String { (path as NSString).lastPathComponent }
    static func copyDir(_ src: String, _ dst: String) throws {
        if exists(dst) { try FileManager.default.removeItem(atPath: dst) }
        try FileManager.default.copyItem(atPath: src, toPath: dst)
    }
}

func chooseFolder(prompt: String, start: String? = nil) -> String? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose"
    panel.message = prompt
    if let start = start, FS.isDir(start) { panel.directoryURL = URL(fileURLWithPath: start) }
    return panel.runModal() == .OK ? panel.url?.path : nil
}
