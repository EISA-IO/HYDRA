#!/usr/bin/env bash
# Build "Hydra.app" — a native SwiftUI macOS app — from the Swift sources
# in ./mac. Requires the Xcode Command Line Tools (swiftc). No Xcode project needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/Hydra.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
BIN="$MACOS/Hydra"
REPO="$(cd "$HERE/.." && pwd)"
RUNTIME_LOCK="$REPO/runtime/runtime-lock.json"

lock_value() {
  python3 - "$RUNTIME_LOCK" "$1" <<'PY'
import json, sys
value = json.load(open(sys.argv[1], encoding="utf-8"))
for part in sys.argv[2].split("."):
    value = value[part]
print(value)
PY
}

download_verified() {
  local url="$1" destination="$2" expected="$3" actual
  echo "  download $url"
  curl -fsSL "$url" -o "$destination"
  actual="$(shasum -a 256 "$destination" | awk '{print $1}')"
  [ "$actual" = "$expected" ] || {
    echo "SHA-256 mismatch for $url. Expected $expected, received $actual." >&2
    exit 1
  }
}

echo "› Building with Swift Package Manager (pulls in SwiftTerm on first run)…"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
( cd "$HERE" && swift build -c release )
BUILT="$HERE/.build/release/Hydra"
if [ ! -x "$BUILT" ]; then
  echo "✗ Build failed — $BUILT not produced." >&2
  exit 1
fi
cp "$BUILT" "$BIN"

echo "› Writing Info.plist…"
cat > "$CONTENTS/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>            <string>Hydra</string>
  <key>CFBundleDisplayName</key>     <string>Hydra</string>
  <key>CFBundleIdentifier</key>      <string>io.eisa.hydra</string>
  <key>CFBundleVersion</key>         <string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleExecutable</key>      <string>Hydra</string>
  <key>CFBundlePackageType</key>     <string>APPL</string>
  <key>CFBundleIconFile</key>        <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>  <string>14.0</string>
  <key>NSHighResolutionCapable</key> <true/>
  <key>NSPrincipalClass</key>        <string>NSApplication</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <!-- Friendly explanations on the rare occasions macOS asks for access. The app avoids
       touching protected folders at startup, so these appear only when YOU open a project
       there. NOTE: rebuilding the app re-signs it (new ad-hoc identity), which makes macOS
       forget previous grants — normal launches never rebuild, so grants stick. -->
  <key>NSDesktopFolderUsageDescription</key>  <string>Hydra opens Claude sessions in project folders you choose, including ones on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Hydra opens Claude sessions in project folders you choose, including ones in Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Hydra opens Claude sessions in project folders you choose, including ones in Downloads.</string>
  <key>NSAppleEventsUsageDescription</key>    <string>Hydra only uses Apple Events if you ask it to control an external Terminal window.</string>
</dict>
</plist>
PLIST

# ---- bundle the skills so they ship natively with the app ----
# SKILLS-BACKUP is shared between the Mac and Windows builds, so it lives one level up
# (the repo root); fall back to a local copy if present.
SKILLS_SRC="$HERE/../SKILLS-BACKUP"
[ -d "$SKILLS_SRC" ] || SKILLS_SRC="$HERE/SKILLS-BACKUP"
if [ -d "$SKILLS_SRC" ]; then
  echo "› Bundling skills…"
  mkdir -p "$RES/skills"
  # copy each skill dir that contains a SKILL.md (ignore stray files like screenshots)
  find "$SKILLS_SRC" -maxdepth 2 -name SKILL.md -print0 | while IFS= read -r -d '' md; do
    d="$(dirname "$md")"
    cp -R "$d" "$RES/skills/" 2>/dev/null || true
  done
  echo "  bundled $(ls -1 "$RES/skills" 2>/dev/null | wc -l | tr -d ' ') skills"
fi

