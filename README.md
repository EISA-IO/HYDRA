# Hydra  ·  by Ahmed Al-Eissa

A launcher + toolchain manager for Claude Code and Codex CLI, with an embedded multi-terminal
Workspace, a token-compression toolchain (RTK + Caveman + Headroom), a bundled skills library,
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

- **Workspace** — create multiple embedded Claude and Codex terminals in tabs; each terminal gets
  RTK + Caveman when enabled.
- **Settings** — choose the default agent, launch defaults, token-compression toggles, one-click
  "Install everything" / "Update core packages".
  Selecting Codex switches the model selector to ChatGPT models, including **ChatGPT 5.6**,
  and Codex terminals always start in YOLO mode (`--dangerously-bypass-approvals-and-sandbox`).
- **SaaS** — the guided *Build a SaaS* lifecycle: describe your idea, scaffold Open SaaS, deploy
  (Firebase / Vercel / Cloud Run via a private GitHub repo + GitHub Actions CI/CD), and add
  subscription billing + subscriber email. Choose Claude or ChatGPT as the builder.
- **Skills** — manage the bundled skills library. Imports are mirrored into Claude skills and
  Codex/ChatGPT user skills (`~/.agents/skills`) so either builder can use them automatically.
- **Glossary** — reference for the whole toolchain.
