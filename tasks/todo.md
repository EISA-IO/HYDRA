# Hydra zero-network release checklist

- [x] Audit current Windows/macOS builders and startup paths.
- [x] Confirm current public release artifacts are thin, not self-contained.
- [x] Add failing zero-network payload contract tests.
- [x] Pin runtime sources and checksums.
- [x] Bundle a relocatable Hermes Python runtime on Windows and macOS.
- [x] Bundle Windows Git Bash plus required ripgrep/FFmpeg commands.
- [x] Remove first-launch online installer fallbacks.
- [x] Make install/repair actions local-only.
- [x] Extend CI to both macOS architectures and verify every runtime command.
- [x] Update documentation and license/third-party notices.
- [x] Run local Windows validation.
- [ ] Push and validate clean Windows/macOS GitHub runners.
- [ ] Complete security/code review and publish the verified GitHub changes.
