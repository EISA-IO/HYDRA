# Hydra — macOS

A native SwiftUI app (v1, by Ahmed Al-Eissa) that mirrors the Windows Hydra:
launch and manage multiple Claude CLI or Codex CLI sessions, toggle the token-compression toolchain,
manage skills, scaffold a SaaS, and browse a CLI reference — all in one dark, native window.

## What's in it

Nav tabs (same as Windows): **Workspace · Settings · SaaS · Skills · Glossary**

- **Workspace** — the home tab. Pick **Claude** or **Codex**, then click **New** to launch a session that runs
  **inside the app as a tab** (a real embedded terminal via a PTY, powered by SwiftTerm).
  Open as many as you like and switch between them. Each tab shows live status
  (working / needs-you / idle) driven by per-session Claude hooks where available.
- **Settings** — launch defaults (model, Claude permissions, `--continue`, extra flags), the
  token-compression toggles (RTK / Caveman / Headroom) with live status + a "don't overlap"
  advisory, and a one-click **Install & setup** section (Node, Claude CLI, Codex CLI, RTK, Caveman,
  Headroom, skills, "Install everything", "Update core") that streams to a log.
  Selecting Codex switches the model selector to ChatGPT models, including **ChatGPT 5.6**,
  and Codex terminals always start in YOLO mode (`--dangerously-bypass-approvals-and-sandbox`).
- **SaaS** — capture a product vision, scaffold Open SaaS (Wasp), then hand it to Claude or
  ChatGPT to build. Generates `VISION.md` and a verified `PAYMENTS.md` (incl. the Tap vs Moyasar
  amount-unit gotcha for KSA).
- **Skills** — enable / disable / import / delete skills. The app mirrors enabled skills into
  `~/.claude/skills` and Codex/ChatGPT's `~/.agents/skills`.
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

- **PATH fix** — a Finder-launched `.app` inherits a bare PATH, so the app resolves your real
  login-shell PATH once (`$SHELL -lic 'echo $PATH'`) and injects it into every child process.
  That's why `claude`, `codex`, `node`, `rtk`, and `headroom` are found even when launched from Finder.
- **Embedded terminals** — macOS can't reparent Terminal.app windows the way Windows reparents
  conhost, so each session is a real terminal emulator (`LocalProcessTerminalView`) hosted in
  the SwiftUI window, running `zsh -l -c "cd <folder> && exec claude …"` or `codex …` in a PTY.
- **Codex compression** — RTK is installed into Codex global instructions with
  `rtk init -g --codex`; Caveman is installed from the bundled local Codex marketplace and a
  guarded `~/.codex/AGENTS.md` block is written so every Codex terminal starts terse.
- **State** lives in `~/.claude-manager/` (`settings.txt`, `recent.txt`, `sessions/`, `events/`) —
  the same layout as the Windows app.

## QA flags

`open -n "Hydra.app" --args --tab <0-4>` preselects a tab;
`--demoterm` auto-opens one embedded session (used for screenshots). Both are inert on a
normal double-click launch.