# ---- bundle the native toolchain (rtk binary, caveman marketplace) so the app
#      provisions them with NO user download. Shared at the repo root; local fallback. ----
TOOLS_SRC="$HERE/../tools"
[ -d "$TOOLS_SRC" ] || TOOLS_SRC="$HERE/tools"
if [ -d "$TOOLS_SRC" ]; then
  echo "› Bundling native toolchain…"
  rm -rf "$RES/tools"
  mkdir -p "$RES/tools"
  cp -R "$TOOLS_SRC/." "$RES/tools/" 2>/dev/null || true
  # keep the shipped rtk binaries executable
  find "$RES/tools" -type f -name rtk -exec chmod +x {} \; 2>/dev/null || true
  echo "  bundled tools: $(ls -1 "$RES/tools" 2>/dev/null | tr '\n' ' ')"
fi
cp "$REPO/THIRD-PARTY-NOTICES.md" "$RES/THIRD-PARTY-NOTICES.md"

# ---- full offline runtime: Node + Claude Code + Codex + Ollama -----------------
# Set HYDRA_THIN_BUILD=1 only for a developer build. Release builds intentionally
# carry the complete architecture-matched runtime and can be several gigabytes.
if [ "${HYDRA_THIN_BUILD:-0}" != "1" ]; then
  echo "› Bundling complete offline CLI/runtime payload…"
  RUNTIME="$RES/runtime"; RBIN="$RUNTIME/bin"; RAPP="$RUNTIME/app"
  rm -rf "$RUNTIME"; mkdir -p "$RBIN" "$RAPP" "$RUNTIME/ollama"
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64) SLOT_NAME="mac-arm64" ;;
    x86_64) SLOT_NAME="mac-x64" ;;
    *) echo "Unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
  esac
  TMP_RUNTIME="$(mktemp -d)"
  trap 'rm -rf "$TMP_RUNTIME"' EXIT

  UV_EXPECTED="$(lock_value uv)"
  command -v uv >/dev/null 2>&1 || { echo "The pinned uv $UV_EXPECTED build dependency is required. Target Macs do not need it." >&2; exit 1; }
  UV_ACTUAL="$(uv --version | sed -E 's/^uv ([^ ]+).*/\1/')"
  [ "$UV_ACTUAL" = "$UV_EXPECTED" ] || { echo "Expected uv $UV_EXPECTED, found $UV_ACTUAL." >&2; exit 1; }

  download_verified "$(lock_value "node.$SLOT_NAME.url")" "$TMP_RUNTIME/node.tgz" "$(lock_value "node.$SLOT_NAME.sha256")"
  tar -xzf "$TMP_RUNTIME/node.tgz" -C "$TMP_RUNTIME"
  NODE_ROOT="$(find "$TMP_RUNTIME" -maxdepth 1 -type d -name 'node-*-darwin-*' | head -1)"
  [ -n "$NODE_ROOT" ] || { echo "Node runtime missing from archive" >&2; exit 1; }
  cp -R "$NODE_ROOT/." "$RBIN/"
  ln -sf bin/node "$RBIN/node"; ln -sf bin/npm "$RBIN/npm"; ln -sf bin/npx "$RBIN/npx"
  cp "$REPO/runtime/package.json" "$REPO/runtime/package-lock.json" "$RAPP/"
  PATH="$RBIN:$PATH" "$RBIN/npm" ci --prefix "$RAPP" --omit=dev --no-fund --no-audit
  cat > "$RBIN/claude" <<'SH'
#!/bin/sh
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export PATH="$HERE:$PATH"
exec "$HERE/../app/node_modules/.bin/claude" "$@"
SH
  cat > "$RBIN/codex" <<'SH'
