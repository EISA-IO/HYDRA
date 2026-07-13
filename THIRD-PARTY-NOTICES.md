# Third-party notices

Hydra self-contained builds aggregate unmodified third-party runtimes and
packages. Each component remains governed by its own license and terms; Hydra's
license does not replace them. Complete dependency metadata and pinned source
artifacts are recorded in `runtime/runtime-lock.json` and
`runtime/package-lock.json`.

| Component | Bundled version | License / terms |
|---|---:|---|
| Node.js | 24.18.0 | Node.js license (MIT plus bundled third-party notices): <https://github.com/nodejs/node/blob/main/LICENSE> |
| Claude Code | 2.1.207 | Copyright Anthropic PBC, all rights reserved; use is subject to Anthropic's Commercial Terms: <https://github.com/anthropics/claude-code/blob/main/LICENSE.md> |
| OpenAI Codex CLI | 0.144.3 | Apache License 2.0: <https://github.com/openai/codex/blob/main/LICENSE> |
| Hermes Agent | 0.18.2 | MIT License: <https://github.com/NousResearch/hermes-agent/blob/main/LICENSE> |
| Python | 3.13.13 | Python Software Foundation License: <https://docs.python.org/3/license.html> |
| Ollama | 0.31.2 | MIT License: <https://github.com/ollama/ollama/blob/main/LICENSE> |
| ripgrep | 15.1.0 | MIT and Unlicense dual license: <https://github.com/BurntSushi/ripgrep> |
| Git for Windows / PortableGit | 2.55.0.2 | GNU GPL v2 and bundled notices: <https://github.com/git-for-windows/git> |
| FFmpeg binary distributed by imageio-ffmpeg | imageio-ffmpeg 0.6.0 | imageio-ffmpeg BSD-2-Clause; the included FFmpeg build carries its own LGPL/GPL configuration and notices: <https://github.com/imageio/imageio-ffmpeg> |
| RTK | 0.43.0 | Apache License 2.0: <https://github.com/rtk-ai/rtk/blob/master/LICENSE> |

The packaged JavaScript and Python dependency trees contain additional
third-party licenses in their package metadata and `*.dist-info` directories.
Those files are retained in the release payload.

## Release-maintainer note

Claude Code is not published under an open-source redistribution license. Before
publishing a Hydra binary that contains Claude Code, the release maintainer must
confirm that their agreement with Anthropic permits that distribution. The
build system's ability to assemble a package is not a grant of redistribution
rights.
