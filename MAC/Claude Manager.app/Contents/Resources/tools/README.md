# Bundled native toolchain

Claude Manager ships these so a user never has to hunt down or download tools by hand.
On launch the app copies the right binary for the current OS into `~/.claude-manager/bin`
(prepended to every embedded terminal's PATH) and seeds the Caveman plugin locally.

## What's bundled
- `mac-arm64/rtk`, `mac-x64/rtk`, `win-x64/rtk.exe` — RTK input-compression binary (per platform).
- `caveman/` — the Caveman marketplace (a local, offline plugin source + Node installer).

## Completing cross-platform coverage
This repo is built on Apple Silicon, so only `mac-arm64/rtk` ships prefilled. To make the app
fully self-contained on the other targets, drop the matching binary into its slot:
- Intel Mac: build/download `rtk` → `tools/mac-x64/rtk`
- Windows x64: `rtk.exe` → `tools/win-x64/rtk.exe`
The manifest lists a `fallbackInstall` command the app runs automatically if a slot is empty,
so the app still self-provisions — bundling just makes it instant and offline.

## Claude CLI
Anthropic's `claude` binary isn't redistributable, so it isn't vendored. If it's missing the app
installs it once, silently, via the official installer — the user still does nothing.
