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

# ---- full offline runtime: Node + Claude Code + Codex + Ollama -----------------
# Set HYDRA_THIN_BUILD=1 only for a developer build. Release builds intentionally
# carry the complete architecture-matched runtime and can be several gigabytes.
if [ "${HYDRA_THIN_BUILD:-0}" != "1" ]; then
  echo "› Bundling complete offline CLI/runtime payload…"
  RUNTIME="$RES/runtime"; RBIN="$RUNTIME/bin"; RAPP="$RUNTIME/app"
  rm -rf "$RUNTIME"; mkdir -p "$RBIN" "$RAPP" "$RUNTIME/ollama"
  ARCH="$(uname -m)"
  case "$ARCH" in
    arm64) NODE_ARCH="arm64"; RTK_PATTERN='darwin.*(aarch64|arm64)|(aarch64|arm64).*darwin' ;;
    x86_64) NODE_ARCH="x64"; RTK_PATTERN='darwin.*x86_64|x86_64.*darwin' ;;
    *) echo "Unsupported macOS architecture: $ARCH" >&2; exit 1 ;;
  esac
  TMP_RUNTIME="$(mktemp -d)"
  trap 'rm -rf "$TMP_RUNTIME"' EXIT
  NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json | /usr/bin/python3 -c 'import json,sys; print(next(x["version"] for x in json.load(sys.stdin) if x["lts"]))')"
  curl -fsSL "https://nodejs.org/dist/$NODE_VER/node-$NODE_VER-darwin-$NODE_ARCH.tar.gz" -o "$TMP_RUNTIME/node.tgz"
  tar -xzf "$TMP_RUNTIME/node.tgz" -C "$TMP_RUNTIME"
  cp -R "$TMP_RUNTIME/node-$NODE_VER-darwin-$NODE_ARCH/." "$RBIN/"
  ln -sf bin/node "$RBIN/node"; ln -sf bin/npm "$RBIN/npm"; ln -sf bin/npx "$RBIN/npx"
  "$RBIN/npm" install --prefix "$RAPP" --omit=dev --no-fund --no-audit \
    @anthropic-ai/claude-code@latest @openai/codex@latest
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
  curl -fsSL https://ollama.com/download/ollama-darwin.tgz -o "$TMP_RUNTIME/ollama.tgz"
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
  SLOT="$RES/tools/$([ "$ARCH" = arm64 ] && echo mac-arm64 || echo mac-x64)"
  mkdir -p "$SLOT"
  if [ ! -x "$SLOT/rtk" ]; then
    RTK_URL="$(curl -fsSL https://api.github.com/repos/rtk-ai/rtk/releases/latest | /usr/bin/python3 -c 'import json,re,sys; d=json.load(sys.stdin); p=re.compile(sys.argv[1],re.I); print(next((a["browser_download_url"] for a in d["assets"] if p.search(a["name"]) and (a["name"].endswith(".tar.gz") or a["name"].endswith(".zip"))), ""))' "$RTK_PATTERN")"
    [ -n "$RTK_URL" ] || { echo "RTK release for $ARCH not found" >&2; exit 1; }
    curl -fsSL "$RTK_URL" -o "$TMP_RUNTIME/rtk.archive"
    case "$RTK_URL" in *.zip) unzip -q "$TMP_RUNTIME/rtk.archive" -d "$TMP_RUNTIME/rtk";; *) mkdir -p "$TMP_RUNTIME/rtk"; tar -xzf "$TMP_RUNTIME/rtk.archive" -C "$TMP_RUNTIME/rtk";; esac
    RTK_BIN="$(find "$TMP_RUNTIME/rtk" -type f -name rtk | head -1)"
    [ -n "$RTK_BIN" ] || { echo "RTK binary missing from archive" >&2; exit 1; }
    cp "$RTK_BIN" "$SLOT/rtk"; chmod +x "$SLOT/rtk"
  fi
  "$RBIN/claude" --version
  "$RBIN/codex" --version
  "$RBIN/node" --version
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
