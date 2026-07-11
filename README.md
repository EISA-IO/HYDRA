# Hydra  ·  by Ahmed Al-Eissa

[![Windows](https://img.shields.io/badge/Windows-hydra__v1.0.exe-0078D6?logo=windows&logoColor=white)](https://github.com/EISA-IO/HYDRA/releases/latest/download/hydra_v1.0.exe)
[![macOS](https://img.shields.io/badge/macOS-hydra__v1.0--mac.zip-000000?logo=apple&logoColor=white)](https://github.com/EISA-IO/HYDRA/releases/latest/download/hydra_v1.0-mac.zip)
[![Release](https://img.shields.io/github/v/release/EISA-IO/HYDRA?color=D97757)](https://github.com/EISA-IO/HYDRA/releases/latest)

## Download

| Platform | Download | Run |
|---|---|---|
| **Windows 10/11** | [`hydra_v1.0.exe`](https://github.com/EISA-IO/HYDRA/releases/latest/download/hydra_v1.0.exe) | double-click — no installer |
| **macOS 14+** | [`hydra_v1.0-mac.zip`](https://github.com/EISA-IO/HYDRA/releases/latest/download/hydra_v1.0-mac.zip) | unzip → right-click **Hydra.app** → Open |

A launcher + toolchain manager for Claude Code, Codex CLI, and a natively built-in Ollama, with an embedded multi-terminal
Workspace, a token-compression toolchain (RTK + Caveman + Headroom), Claude Video `/watch`,
Addy Osmani's Agent Skills, and a bundled skills library,
and a guided **Build a SaaS** lifecycle (Vision → Deploy → Subscriptions).

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
│   ├── bot.ico, bot.png
├── SKILLS-BACKUP/    — bundled skills (auto-seeded into ~/.claude/skills and ~/.agents/skills)
└── README.md
```

`SKILLS-BACKUP/` is shared: the Mac build bundles it from `../SKILLS-BACKUP`, and the Windows
app finds it in the repo root (the parent of `WINDOWS/`).

## Build & run

**macOS** (needs Xcode Command Line Tools — `xcode-select --install`):
```bash
cd MAC && ./build-mac.sh && open "Hydra.app"
```
or just double-click `MAC/Hydra-Mac.command`.

**Windows** (needs the .NET Framework compiler that ships with Windows):
double-click `WINDOWS/Hydra.bat` — it compiles `Hydra.cs` on first run
(and whenever the source is newer than the exe), then launches the GUI.

## The SaaS production playbook

Every project the SaaS builder creates gets a `PLAYBOOK.md` — the battle-tested sequence
to a production site (accounts-first ordering, deploy-the-skeleton-early, Firebase Auth
enablement, Lemon Squeezy / KSA payments decision tree, Namecheap domain → Firebase Hosting
linking, deliverability, acceptance tests). Canonical copy: `docs/BUILD-A-SAAS-PLAYBOOK.md`.

## Tabs

The macOS and Windows apps share the same dark shell: a persistent 190px sidebar for navigation,
Ollama controls and live tool counts; a flat content canvas; matching page headers; and the same
compact workspace toolbar, task/model terminal chips, status colors and composed empty state.

- **Workspace** — create multiple embedded Claude and Codex terminals in tabs; each terminal gets
  RTK + Caveman when enabled. Terminal tabs make live state primary: **Ready**, **Working**,
  **Waiting for User**, or **Stopped / Token Limit**. Per-session Claude and Codex hooks drive
  turn state and report the actual runtime model; unresolved sessions say **Resolving model…**, never
  “Default.” Tabs use a short prompt-derived task hint, or the project folder for an interactive
  session, instead of an agent name. Process exit supplies the stopped fallback. Claude and Codex keep separate default
  model choices, so a Codex default like **gpt-5.6-sol** is not overwritten when you switch back
  to Claude.
- **Ollama (built into Hydra)** — the portable Ollama runtime lives in Hydra's own state dir
  (`~/.claude-manager/ollama`) with the models, `context_size.cfg` and `recommended_models.txt`
  alongside it: no installer, no login item, no system service — delete the folder and every
  trace is gone. "Install everything" (or the Ollama button) embeds it on both platforms.
  The server stays off by default; **Start Ollama** serves localhost-only with a tuned
  environment (persisted context window, keep-alive 30m, flash attention, single queue,
  q8_0 KV cache) and **Stop Ollama** stops only the process Hydra owns. A server started
  elsewhere is detected without taking ownership. **Settings → Ollama models** is the model
  manager: a recommended list (LOW/HIGH VRAM groups, ornith by default), download any tag,
  chat with a model in an embedded terminal, delete models, and change the context length
  (restarts the owned server). Existing PATH / `Ollama.app` / system installs still work as
  a fallback.
- **Settings** — choose the default agent, launch defaults, token-compression toggles, one-click
  "Install everything" / "Update core packages".
  Selecting Codex switches the model selector to current Codex models, including **gpt-5.6-sol**,
  and Codex terminals always start in YOLO mode (`--dangerously-bypass-approvals-and-sandbox`).
  Hydra also installs Claude Video `/watch` from `tools/claude-video` and Addy Osmani's
  24-skill lifecycle pack from `tools/agent-skills` into both Claude and Codex skill folders.
- **SaaS** — the guided *Build a SaaS* lifecycle: describe your idea, scaffold Open SaaS, deploy
  (Firebase / Vercel / Cloud Run via a private GitHub repo + GitHub Actions CI/CD), and add
  subscription billing + subscriber email. Choose Claude or ChatGPT as the builder.
- **Skills** — manage the bundled skills library. Imports are mirrored into Claude skills and
  Codex/ChatGPT user skills (`~/.agents/skills`) so either builder can use them automatically.
  The built-in Agent Skills pack adds workflows for spec, plan, build, test, review, performance,
  security, documentation, launch readiness, and more.
- **Glossary** — reference for the whole toolchain.
