# Bundled native toolchain

Hydra’s self-contained releases include the complete core runtime. Embedded terminals place
Hydra’s private binaries before the system `PATH`, and bundled skills are mirrored into both
Claude and Codex/ChatGPT user skill folders.

## What is bundled

- Portable Node.js runtime.
- Claude Code CLI and ChatGPT/Codex CLI.
- Ollama runtime. Model weights remain user-selected and are not preloaded.
- RTK input-compression binary for the target platform.
- Caveman, Claude Video, Agent Skills, and the bundled skill library.

## Release artifacts

`WINDOWS/Build-SelfContained.ps1` produces one large Windows EXE containing a compressed
payload. On first launch it extracts into `%USERPROFILE%\.claude-manager\runtime` and uses
that private runtime before system-installed tools.

`MAC/build-mac.sh` puts the architecture-matched payload directly inside
`Hydra.app/Contents/Resources/runtime`. Set `HYDRA_THIN_BUILD=1` only for a developer build
that intentionally omits the large runtime.

The manual **Self-contained release builds** GitHub workflow builds and smoke-tests both
targets. Review and comply with each bundled dependency’s current license and terms before
redistributing generated artifacts.
