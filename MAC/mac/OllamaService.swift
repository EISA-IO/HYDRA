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
        environment["OLLAMA_HOST"] = "127.0.0.1:\(OllamaPort)"
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

final class OllamaService: ObservableObject {
    @Published private(set) var state: OllamaState = .stopped
    @Published private(set) var errorMessage: String?

    private let executable: () -> String?
    private let serverReachable: () -> Bool
    private let launch: (String, [String]) throws -> OllamaProcess
    private var process: OllamaProcess?

    init(
        executable: @escaping () -> String? = { OllamaService.installedExecutable() },
        serverReachable: @escaping () -> Bool = { AppState.portOpen(OllamaPort) },
        launch: @escaping (String, [String]) throws -> OllamaProcess = {
            try NativeOllamaProcess(executable: $0, arguments: $1)
        }
    ) {
        self.executable = executable
        self.serverReachable = serverReachable
        self.launch = launch
    }

    static func installedExecutable() -> String? {
        if let executable = Shell.shared.which("ollama") { return executable }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appExecutables = [
            "/Applications/Ollama.app/Contents/Resources/ollama",
            home + "/Applications/Ollama.app/Contents/Resources/ollama"
        ]
        return appExecutables.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func terminalCommand(executable: String, serverRunning: Bool) -> String {
        let executable = TerminalLauncher.shellQuote(executable)
        if serverRunning { return executable + " ps" }
        return "OLLAMA_HOST=\(TerminalLauncher.shellQuote("127.0.0.1:\(OllamaPort)")) \(executable) serve"
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
            state = process?.isRunning == true ? .runningOwned : .runningExternal
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
            errorMessage = "Install Ollama from ollama.com, then try again. Hydra never installs or starts it without your action."
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
