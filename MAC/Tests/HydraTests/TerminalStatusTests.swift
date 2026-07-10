import Foundation
import Testing
@testable import Hydra

@Suite("Terminal live status")
struct TerminalStatusTests {
    @Test("uses live state labels instead of task metadata")
    func visibleLabels() {
        #expect(TerminalStatus.ready.label == "Ready")
        #expect(TerminalStatus.working.label == "Working")
        #expect(TerminalStatus.waitingForUser.label == "Waiting for User")
        #expect(TerminalStatus.stoppedOrTokenLimit.label == "Stopped / Token Limit")
    }

    @Test("moves from ready to working when a prompt is submitted")
    func promptStartsWork() {
        #expect(TerminalStatus.ready.applying(event: "work") == .working)
    }

    @Test("moves from working to waiting when a turn completes")
    func completedTurnWaitsForUser() {
        #expect(TerminalStatus.working.applying(event: "stop") == .waitingForUser)
    }

    @Test("marks permission and idle notifications as waiting for user")
    func notificationWaitsForUser() {
        #expect(TerminalStatus.working.applying(event: "notify") == .waitingForUser)
    }

    @Test("marks API failure or process exit as stopped or token-limited")
    func failureStopsSession() {
        #expect(TerminalStatus.working.applying(event: "failure") == .stoppedOrTokenLimit)
        #expect(TerminalStatus.ready.applying(event: "exited") == .stoppedOrTokenLimit)
    }

    @Test("ignores unknown events without losing current state")
    func unknownEventKeepsState() {
        #expect(TerminalStatus.working.applying(event: "something-new") == .working)
    }

    @Test("does not revive a terminal after its process has stopped")
    func stoppedStateIsFinal() {
        #expect(TerminalStatus.stoppedOrTokenLimit.applying(event: "stop") == .stoppedOrTokenLimit)
        #expect(TerminalStatus.stoppedOrTokenLimit.applying(event: "work") == .stoppedOrTokenLimit)
    }

    @Test("Codex profile emits per-session lifecycle events")
    func codexProfileContainsLifecycleHooks() {
        let profile = SessionHookConfig.codexProfile(
            id: "session123",
            eventsDirectory: "/tmp/hydra events"
        )

        #expect(profile.contains("[[hooks.UserPromptSubmit]]"))
        #expect(profile.contains("session123__work__"))
        #expect(profile.contains("session123__work__'$(date +%s)_$RANDOM.evt"))
        #expect(profile.contains("[[hooks.PermissionRequest]]"))
        #expect(profile.contains("session123__notify__"))
        #expect(profile.contains("[[hooks.Stop]]"))
        #expect(profile.contains("session123__stop__"))
        #expect(profile.contains("printf '{}'") )
    }

    @Test("Claude settings emit working, waiting, completion, and failure events")
    func claudeHooksContainLifecycleEvents() throws {
        let hooks = SessionHookConfig.claudeHooks(
            id: "session123",
            eventsDirectory: "/tmp/hydra events"
        )
        let data = try JSONSerialization.data(withJSONObject: hooks, options: [.sortedKeys])
        let json = String(decoding: data, as: UTF8.self)

        #expect(json.contains("UserPromptSubmit"))
        #expect(json.contains("session123__work__"))
        #expect(json.contains("permission_prompt|idle_prompt|elicitation_dialog"))
        #expect(json.contains("session123__notify__"))
        #expect(json.contains("session123__stop__"))
        #expect(json.contains("StopFailure"))
        #expect(json.contains("session123__failure__"))
    }
}
