import Foundation
import Combine

let OllamaPort = 11434

enum OllamaState: Equatable {
    case stopped
    case unavailable
    case starting
    case runningOwned
    case runningExternal
    case failed
}

protocol OllamaProcess: AnyObject {
    var isRunning: Bool { get }
    func setTerminationHandler(_ handler: @escaping () -> Void)
    func terminate()
}

private final class NativeOllamaProcess: OllamaProcess {
    private let process: Process

    init(executable: String, arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = Shell.shared.path
        for (key, value) in OllamaService.serverEnvironment(executable: executable) {
            environment[key] = value
        }
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        process.terminationHandler = { _ in handler() }
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

// A reachable server Hydra didn't start is usually Hydra's own embedded runtime left
// over from a previous session (or booted inside an embedded terminal). Wrapping its
// pid lets Stop and app-shutdown own it again; a genuinely foreign install (PATH,
// Ollama.app) is never adopted or killed.
private final class AdoptedOllamaProcess: OllamaProcess {
    private let pid: pid_t
    init(pid: pid_t) { self.pid = pid }
    var isRunning: Bool { kill(pid, 0) == 0 }
    func setTerminationHandler(_ handler: @escaping () -> Void) {}   // refresh() polls instead
    func terminate() { kill(pid, SIGTERM) }
}

final class OllamaService: ObservableObject {
    @Published private(set) var state: OllamaState = .stopped
    @Published private(set) var errorMessage: String?

    private let executable: () -> String?
    private let serverReachable: () -> Bool
    private let launch: (String, [String]) throws -> OllamaProcess
    private let adopt: () -> OllamaProcess?
    private var process: OllamaProcess?

    init(
        executable: @escaping () -> String? = { OllamaService.installedExecutable() },
        serverReachable: @escaping () -> Bool = { AppState.portOpen(OllamaPort) },
        launch: @escaping (String, [String]) throws -> OllamaProcess = {
            try NativeOllamaProcess(executable: $0, arguments: $1)
        },
        adopt: @escaping () -> OllamaProcess? = {
            OllamaService.embeddedServerPid().map { AdoptedOllamaProcess(pid: $0) }
        }
    ) {
        self.executable = executable
        self.serverReachable = serverReachable
        self.launch = launch
        self.adopt = adopt
    }

    /// Pid of a running `ollama` that belongs to Hydra's own runtime (managed dir or
    /// app bundle) — the only kind of "external" server Hydra is allowed to reclaim.
    static func embeddedServerPid() -> pid_t? {
        var markers = [Paths.ollamaDir + "/ollama"]
        if let resources = Bundle.main.resourcePath {
            markers.append(resources + "/runtime/ollama/ollama")
        }
        for marker in markers {
            let result = Shell.shared.run("pgrep", ["-f", marker], timeout: 5)
            for line in result.out.split(separator: "\n") {
                if let pid = Int32(line.trimmingCharacters(in: .whitespaces)), pid > 0 { return pid_t(pid) }
            }
        }
        return nil
    }

    static func installedExecutable() -> String? {
        // Hydra's built-in runtime wins; PATH/system copies are only a compatibility fallback.
        let bundled = (Bundle.main.resourcePath ?? "") + "/runtime/ollama/ollama"
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        if FileManager.default.isExecutableFile(atPath: Paths.ollamaExe) { return Paths.ollamaExe }
        if let executable = Shell.shared.which("ollama") { return executable }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appExecutables = [
            "/Applications/Ollama.app/Contents/Resources/ollama",
            home + "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        return appExecutables.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func isEmbedded(_ executable: String) -> Bool {
        executable.hasPrefix(Paths.ollamaDir + "/") || executable.contains("/Hydra.app/Contents/Resources/runtime/ollama/")
    }

    // Context window the built-in server starts with (persisted like the classic
    // OLLAMA MANAGER's context_size.cfg; changing it restarts the owned server).
    static func contextLength() -> Int {
        if let s = try? String(contentsOfFile: Paths.ollamaCtxFile, encoding: .utf8),
           let v = Int(s.trimmingCharacters(in: .whitespacesAndNewlines)), v > 0 { return v }
        return 8192
    }

    static func saveContextLength(_ v: Int) {
        try? FileManager.default.createDirectory(atPath: Paths.ollamaDir, withIntermediateDirectories: true)
        try? String(v).write(toFile: Paths.ollamaCtxFile, atomically: true, encoding: .utf8)
    }

    /// Persisted context window, warm keep-alive, single queue. Correctness note:
    /// OLLAMA_KV_CACHE_TYPE=q8_0 + OLLAMA_FLASH_ATTENTION=1 corrupt long generations
    /// on several model architectures (duplicated/mangled fragments — seen live with
    /// ornith:9b under Hermes), so both stay at Ollama's f16 defaults. Costs VRAM,
    /// buys correct output. The built-in runtime also keeps its models in Hydra's dir.
    static func serverEnvironment(executable: String) -> [String: String] {
        var env: [String: String] = [
            "OLLAMA_HOST": "127.0.0.1:\(OllamaPort)",
            // Open to every local app: localhost-bound (nothing from the network can
            // reach it) but any app or web origin on THIS machine may call it.
            "OLLAMA_ORIGINS": "*",
            "OLLAMA_NUM_CTX": String(contextLength()),
            "OLLAMA_KEEP_ALIVE": "30m",
            "OLLAMA_NUM_PARALLEL": "1"
        ]
        if isEmbedded(executable) {
            try? FileManager.default.createDirectory(atPath: Paths.ollamaModelsDir, withIntermediateDirectories: true)
            env["OLLAMA_MODELS"] = Paths.ollamaModelsDir
        }
        return env
    }

    /// Shell prefix exporting the same environment (for terminal-based commands).
    static func shellEnvPrefix(executable: String) -> String {
        serverEnvironment(executable: executable)
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(TerminalLauncher.shellQuote($0.value))" }
            .joined(separator: " ")
    }

    static func terminalCommand(executable: String, serverRunning: Bool) -> String {
        let quoted = TerminalLauncher.shellQuote(executable)
        if serverRunning { return quoted + " ps" }
        // The built-in runtime serves with the full tuned environment; external copies
        // keep the minimal localhost pin (their config is the user's business).
        if isEmbedded(executable) { return "\(shellEnvPrefix(executable: executable)) \(quoted) serve" }
        return "OLLAMA_HOST=\(TerminalLauncher.shellQuote("127.0.0.1:\(OllamaPort)")) \(quoted) serve"
    }

    var buttonTitle: String {
        switch state {
        case .starting: return "Starting Ollama…"
        case .runningOwned: return "Stop Ollama"
        case .runningExternal: return "Ollama Running"
        default: return "Start Ollama"
        }
    }

    var statusText: String {
        switch state {
        case .stopped: return "Local server off"
        case .unavailable: return "Ollama not installed"
        case .starting: return "Starting local server"
        case .runningOwned: return "Local server running"
        case .runningExternal: return "Running outside Hydra"
        case .failed: return "Server failed"
        }
    }

    var isRunning: Bool { state == .runningOwned || state == .runningExternal }
    var buttonDisabled: Bool { state == .starting || state == .runningExternal }

    func refresh() {
        if serverReachable() {
            errorMessage = nil
            if process?.isRunning == true {
                state = .runningOwned
            } else if let reclaimed = adopt() {
                process = reclaimed          // Hydra's own runtime — own it again
                state = .runningOwned
            } else {
                state = .runningExternal
            }
            return
        }

        if process?.isRunning == true {
            state = .starting
            return
        }

        process = nil
        switch state {
        case .failed:
            break
        case .unavailable where executable() == nil:
            break
        default:
            errorMessage = nil
            state = .stopped
        }
    }

    func start() {
        if serverReachable() {
            errorMessage = nil
            state = .runningExternal
            return
        }
        guard process?.isRunning != true else { return }
        guard let executable = executable() else {
            errorMessage = "Ollama isn't built into Hydra yet. Use Settings → \"Install everything\" (or its Ollama button) to add the built-in runtime — nothing is installed system-wide."
            state = .unavailable
            return
        }

        do {
            let launched = try launch(executable, ["serve"])
            process = launched
            errorMessage = nil
            state = .starting
            launched.setTerminationHandler { [weak self, weak launched] in
                DispatchQueue.main.async { [weak self, weak launched] in
                    guard let launched else { return }
                    self?.processDidTerminate(launched)
                }
            }
        } catch {
            process = nil
            errorMessage = "Could not start Ollama: \(error.localizedDescription)"
            state = .failed
        }
    }

    func stop() {
        guard state == .starting || state == .runningOwned, let process else { return }
        self.process = nil
        errorMessage = nil
        state = .stopped
        process.terminate()
    }

    func shutdown() {
        stop()
        // Belt and braces: no process from Hydra's own runtime dir may outlive the
        // app — Ollama runs strictly as part of Hydra. Foreign installs untouched.
        _ = Shell.shared.run("pkill", ["-f", Paths.ollamaDir + "/"], timeout: 5)
    }

    private func processDidTerminate(_ terminated: OllamaProcess) {
        guard process === terminated else { return }
        process = nil
        if serverReachable() {
            errorMessage = nil
            state = .runningExternal
        } else {
            errorMessage = "Ollama server exited before Hydra stopped it."
            state = .failed
        }
    }
}
