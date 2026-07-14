# Hydra  ·  by Ahmed Al-Eissa

[![Windows](https://img.shields.io/badge/Windows-offline_x64-0078D6?logo=windows&logoColor=white)](https://github.com/EISA-IO/HYDRA/releases)
[![macOS](https://img.shields.io/badge/macOS-offline_arm64_%7C_x64-000000?logo=apple&logoColor=white)](https://github.com/EISA-IO/HYDRA/releases/latest)
[![Release](https://img.shields.io/github/v/release/EISA-IO/HYDRA?color=D97757)](https://github.com/EISA-IO/HYDRA/releases/latest)

## Download

| Platform | Download | Run |
|---|---|---|
| **Windows 10/11 x64** | `Hydra-Windows-x64-SelfContained.exe` + `Hydra-Windows-x64-Ollama-Offline-Pack.zip` | keep both files together, then double-click the EXE |
| **macOS 14+ Apple Silicon** | `Hydra-macOS-arm64-SelfContained.zip` | unzip → right-click **Hydra.app** → Open |
| **macOS 14+ Intel** | `Hydra-macOS-x64-SelfContained.zip` | unzip → right-click **Hydra.app** → Open |

Get the named assets from the [GitHub Releases page](https://github.com/EISA-IO/HYDRA/releases)
and verify each adjacent `.sha256` file. Self-contained assets are published only from an
approved v1.1+ tag; older v1.0 assets are thin launchers and do not satisfy the offline-install
contract.
The Windows Ollama pack is separate only to stay below GitHub's per-file release
limit; Hydra verifies its SHA-256 and extracts it locally on first launch.

A launcher + toolchain manager for Claude Code, Codex CLI, Hermes Agent, and a natively built-in Ollama, with an embedded multi-terminal
Workspace, a token-compression toolchain (RTK + Caveman + Headroom), Claude Video `/watch`,
Addy Osmani's Agent Skills, and a bundled skills library,
dedicated memory/context and MCP control centers, and a guided **Build a SaaS** lifecycle (Vision → Deploy → Subscriptions).

## Repository layout

```
HYDRA/
├── MAC/              — the native macOS app (SwiftUI, built with Swift Package Manager)
│   ├── mac/          — Swift sources
│   ├── Package.swift, Package.resolved
│   ├── build-mac.sh              — builds "Hydra.app"
│   ├── Hydra-Mac.command — double-click launcher (builds on first run)
│   ├── README-Mac.md
│   └── bot.png
├── WINDOWS/          — the native Windows app (C# WinForms)
│   ├── Hydra.cs
│   ├── Hydra.bat        — compiles + launches (rebuilds when the source changes)
│   ├── Hydra.ps1         — lightweight fallback launcher
│   ├── Build-SelfContained.ps1 — packs the offline Windows payload
│   ├── SelfContainedBuilder.cs — companion builder EXE source
│   ├── Build-SelfContained-Builder.ps1 — compiles the builder EXE
│   ├── bot.ico, bot.png
├── SKILLS-BACKUP/    — bundled skills (auto-seeded into ~/.claude/skills and ~/.agents/skills)
├── tools/            — bundled toolchain (RTK, Caveman, Claude Video, Agent Skills) + manifest.json
├── docs/             — BUILD-A-SAAS-PLAYBOOK.md (canonical SaaS production runbook)
└── README.md
```

`SKILLS-BACKUP/` is shared: the Mac build bundles it from `../SKILLS-BACKUP`, and the Windows
app finds it in the repo root (the parent of `WINDOWS/`).

## Offline-install contract

Self-contained releases include architecture-matched Node.js, Claude Code, OpenAI Codex,
Hermes Agent with a private Python runtime, Ollama, RTK, ripgrep, FFmpeg, plugins, and skills.
Windows also carries portable Git and Git Bash; its adjacent Ollama pack is part of the complete
offline download. Normal startup and **Repair bundled tools** use
only files already inside the release; they do not invoke Winget, Homebrew, `curl`, `npm`, `pip`,
`uv`, or a remote installer.

“No online installation” is not the same as “every feature works without a network.” Claude,
Codex, cloud-backed Hermes providers, authentication, update checks, and optional integrations
still contact their services. The Ollama executable is bundled, but model weights are separate
because they are multi-gigabyte and depend on the user's hardware/model choice. Supply an Ollama
model through Hydra while online or copy an existing Ollama model store as an offline pack.

The locked versions, source URLs, and SHA-256 values used by the release builders are in
[`runtime/runtime-lock.json`](runtime/runtime-lock.json). JavaScript dependencies are pinned by
[`runtime/package-lock.json`](runtime/package-lock.json). See
[`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) before redistributing a build.

## Build & run

Building from source is a maintainer workflow and does require network access plus build tools;
fresh end-user machines should use the self-contained assets above.

**macOS** (needs Xcode Command Line Tools — `xcode-select --install`):
```bash
cd MAC && ./build-mac.sh && open "Hydra.app"
```
or just double-click `MAC/Hydra-Mac.command`.

**Windows** (needs the .NET Framework compiler that ships with Windows):
double-click `WINDOWS/Hydra.bat` — it compiles `Hydra.cs` on first run
(and whenever the source is newer than the exe), then launches the GUI.

To get a double-clickable option for making the complete Windows offline package,
compile the small companion builder once and then open its EXE:

```powershell
.\WINDOWS\Build-SelfContained-Builder.ps1
.\WINDOWS\Hydra-SelfContained-Builder.exe
```

With no arguments it writes `Hydra-Windows-x64-SelfContained.exe` and
`Hydra-Windows-x64-Ollama-Offline-Pack.zip` to `dist`. Run it with `--help` for
custom output and work-directory options. The builder machine needs internet access;
the two finished files need no online installation on the target PC.

## The SaaS production playbook

Build the offline Windows package directly from PowerShell with:

```powershell
.\WINDOWS\Build-SelfContained.ps1 -Output .\WINDOWS\Hydra-SelfContained.exe
```

Every project the SaaS builder creates gets a `PLAYBOOK.md` — the battle-tested sequence
to a production site (accounts-first ordering, deploy-the-skeleton-early, Firebase Auth
enablement, Lemon Squeezy / KSA payments decision tree, Namecheap domain → Firebase Hosting
linking, deliverability, acceptance tests). Canonical copy: `docs/BUILD-A-SAAS-PLAYBOOK.md`.

## Tabs

The macOS and Windows apps share the same dark shell: a persistent 190px sidebar for navigation,
Ollama controls and live tool counts; a flat content canvas; matching page headers; and the same
compact workspace toolbar, task/model terminal chips, status colors and composed empty state.

- **Workspace** — create multiple embedded Claude, Codex, and Hermes terminals in tabs. Hermes tabs
  can run concurrently with different provider/model/profile settings; changing a default affects
  only terminals opened afterward. Claude/Codex terminals get
  RTK + Caveman when enabled. Terminal tabs make live state primary: **Ready**, **Working**,
  **Waiting for User**, or **Stopped / Token Limit**. Per-session Claude and Codex hooks drive
  turn state and report the actual runtime model; unresolved sessions say **Resolving model…**, never
  “Default.” Tabs use a short prompt-derived task hint, or the project folder for an interactive
  session, instead of an agent name. Process exit supplies the stopped fallback. Claude and Codex keep separate default
  model choices, so a Codex default like **gpt-5.6-sol** is not overwritten when you switch back
  to Claude. Hermes has its own editable model field, allowing arbitrary Ollama and OpenRouter IDs.
- **Ollama (built into Hydra)** — the portable Ollama runtime lives in Hydra's own state dir
  (`~/.claude-manager/ollama`) with `context_size.cfg` and `recommended_models.txt`
  alongside it: no installer, no login item, no system service. The architecture-matched runtime
  is already present in complete release assets; models remain user-supplied.
  The server stays off by default; **Start Ollama** serves localhost-only with a tuned
  environment (persisted context window, keep-alive 30m, flash attention, single queue,
  q8_0 KV cache) and **Stop Ollama** stops only the process Hydra owns. A server started
  elsewhere is detected without taking ownership. **Settings → Ollama models** is the model
  manager: a recommended list (LOW/HIGH VRAM groups, ornith by default), download any tag,
  chat with a model in an embedded terminal, delete models, and change the context length
  (restarts the owned server). Existing PATH / `Ollama.app` / system installs still work as
  a fallback.
- **Settings** — four focused pages for **Launch & agents**, **Memory & context**, **Compression**, and
  **System & updates**. Launch & agents shows independent Claude and Codex default models at the
  same time. Control Claude
  auto-memory and `CLAUDE.md`; Codex memories, context window,
  compaction threshold, and `AGENTS.md`; and Hermes built-in/external memory plus context compression.
  Also choose the default agent, launch defaults, token-compression toggles, one-click
  "Repair bundled tools" / "Update core packages", and check the installed Claude and
  ChatGPT/Codex CLI versions against their latest published releases.
  Selecting Codex switches the model selector to current Codex models, including **gpt-5.6-sol**,
  and Codex terminals always start in YOLO mode (`--dangerously-bypass-approvals-and-sandbox`).
  Hydra also installs Claude Video `/watch` from `tools/claude-video` and Addy Osmani's
  24-skill lifecycle pack from `tools/agent-skills` into both Claude and Codex skill folders.
  The Hermes section selects **ChatGPT/Codex OAuth**, **Claude/Anthropic**, **Ollama (local)**,
  **OpenRouter**, or Hermes' own default. It also exposes profile selection, official installation,
  `hermes model`, update checks, in-place updates, and `hermes doctor`.
- **SaaS** — the guided *Build a SaaS* lifecycle: describe your idea, scaffold Open SaaS, deploy
  (Firebase / Vercel / Cloud Run via a private GitHub repo + GitHub Actions CI/CD), and add
  subscription billing + subscriber email. Choose Claude or ChatGPT as the builder.
- **Skills** — manage the bundled skills library. Imports are mirrored into Claude skills and
  Codex/ChatGPT user skills (`~/.agents/skills`) so either builder can use them automatically.
  Native Hermes skills are inventoried separately for the selected profile, with direct access to
  `hermes skills` for browsing, installation, updates, and audits.
  The built-in Agent Skills pack adds workflows for spec, plan, build, test, review, performance,
  security, documentation, launch readiness, and more.
- **Hermes** — a dedicated Hermes control center: the explicit **provider/account → model ID → profile**
  mapping (ChatGPT/Codex OAuth, Claude/Anthropic, local Ollama, the curated OpenRouter list, or Hermes'
  default), bundled-runtime check/update/doctor actions, full **skills-hub** integration (`hermes skills` —
  browse, install by ID or SKILL.md URL, inspect, enable/disable, update, uninstall, or open the folder
  to edit by hand), structured agent-state inventories, in-app `MEMORY.md` / `USER.md` / project-context
  editors, native create forms for schedules and Kanban tasks, Kanban actions, and one-click access to
  Hermes' full local dashboard for models, auth, sessions/contexts, schedules, profiles, tools,
  analytics, and plugins. The popular workflows lead an expanded full-command glossary. Hermes keeps
  its own skills ecosystem — Hydra never mixes the shared Claude/Codex skills into it.
- **Glossary** — searchable reference for the whole toolchain, including popular-first and full-reference
  Hermes sections.
- **MCP** — a dedicated, refreshable inventory for Claude, Codex, and the selected Hermes profile.
  Hydra calls each CLI's native `mcp list`, so project/user/plugin/profile sources and health status
  remain authoritative; native manager/config actions sit beside the results.

## Hermes compatibility boundary

Hydra never rewrites Hermes' `~/.hermes/config.yaml` or `.env` itself; provider/context changes go
through supported `hermes memory` and `hermes config set` commands. The built-in memory editors only
edit Hermes' documented `memories/MEMORY.md` and `memories/USER.md` content files, with a `.hydra.bak`
save point. New terminals receive
documented per-launch `--provider`, `--model`, `-p`, `--tui`, and `--continue` arguments. Ollama is
connected through its localhost OpenAI-compatible endpoint only in the selected terminal's process
environment. Authentication remains in `hermes model`; complete Hydra releases launch the
bundled Hermes/Python environment without running Hermes' installer. Explicit upgrades use the
[official `hermes update` workflow](https://hermes-agent.nousresearch.com/docs/reference/cli-commands)
with a forced pre-update backup. Hydra refuses to update while a Hermes terminal is still running,
keeping live processes away from an in-place environment change and avoiding coupling to Hermes'
internal schema.

For the local Ollama backend, Hydra starts the owned runtime and waits up to 15 seconds for its
OpenAI-compatible API to accept connections before launching Hermes. If readiness fails, Hydra keeps
Hermes closed and shows a repair path instead of allowing Hermes to exhaust three connection retries.
On Windows, the first embedded console also receives a verified cross-process focus handoff; this is
covered by an executable-level keyboard-input regression test in CI.
