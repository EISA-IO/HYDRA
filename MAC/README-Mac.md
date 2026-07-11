# Hydra — macOS

A native SwiftUI app (v1, by Ahmed Al-Eissa) that mirrors the Windows Hydra:
launch and manage multiple Claude CLI, Codex CLI, or Hermes Agent sessions, toggle the token-compression toolchain,
manage an optional local Ollama server, manage skills, scaffold a SaaS, and browse a CLI reference — all in one dark, native window.

## What's in it

Nav tabs (same as Windows): **Workspace · Settings · SaaS · Skills · Glossary · Ollama · MCP**

- **Workspace** — the home tab. Pick **Claude**, **Codex**, or **Hermes**, then click **New** to launch a session that runs
  **inside the app as a tab** (a real embedded terminal via a PTY, powered by SwiftTerm).
  Open as many as you like and switch between them. Each tab shows **Ready**, **Working**,
  **Waiting for User**, or **Stopped / Token Limit** as its primary second line. Per-session
  Claude and Codex lifecycle hooks update turn state and the actual runtime model; the model reads
  **Resolving model…** until reported, never “Default.” The tab title is a short prompt-derived task
  hint, or the project folder for an interactive session. PTY termination supplies the stopped fallback.
  Multiple Hermes tabs can run simultaneously with different backend/model/profile overrides.
- **Ollama sidebar controls** — local inference is off by default. **Start Ollama** launches the
  installed official CLI as `ollama serve` bound to `127.0.0.1:11434`; **Stop Ollama** appears only
  for a server Hydra started. A server launched from another terminal is detected and left under
  that terminal's control. **Open Ollama Terminal** creates an embedded PTY for server logs and
  commands. Release builds carry an architecture-matched runtime; Hydra also accepts PATH and
  standard macOS `Ollama.app` installations as compatibility fallbacks.
- **Settings** — four spaced, purpose-based pages: **Launch & agents**, **Memory & context**,
  **Compression**, and **System & updates**. Launch & agents exposes the Claude and Codex defaults
  side-by-side and maps a Hermes provider/account directly to its model ID. The memory page controls Claude auto-memory and
  `CLAUDE.md`, Codex memories/context/compaction and `AGENTS.md`, and Hermes memory plus compression.
  Launch defaults still include model, Claude permissions, `--continue`, extra flags, and the
  token-compression toggles (RTK / Caveman / Headroom) with live status + a "don't overlap"
  advisory, and a one-click **Install & setup** section (Node, Claude CLI, Codex CLI, Hermes, RTK, Caveman,
  Headroom, skills, "Install everything", "Update core", and a Claude + ChatGPT/Codex CLI
  update checker) that streams to a log.
  Selecting Codex switches the model selector to current Codex models, including **gpt-5.6-sol**,
  and Codex terminals always start in YOLO mode (`--dangerously-bypass-approvals-and-sandbox`).
  Hermes adds an editable model ID plus backends for ChatGPT/Codex OAuth, Claude/Anthropic,
  local Ollama, and OpenRouter. Its install, auth/model setup, update check, update, and doctor
  commands run in normal embedded terminals.
- **SaaS** — capture a product vision, scaffold Open SaaS (Wasp), then hand it to Claude or
  ChatGPT to build. Generates `VISION.md` and a verified `PAYMENTS.md` (incl. the Tap vs Moyasar
  amount-unit gotcha for KSA).
- **Skills** — enable / disable / import / delete shared skills. The app mirrors enabled skills into
  `~/.claude/skills` and Codex/ChatGPT's `~/.agents/skills`, and inventories native Hermes skills for
  the selected profile with direct `hermes skills` management actions.
- **MCP** — dedicated native inventories for Claude, Codex, and the selected Hermes profile, with
  refresh and manager/config actions.
- **Glossary** — searchable reference: slash commands, CLI flags, keyboard tips, and the
  RTK / Caveman / Headroom command sets.

## Build

Requires the Xcode Command Line Tools (`xcode-select --install`) — no full Xcode needed.

```bash
./build-mac.sh          # → "Hydra.app" (fetches SwiftTerm on first build)
open "Hydra.app"
```

Or just double-click **Hydra-Mac.command** — it builds the app on first run,
then launches it. If Swift isn't available it falls back to a lightweight folder/model picker.

## How it works (Mac specifics)

`build-mac.sh` creates the full offline app by default, bundling architecture-matched Node,
Claude Code, ChatGPT/Codex, Ollama, RTK, plugins, and skills. Hermes stays Hermes-managed and is
installed on demand through its official installer so future migrations and updates remain supported.
The app is intentionally large.
Hermes upstream currently lists Apple Silicon macOS as supported and Intel macOS as unsupported;
Hydra therefore skips the Hermes installer on Intel while still allowing an existing CLI to launch.
Use `HYDRA_THIN_BUILD=1 ./build-mac.sh` only for a developer build that may rely on tools
already installed on the Mac. Ollama model weights remain user-selected downloads.

- **PATH fix** — a Finder-launched `.app` inherits a bare PATH, so the app resolves your real
  login-shell PATH once (`$SHELL -lic 'echo $PATH'`) and injects it into every child process.
  That's why `claude`, `codex`, `hermes`, `node`, `rtk`, and `headroom` are found even when launched from Finder.
- **Embedded terminals** — macOS can't reparent Terminal.app windows the way Windows reparents
  conhost, so each session is a real terminal emulator (`LocalProcessTerminalView`) hosted in
  the SwiftUI window, running `zsh -l -c "cd <folder> && exec claude …"`, `codex …`, or `hermes …` in a PTY.
- **Hermes compatibility** — Hydra never rewrites `~/.hermes/config.yaml` or `.env` itself. It uses
  documented `hermes memory` / `hermes config set` controls, per-launch CLI overrides, `hermes model` for authentication/configuration, and
  `hermes update --backup` for lifecycle changes. New defaults affect new tabs only; already-running
  tabs keep their original process environment, and updates are blocked until Hermes tabs are closed.
- **Codex compression** — RTK is installed into Codex global instructions with
  `rtk init -g --codex`; Caveman is installed from the bundled local Codex marketplace and a
  guarded `~/.codex/AGENTS.md` block is written so every Codex terminal starts terse.
- **State** lives in `~/.claude-manager/` (`settings.txt`, `recent.txt`, `sessions/`, `events/`) —
  the same layout as the Windows app.

## QA flags

`open -n "Hydra.app" --args --tab <0-6>` preselects a tab;
`--demoterm` auto-opens one embedded session; `--demohermes` opens two independent Hermes
terminals for multi-tab QA. All flags are inert on a normal double-click launch.
