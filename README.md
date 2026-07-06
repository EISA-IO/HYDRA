# Claude Manager  ·  by Ahmed Al-Eissa

A launcher + toolchain manager for Claude Code, with an embedded multi-terminal Workspace,
a token-compression toolchain (RTK + Caveman + Headroom), a bundled skills library, and a
guided **Build a SaaS** lifecycle (Vision → Deploy → Subscriptions).

## Repository layout

```
CLAUDE-MANAGER/
├── MAC/              — the native macOS app (SwiftUI, built with Swift Package Manager)
│   ├── mac/          — Swift sources
│   ├── Package.swift, Package.resolved
│   ├── build-mac.sh              — builds "Claude Manager.app"
│   ├── Claude-Manager-Mac.command — double-click launcher (builds on first run)
│   ├── README-Mac.md
│   └── bot.png
├── WINDOWS/          — the native Windows app (C# WinForms)
│   ├── ClaudeManager.cs
│   ├── Claude-Manager.bat        — compiles + launches (rebuilds when the source changes)
│   ├── ClaudeManager.ps1         — lightweight fallback launcher
│   ├── bot.ico, bot.png
├── SKILLS-BACKUP/    — the bundled skills library (shared by BOTH apps; auto-seeded into ~/.claude/skills)
└── README.md
```

`SKILLS-BACKUP/` is shared: the Mac build bundles it from `../SKILLS-BACKUP`, and the Windows
app finds it in the repo root (the parent of `WINDOWS/`).

## Build & run

**macOS** (needs Xcode Command Line Tools — `xcode-select --install`):
```bash
cd MAC && ./build-mac.sh && open "Claude Manager.app"
```
or just double-click `MAC/Claude-Manager-Mac.command`.

**Windows** (needs the .NET Framework compiler that ships with Windows):
double-click `WINDOWS/Claude-Manager.bat` — it compiles `ClaudeManager.cs` on first run
(and whenever the source is newer than the exe), then launches the GUI.

## The SaaS production playbook

Every project the SaaS builder creates gets a `PLAYBOOK.md` — the battle-tested sequence
to a production site (accounts-first ordering, deploy-the-skeleton-early, Firebase Auth
enablement, Lemon Squeezy / KSA payments decision tree, Namecheap domain → Firebase Hosting
linking, deliverability, acceptance tests). Canonical copy: `docs/BUILD-A-SAAS-PLAYBOOK.md`.

## Tabs

- **Workspace** — create multiple embedded Claude terminals in tabs; per-terminal RTK + Caveman.
- **Settings** — launch defaults, token-compression toggles, one-click "Install everything" / "Update core packages".
- **SaaS** — the guided *Build a SaaS* lifecycle: describe your idea, scaffold Open SaaS, deploy
  (Firebase / Vercel / Cloud Run via a private GitHub repo + GitHub Actions CI/CD), and add
  subscription billing + subscriber email. KSA-first payments (Tap / Moyasar) by default.
- **Skills** — manage the bundled skills library.
- **Glossary** — reference for the whole toolchain.
