import Testing
@testable import Hydra

@Test("CLI version parser accepts Claude and Codex output")
func parsesCLIVersions() {
    #expect(CLIVersion.parse("2.1.7 (Claude Code)") == CLIVersion(2, 1, 7))
    #expect(CLIVersion.parse("codex-cli 0.42.0") == CLIVersion(0, 42, 0))
}

@Test("CLI update comparison detects newer registry releases")
func detectsCLIUpdates() {
    #expect(CLIVersion.updateAvailable(installed: "2.1.7 (Claude Code)", latest: "2.2.0"))
    #expect(!CLIVersion.updateAvailable(installed: "codex-cli 1.4.0", latest: "1.4.0"))
    #expect(!CLIVersion.updateAvailable(installed: "not installed", latest: "1.4.0"))
}