#!/bin/sh
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export PATH="$HERE:$PATH"
exec "$HERE/../app/node_modules/.bin/codex" "$@"
SH
  chmod +x "$RBIN/claude" "$RBIN/codex" "$RBIN/bin/node" "$RBIN/bin/npm" "$RBIN/bin/npx"

  PYTHON_VERSION="$(lock_value python)"
  uv python install "$PYTHON_VERSION" --install-dir "$TMP_RUNTIME/python-install" --no-bin
  # uv's managed macOS Python exposes bin/python3 as a relative symlink, while
  # Windows uses a regular executable. Accept either filesystem type here.
  PYTHON_BIN="$(find "$TMP_RUNTIME/python-install" -path '*/bin/python3' | head -1)"
  [ -n "$PYTHON_BIN" ] || { echo "Managed Python runtime missing after uv install" >&2; exit 1; }
  PYTHON_ROOT="$(cd "$(dirname "$PYTHON_BIN")/.." && pwd)"
  mkdir -p "$RUNTIME/python"
  cp -R "$PYTHON_ROOT/." "$RUNTIME/python/"
  PYTHON="$RUNTIME/python/bin/python3"
  SITE_PACKAGES="$($PYTHON -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])')"

  download_verified "$(lock_value hermes.sdistUrl)" "$TMP_RUNTIME/hermes_agent.tar.gz" "$(lock_value hermes.sdistSha256)"
  mkdir -p "$TMP_RUNTIME/hermes-source"
  tar -xzf "$TMP_RUNTIME/hermes_agent.tar.gz" -C "$TMP_RUNTIME/hermes-source"
  HERMES_SOURCE="$(find "$TMP_RUNTIME/hermes-source" -mindepth 1 -maxdepth 1 -type d | head -1)"
  [ -n "$HERMES_SOURCE" ] || { echo "Hermes source metadata missing from archive" >&2; exit 1; }
  download_verified "$(lock_value hermes.uvLockUrl)" "$HERMES_SOURCE/uv.lock" "$(lock_value hermes.uvLockSha256)"
  uv export --project "$HERMES_SOURCE" --frozen --extra all --no-dev --no-emit-project --output-file "$TMP_RUNTIME/hermes-requirements.txt" >/dev/null
  uv pip install --python "$PYTHON" --target "$SITE_PACKAGES" --require-hashes --requirements "$TMP_RUNTIME/hermes-requirements.txt"
  HERMES_WHEEL="$TMP_RUNTIME/hermes_agent-0.18.2-py3-none-any.whl"
  download_verified "$(lock_value hermes.wheelUrl)" "$HERMES_WHEEL" "$(lock_value hermes.wheelSha256)"
  uv pip install --python "$PYTHON" --target "$SITE_PACKAGES" --no-deps "$HERMES_WHEEL"
  SECURITY_OVERRIDES="$REPO/$(lock_value hermes.securityOverridesPath)"
  SECURITY_OVERRIDES_HASH="$(shasum -a 256 "$SECURITY_OVERRIDES" | awk '{print $1}')"
  [ "$SECURITY_OVERRIDES_HASH" = "$(lock_value hermes.securityOverridesSha256)" ] || {
    echo "Hermes security override hash mismatch." >&2
    exit 1
  }
  uv pip install --python "$PYTHON" --target "$SITE_PACKAGES" --upgrade --no-deps --require-hashes --only-binary :all: --requirements "$SECURITY_OVERRIDES"

  case "$ARCH" in
    arm64) FFMPEG_WHEEL="$TMP_RUNTIME/imageio_ffmpeg-0.6.0-py3-none-macosx_11_0_arm64.whl" ;;
    x86_64) FFMPEG_WHEEL="$TMP_RUNTIME/imageio_ffmpeg-0.6.0-py3-none-macosx_10_9_intel.macosx_10_9_x86_64.whl" ;;
  esac
  download_verified "$(lock_value "ffmpeg.$SLOT_NAME.url")" "$FFMPEG_WHEEL" "$(lock_value "ffmpeg.$SLOT_NAME.sha256")"
  uv pip install --python "$PYTHON" --target "$SITE_PACKAGES" --no-deps "$FFMPEG_WHEEL"
  FFMPEG_BIN="$(find "$SITE_PACKAGES/imageio_ffmpeg/binaries" -type f -name 'ffmpeg-*' | head -1)"
  [ -n "$FFMPEG_BIN" ] || { echo "FFmpeg binary missing from wheel" >&2; exit 1; }
  cp "$FFMPEG_BIN" "$RBIN/ffmpeg"; chmod +x "$RBIN/ffmpeg"

  cat > "$RBIN/python3" <<'SH'
#!/bin/sh
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec "$HERE/../python/bin/python3" "$@"
SH
  cat > "$RBIN/hermes" <<'SH'
