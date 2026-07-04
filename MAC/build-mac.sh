#!/usr/bin/env bash
# Build "Claude Manager.app" — a native SwiftUI macOS app — from the Swift sources
# in ./mac. Requires the Xcode Command Line Tools (swiftc). No Xcode project needed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/Claude Manager.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RES="$CONTENTS/Resources"
BIN="$MACOS/Claude Manager"

echo "› Building with Swift Package Manager (pulls in SwiftTerm on first run)…"
rm -rf "$APP"
mkdir -p "$MACOS" "$RES"
( cd "$HERE" && swift build -c release )
BUILT="$HERE/.build/release/ClaudeManager"
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
  <key>CFBundleName</key>            <string>Claude Manager</string>
  <key>CFBundleDisplayName</key>     <string>Claude Manager</string>
  <key>CFBundleIdentifier</key>      <string>com.claudemanager.mac</string>
  <key>CFBundleVersion</key>         <string>1.0.0</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleExecutable</key>      <string>Claude Manager</string>
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
  <key>NSDesktopFolderUsageDescription</key>  <string>Claude Manager opens Claude sessions in project folders you choose, including ones on your Desktop.</string>
  <key>NSDocumentsFolderUsageDescription</key><string>Claude Manager opens Claude sessions in project folders you choose, including ones in Documents.</string>
  <key>NSDownloadsFolderUsageDescription</key><string>Claude Manager opens Claude sessions in project folders you choose, including ones in Downloads.</string>
  <key>NSAppleEventsUsageDescription</key>    <string>Claude Manager only uses Apple Events if you ask it to control an external Terminal window.</string>
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
