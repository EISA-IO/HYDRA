import Foundation

enum Glossary {
    static let all: [GlossaryEntry] = {
        var g: [GlossaryEntry] = []
        func add(_ c: String, _ t: String, _ d: String) { g.append(GlossaryEntry(category: c, term: t, desc: d)) }

        let S = "Slash commands (in session)"
        add(S, "/help", "List all commands and shortcuts.")
        add(S, "/clear", "Clear the conversation and free up context.")
        add(S, "/compact", "Summarize & compress the conversation to save context.")
        add(S, "/config", "Open settings (theme, model, editor, verbosity).")
        add(S, "/model", "Switch the model for this session (Opus / Sonnet / Haiku).")
        add(S, "/agents", "Create and manage custom subagents.")
        add(S, "/mcp", "Manage MCP servers and inspect their tools.")
        add(S, "/init", "Generate a CLAUDE.md documenting the codebase.")
        add(S, "/memory", "View/edit memory files. Tip: start a line with # to save a memory.")
        add(S, "/permissions", "View or edit tool permission rules.")
        add(S, "/review", "Review a pull request.")
        add(S, "/security-review", "Scan current changes for vulnerabilities.")
        add(S, "/loop", "Run a prompt/command on a repeat, e.g. /loop 5m /babysit-prs. Omit interval to self-pace.")
        add(S, "/goal", "Set a goal; a Stop hook keeps the session working until the condition is met.")
        add(S, "/vim", "Toggle vim keybindings in the prompt editor.")
        add(S, "/fast", "Toggle Fast mode (faster Opus output; Opus 4.7/4.8).")
        add(S, "/resume", "Resume a previous conversation/session.")
        add(S, "/status", "Show account, model, and connection status.")
        add(S, "/cost", "Show token usage and cost for the session.")
        add(S, "/doctor", "Diagnose installation and health issues.")
        add(S, "/login  •  /logout", "Sign in / switch account, or sign out.")
        add(S, "/terminal-setup", "Enable Shift+Enter for newlines and other keybindings.")
        add(S, "/bug", "Report a bug to Anthropic.")
        add(S, "/<skill-name>", "Invoke an installed skill, e.g. /stop-slop, /code-review, /verify.")

        let F = "CLI flags (at startup)"
        add(F, "claude", "Start an interactive session in the current folder.")
        add(F, "-p, --print \"...\"", "Run once, print the result, and exit (great for scripting).")
        add(F, "-c, --continue", "Continue the most recent conversation.")
        add(F, "--resume", "Pick a past session to resume.")
        add(F, "--model <alias|id>", "Choose the model: opus / sonnet / haiku, or a full id.")
        add(F, "--dangerously-skip-permissions", "Bypass ALL permission prompts. Fast, but runs anything without asking.")
        add(F, "--permission-mode <mode>", "default | plan | acceptEdits | bypassPermissions.")
        add(F, "--effort <level>", "Set reasoning effort for the session.")
        add(F, "--agent <name>", "Start with a specific subagent.")
        add(F, "--add-dir <dirs...>", "Allow tools to access extra directories.")
        add(F, "--mcp-config <files...>", "Load MCP servers from JSON config files.")
        add(F, "--ide", "Auto-connect to your IDE on startup.")
        add(F, "--bg, --background", "Start as a background agent.")
        add(F, "--debug", "Enable debug logging.")
        add(F, "--append-system-prompt \"...\"", "Append text to the default system prompt.")

        let X = "Codex CLI"
        add(X, "codex", "Start an interactive ChatGPT/Codex coding session in the current folder.")
        add(X, "codex -C <dir>", "Start Codex with an explicit working root. Hydra uses this for every Codex terminal.")
        add(X, "--model <id>", "Choose a Codex model, e.g. gpt-5.6-sol, gpt-5.6-terra, or gpt-5.6-luna.")
        add(X, "--dangerously-bypass-approvals-and-sandbox", "YOLO mode: no approvals and no sandbox. Hydra starts Codex terminals this way.")
        add(X, "--ask-for-approval <policy>", "Approval policy for Codex when not using YOLO: untrusted, on-request, or never.")
        add(X, "--sandbox <mode>", "Codex sandbox mode: read-only, workspace-write, or danger-full-access.")
        add(X, "resume --last", "Resume the most recent Codex conversation.")
        add(X, "codex plugin list", "Show installed Codex plugins and their enabled/installed status.")
        add(X, "codex plugin marketplace add <path>", "Register a local Codex plugin marketplace, like the bundled Caveman marketplace.")
        add(X, "codex plugin add caveman@caveman", "Install Caveman from the local marketplace for Codex sessions.")
        add(X, "~/.codex/AGENTS.md", "Global Codex instructions. Hydra writes RTK/Caveman guidance here.")
        add(X, "~/.agents/skills", "Codex/ChatGPT user skills folder. Hydra mirrors bundled/imported skills here.")
        add(X, "rtk init -g --codex", "Install RTK guidance for Codex so shell commands use token-filtered rtk output.")
        add(X, "CODEX_HOME", "Points Codex at its config/state directory; Hydra sets it to ~/.codex.")

        let K = "Keyboard & prompt tips"
        add(K, "Esc", "Interrupt Claude / cancel the current action.")
        add(K, "Esc  Esc", "Rewind — edit a previous message and branch.")
        add(K, "Shift+Tab", "Cycle permission mode (auto-accept edits / plan mode).")
        add(K, "Shift+Enter", "Insert a newline (after running /terminal-setup).")
        add(K, "#  <text>", "Save a memory for future sessions.")
        add(K, "!  <command>", "Run a shell command directly (bash mode).")
        add(K, "@  <path>", "Reference/attach a file or folder in your prompt.")
        add(K, "Ctrl+V", "Paste an image into the prompt.")
        add(K, "Up arrow", "Cycle through previous prompt history.")

        let M = "Hydra (this app)"
        add(M, "⌘1 … ⌘5", "Switch tabs (Launch / Skills / SaaS / Glossary / Setup).")
        add(M, "⌘L", "Launch a new Claude session in the chosen folder.")
        add(M, "⌘, ", "Focus the folder field.")
        add(M, "Recents", "Double-click a recent folder to launch straight into it.")

        let H = "Headroom (token compression)"
        add(H, "headroom proxy", "Start the compression proxy on port 8787.")
        add(H, "headroom mcp install", "Register Headroom as an MCP server for Claude.")
        add(H, "headroom wrap claude", "Durably route Claude Code through Headroom.")
        add(H, "headroom savings", "Show measured token savings over time.")
        add(H, "headroom dashboard", "Open the savings dashboard in your browser.")
        add(H, "ANTHROPIC_BASE_URL", "Point Claude at the proxy: http://127.0.0.1:8787 (this app sets it for you).")

        let R = "RTK (input compression)"
        add(R, "What it is", "A Rust CLI + PreToolUse hook that rewrites shell commands (git status → rtk git status) and filters their output — 60-90% fewer INPUT tokens. Only affects Bash tool calls, not Read/Grep/Glob.")
        add(R, "rtk init -g", "Install the auto-rewrite hook for Claude Code (this app's toggle does it for you).")
        add(R, "rtk gain", "Show measured token savings + USD; add --graph / --daily / --history.")
        add(R, "rtk discover", "Find missed savings opportunities in recent sessions.")
        add(R, "rtk ls / read / grep / diff", "Token-optimized file & search commands you can call directly.")
        add(R, "rtk test <cmd>", "Run any test command, keep failures only (~90% smaller).")
        add(R, "rtk init -g --uninstall", "Remove the hook (this app's toggle does it for you).")

        let C = "Caveman (output compression)"
        add(C, "What it is", "A plugin that makes Claude reply in terse 'caveman' style — ~65% fewer OUTPUT tokens, full accuracy. Complements Headroom/RTK (which compress INPUT).")
        add(C, "/caveman [lite|full|ultra|wenyan]", "Turn on caveman speak for the session; pick how terse. Say 'normal mode' to stop.")
        add(C, "/caveman-commit", "Write a Conventional Commit message, ≤50 char subject.")
        add(C, "/caveman-review", "One-line PR review comments, e.g. L42: bug: user null. Add guard.")
        add(C, "/caveman-stats", "Show real token savings this session + lifetime + USD.")
        add(C, "/caveman-compress <file>", "Rewrite a memory file (e.g. CLAUDE.md) into caveman-speak to save input tokens every session.")
        add(C, "Install / Remove", "Toggle it in Settings, or run: npx -y github:JuliusBrussee/caveman --only claude --only codex")

        return g
    }()
}
