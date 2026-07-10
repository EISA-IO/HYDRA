import Testing
@testable import Hydra

@MainActor
@Suite("Ollama service")
struct OllamaServiceTests {
    @Test("starts disabled without launching Ollama")
    func initialStateIsStoppedAndDoesNotLaunchOllama() {
        var launches = 0
        let service = OllamaService(
            executable: { "/usr/local/bin/ollama" },
            serverReachable: { false },
            launch: { _, _ in launches += 1; return FakeOllamaProcess() }
        )

        #expect(service.state == .stopped)
        #expect(service.buttonTitle == "Start Ollama")
        #expect(launches == 0)
    }

    @Test("recognizes a server started outside Hydra")
    func refreshRecognizesServerStartedOutsideHydra() {
        let service = OllamaService(
            executable: { "/usr/local/bin/ollama" },
            serverReachable: { true },
            launch: { _, _ in Issue.record("External server must not be relaunched"); return FakeOllamaProcess() }
        )

        service.refresh()

        #expect(service.state == .runningExternal)
    }

    @Test("starts ollama serve and marks reachable process as Hydra-owned")
    func startLaunchesServeAndBecomesHydraOwnedWhenReachable() {
        var reachable = false
        var launchedExecutable: String?
        var launchedArguments: [String] = []
        let service = OllamaService(
            executable: { "/opt/homebrew/bin/ollama" },
            serverReachable: { reachable },
            launch: { executable, arguments in
                launchedExecutable = executable
                launchedArguments = arguments
                return FakeOllamaProcess()
            }
        )

        service.start()
        #expect(service.state == .starting)
        #expect(launchedExecutable == "/opt/homebrew/bin/ollama")
        #expect(launchedArguments == ["serve"])

        reachable = true
        service.refresh()
        #expect(service.state == .runningOwned)
        #expect(service.buttonTitle == "Stop Ollama")
    }

    @Test("reports missing Ollama without launching")
    func startReportsMissingInstallationWithoutLaunching() {
        var launches = 0
        let service = OllamaService(
            executable: { nil },
            serverReachable: { false },
            launch: { _, _ in launches += 1; return FakeOllamaProcess() }
        )

        service.start()

        #expect(service.state == .unavailable)
        #expect(launches == 0)
        #expect(service.errorMessage != nil)
    }

    @Test("stops only a server launched by Hydra")
    func stopTerminatesOnlyHydraOwnedServer() {
        let process = FakeOllamaProcess()
        var reachable = false
        let service = OllamaService(
            executable: { "/usr/local/bin/ollama" },
            serverReachable: { reachable },
            launch: { _, _ in process }
        )
        service.start()
        reachable = true
        service.refresh()

        service.stop()

        #expect(process.wasTerminated)
        #expect(service.state == .stopped)
    }

    @Test("does not stop a server launched outside Hydra")
    func stopDoesNotTerminateExternalServer() {
        let service = OllamaService(
            executable: { "/usr/local/bin/ollama" },
            serverReachable: { true },
            launch: { _, _ in Issue.record("External server must not be launched"); return FakeOllamaProcess() }
        )
        service.refresh()

        service.stop()

        #expect(service.state == .runningExternal)
        #expect(service.buttonTitle == "Ollama Running")
    }

    @Test("reports native process launch failures")
    func startReportsLaunchFailure() {
        let service = OllamaService(
            executable: { "/usr/local/bin/ollama" },
            serverReachable: { false },
            launch: { _, _ in throw FakeLaunchError.failed }
        )

        service.start()

        #expect(service.state == .failed)
        #expect(service.errorMessage?.contains("Could not start Ollama") == true)
    }

    @Test("reports an unexpected server exit")
    func unexpectedExitBecomesFailure() async {
        let process = FakeOllamaProcess()
        let service = OllamaService(
            executable: { "/usr/local/bin/ollama" },
            serverReachable: { false },
            launch: { _, _ in process }
        )
        service.start()

        process.exit()
        await Task.yield()

        #expect(service.state == .failed)
        #expect(service.errorMessage != nil)
    }

    @Test("builds a localhost-only serve command for an Ollama terminal")
    func terminalCommandStartsLocalServerWhenStopped() {
        let command = OllamaService.terminalCommand(
            executable: "/Applications/Ollama CLI/ollama",
            serverRunning: false
        )

        #expect(command == "OLLAMA_HOST='127.0.0.1:11434' '/Applications/Ollama CLI/ollama' serve")
    }

    @Test("builds a management command when a server already runs")
    func terminalCommandUsesExistingServer() {
        let command = OllamaService.terminalCommand(
            executable: "/usr/local/bin/ollama",
            serverRunning: true
        )

        #expect(command == "'/usr/local/bin/ollama' ps")
    }
}

private final class FakeOllamaProcess: OllamaProcess {
    var isRunning = true
    private var terminationHandler: (() -> Void)?
    private(set) var wasTerminated = false

    func setTerminationHandler(_ handler: @escaping () -> Void) {
        terminationHandler = handler
    }

    func terminate() {
        wasTerminated = true
        exit()
    }

    func exit() {
        isRunning = false
        terminationHandler?()
    }
}

private enum FakeLaunchError: Error {
    case failed
}