#!/bin/sh
HERE="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
export PATH="$HERE:$PATH"
exec "$HERE/../python/bin/python3" -m hermes_cli.main "$@"
SH
  chmod +x "$RBIN/python3" "$RBIN/hermes"

  download_verified "$(lock_value "ripgrep.$SLOT_NAME.url")" "$TMP_RUNTIME/ripgrep.tgz" "$(lock_value "ripgrep.$SLOT_NAME.sha256")"
  mkdir -p "$TMP_RUNTIME/ripgrep"
  tar -xzf "$TMP_RUNTIME/ripgrep.tgz" -C "$TMP_RUNTIME/ripgrep"
  RG_BIN="$(find "$TMP_RUNTIME/ripgrep" -type f -name rg | head -1)"
  [ -n "$RG_BIN" ] || { echo "ripgrep binary missing from archive" >&2; exit 1; }
  cp "$RG_BIN" "$RBIN/rg"; chmod +x "$RBIN/rg"

  download_verified "$(lock_value ollama.mac-universal.url)" "$TMP_RUNTIME/ollama.tgz" "$(lock_value ollama.mac-universal.sha256)"
  tar -xzf "$TMP_RUNTIME/ollama.tgz" -C "$RUNTIME/ollama"
  OLLAMA_BIN="$(find "$RUNTIME/ollama" -type f -name ollama | head -1)"
  [ -n "$OLLAMA_BIN" ] || { echo "Ollama runtime missing from archive" >&2; exit 1; }
  if [ "$OLLAMA_BIN" != "$RUNTIME/ollama/ollama" ]; then
    OLLAMA_REL="${OLLAMA_BIN#"$RUNTIME/ollama/"}"
    cat > "$RUNTIME/ollama/ollama" <<SH
#!/bin/sh
HERE="\$(CDPATH= cd -- "\$(dirname -- "\$0")" && pwd)"
exec "\$HERE/$OLLAMA_REL" "\$@"
SH
  fi
  chmod +x "$RUNTIME/ollama/ollama"
  SLOT="$RES/tools/$SLOT_NAME"
  mkdir -p "$SLOT"
  if [ ! -x "$SLOT/rtk" ]; then
    download_verified "$(lock_value "rtk.$SLOT_NAME.url")" "$TMP_RUNTIME/rtk.tgz" "$(lock_value "rtk.$SLOT_NAME.sha256")"
    mkdir -p "$TMP_RUNTIME/rtk"; tar -xzf "$TMP_RUNTIME/rtk.tgz" -C "$TMP_RUNTIME/rtk"
    RTK_BIN="$(find "$TMP_RUNTIME/rtk" -type f -name rtk | head -1)"
    [ -n "$RTK_BIN" ] || { echo "RTK binary missing from archive" >&2; exit 1; }
    cp "$RTK_BIN" "$SLOT/rtk"; chmod +x "$SLOT/rtk"
  fi
  "$RBIN/claude" --version
  "$RBIN/codex" --version
  "$RBIN/node" --version
  "$RBIN/hermes" --version
  "$RBIN/python3" --version
  "$RBIN/rg" --version
  "$RBIN/ffmpeg" -version
  "$RUNTIME/ollama/ollama" --version
  "$SLOT/rtk" --version
  echo "  offline runtime bundled for $ARCH"
fi

# ---- bundle the logo + build an .icns app icon from bot.png ----
if [ -f "$HERE/bot.png" ]; then
  cp "$HERE/bot.png" "$RES/bot.png"
  echo "› Building app icon…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for sz in 16 32 64 128 256 512; do
    sips -z $sz $sz "$HERE/bot.png" --out "$ICONSET/icon_${sz}x${sz}.png" >/dev/null 2>&1 || true
    dbl=$((sz*2))
    sips -z $dbl $dbl "$HERE/bot.png" --out "$ICONSET/icon_${sz}x${sz}@2x.png" >/dev/null 2>&1 || true
  done
  if iconutil -c icns "$ICONSET" -o "$RES/AppIcon.icns" >/dev/null 2>&1; then
    echo "  icon ok"
  else
    echo "  (iconutil unavailable — app will use bot.png fallback)"
  fi
fi

# ---- ad-hoc codesign so Gatekeeper lets a local build run cleanly ----
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 && echo "› Ad-hoc signed." || echo "› (codesign skipped)"

echo "✓ Built: $APP"
