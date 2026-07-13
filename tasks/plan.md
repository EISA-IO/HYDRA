# Hydra zero-network release plan

## Objective

Ship Windows x64 and macOS (Apple Silicon and Intel) Hydra release artifacts that
start on a fresh supported machine without downloading or installing developer
tools. Network access remains necessary for cloud-agent authentication and model
requests; local Ollama use additionally requires model weights supplied by the
user or an offline model pack.

## Acceptance criteria

1. The release payload (including the adjacent Windows Ollama pack) contains architecture-matched Node.js, Claude Code,
   Codex, Hermes Agent with its own Python runtime, Ollama, RTK, ripgrep, FFmpeg,
   and (on Windows) portable Git Bash.
2. Normal application startup never invokes `curl`, `npm install`, `pip`, `uv`,
   Winget, Homebrew, or a remote installer.
3. Install/repair actions restore the bundled payload locally. Networked update
   actions remain explicit user choices.
4. Release builders use pinned dependency versions and verify downloaded
   artifacts before packaging.
5. Windows and macOS release jobs exercise every bundled command using a clean
   state directory and a restricted system `PATH`; Hermes is included in the
   gate.
6. CI builds both supported macOS architectures and Windows x64 artifacts, then
   publishes immutable artifacts with SHA-256 checksums.
7. Documentation distinguishes zero-network installation from cloud-agent use,
   authentication, optional integrations, and separately supplied Ollama model
   weights.

## Implementation increments

### 1. Contract and failing tests

- Add platform payload verifiers for required files, command execution, and
  forbidden first-launch installer fallbacks.
- Run them against the current builders/payload layout and record the expected
  Hermes/dependency failures.

### 2. Reproducible runtime assembly

- Add a checked-in runtime lock manifest.
- Add shared platform assembly logic for the managed Python/Hermes environment
  and command wrappers.
- Bundle Git Bash/ripgrep/FFmpeg where the target OS does not provide an
  acceptable runtime command.
- Extend the Windows and macOS builders to call the assembly logic.

### 3. Offline application behavior

- Remove automatic online installer fallbacks from startup provisioning.
- Make install/repair buttons validate and restore bundled tools locally.
- Preserve explicit networked update commands with clear labeling.

### 4. Release automation and documentation

- Run self-contained builds in CI for release-related changes and tags.
- Build native macOS artifacts on both architectures.
- Generate checksums and publish release assets from version tags.
- Update the README and bundled manifest with the precise support contract.

### 5. Verification and shipping

- Run Windows compile/unit/UI tests and offline payload tests locally where the
  platform permits.
- Push the branch, run Windows and macOS clean-runner builds, inspect artifacts,
  and resolve failures.
- Perform security and code-quality review, then push the verified commit to the
  Hydra GitHub repository.

## Explicit exclusions

- API credentials and user authentication state are never bundled.
- Multi-gigabyte Ollama model weights are separate offline packs because model
  choice depends on RAM/VRAM and GitHub release assets have practical size
  limits.
- Optional third-party Hermes integrations may require their own credentials or
  services; the core Hermes CLI must launch without installing them.
