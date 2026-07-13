#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="${1:-}"

assert_contains() {
  local file="$1" pattern="$2" message="$3"
  grep -Fq "$pattern" "$file" || { echo "ERROR: $message" >&2; exit 1; }
}

assert_not_contains_range() {
  local file="$1" start="$2" end="$3" pattern="$4" message="$5"
  local body
  # The end marker normally names the following function. Exclude that marker so
  # its declaration cannot be mistaken for a call from the function under test.
  body="$(sed -n "/$start/,/$end/p" "$file" | sed '$d')"
  if printf '%s' "$body" | grep -Eq "$pattern"; then
    echo "ERROR: $message" >&2
    exit 1
  fi
}

assert_not_contains_range "$HERE/mac/Tooling.swift" \
  'func provisionNativeToolchain()' 'func codexInstallCmd()' \
  'claudeInstallCmd|codexInstallCmd|rtkFullScript|curl |https?://' \
  'Normal macOS startup still contains an online installer fallback.'

assert_not_contains_range "$HERE/mac/Installers.swift" \
  'func installHermes()' 'func configureHermes()' \
  'curl |https?://' \
  'macOS Hermes repair still downloads and executes a remote installer.'

assert_not_contains_range "$HERE/mac/Installers.swift" \
  'func installCodex()' 'func cavemanCmd()' \
  'nodeEnsureScript|codexInstallCmd|curl |https?://' \
  'macOS Codex repair still invokes an online installer.'

assert_not_contains_range "$HERE/mac/Installers.swift" \
  'func installNode()' 'func installClaude()' \
  'nodeEnsureScript|curl |https?://' \
  'macOS Node repair still invokes an online installer.'

assert_not_contains_range "$HERE/mac/Installers.swift" \
  'func installClaude()' 'func installHermes()' \
  'claudeInstallCmd|curl |https?://' \
  'macOS Claude repair still invokes an online installer.'

assert_not_contains_range "$HERE/mac/Installers.swift" \
  'func installRtk()' 'func installCaveman()' \
  'rtkFullScript|curl |https?://' \
  'macOS RTK repair still invokes an online installer.'

assert_not_contains_range "$HERE/mac/Installers.swift" \
  'func installCaveman()' 'func installClaudeVideo()' \
  'cavemanCmd|npx |curl |https?://' \
  'macOS Caveman repair still invokes an online installer.'

assert_not_contains_range "$HERE/mac/Installers.swift" \
  'func installOllama()' 'func installHeadroom()' \
  'ollamaInstallScript|curl |https?://' \
  'macOS Ollama repair still invokes an online installer.'

assert_not_contains_range "$HERE/mac/Installers.swift" \
  'func installEverything()' 'func updateCore()' \
  'nodeEnsureScript|claudeInstallCmd|codexInstallCmd|rtkFullScript|cavemanCmd|ollamaInstallScript|curl |https?://' \
  'macOS bundled-tool repair still invokes an online installer.'

for marker in hermes securityOverridesPath python3 rg ffmpeg; do
  assert_contains "$HERE/build-mac.sh" "$marker" \
    "macOS self-contained builder does not assemble $marker."
done

if [ -z "$APP" ]; then
  echo 'macOS zero-network source contract passed.'
  exit 0
fi

RES="$APP/Contents/Resources"
RBIN="$RES/runtime/bin"
for path in \
  "$RBIN/node" \
  "$RBIN/claude" \
  "$RBIN/codex" \
  "$RBIN/hermes" \
  "$RBIN/python3" \
  "$RBIN/rg" \
  "$RBIN/ffmpeg" \
  "$RES/runtime/ollama/ollama"; do
  [ -x "$path" ] || { echo "ERROR: Offline payload is missing executable $path" >&2; exit 1; }
done

RTK="$(find "$RES/tools" -type f -name rtk -perm -111 | head -1)"
[ -n "$RTK" ] || { echo 'ERROR: Offline payload is missing RTK.' >&2; exit 1; }

TEST_HOME="$(mktemp -d)"
trap 'rm -rf "$TEST_HOME"' EXIT
export HOME="$TEST_HOME"
export PATH="$RBIN:/usr/bin:/bin"
export UV_OFFLINE=1 PIP_NO_INDEX=1 npm_config_offline=true
"$RBIN/node" --version
"$RBIN/claude" --version
"$RBIN/codex" --version
"$RBIN/hermes" --version
"$RBIN/python3" --version
"$RBIN/rg" --version
"$RBIN/ffmpeg" -version
"$RES/runtime/ollama/ollama" --version
"$RTK" --version

echo 'macOS zero-network payload contract passed.'
