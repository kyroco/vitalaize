#!/bin/bash
# Builds VitalAIze.app and a signed installer package for it.
#
#   macos/build.sh                                  build and sign
#   macos/build.sh --notary-profile NAME            also notarize and staple
#
# Signs with the Developer ID certificates in this Mac's keychain, the same
# ones korium-cli's packaging uses: "Developer ID Application" for the app
# and everything inside it, "Developer ID Installer" for the .pkg.
#
# Notarizing needs a saved notarytool login (made once with
# `xcrun notarytool store-credentials NAME ...`). Without one the package is
# signed but not notarized, and other Macs warn before opening it.
#
# The app holds the board (an Elixir release with its own Erlang) and a
# small SwiftUI setup app. Apple silicon only: the release is built here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/macos/build"
DIST="$ROOT/macos/dist"
APP="$OUT/VitalAIze.app"
NOTARY_PROFILE=""
BUNDLE_ID="ai.kyroco.wallboard"

while [ $# -gt 0 ]; do
  case "$1" in
    --notary-profile) NOTARY_PROFILE="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Optional: a file that puts a pinned Elixir and Erlang on PATH, for Macs
# that keep more than one. Set VITALAIZE_TOOLCHAIN to its path.
if [ -n "${VITALAIZE_TOOLCHAIN:-}" ] && [ -f "$VITALAIZE_TOOLCHAIN" ]; then
  # shellcheck disable=SC1090
  . "$VITALAIZE_TOOLCHAIN"
fi

APP_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | head -1)
PKG_ID=$(security find-identity -v | sed -n 's/.*"\(Developer ID Installer:.*\)"/\1/p' | head -1)
[ -n "$APP_ID" ] || { echo "No Developer ID Application certificate in the keychain." >&2; exit 1; }
[ -n "$PKG_ID" ] || { echo "No Developer ID Installer certificate in the keychain." >&2; exit 1; }

VERSION=$(sed -n 's/^ *version: "\(.*\)",$/\1/p' "$ROOT/mix.exs" | head -1)
BUILD=$(git -C "$ROOT" rev-list --count HEAD)
echo "VitalAIze $VERSION ($BUILD)"
echo "Signing as:   $APP_ID"
echo "Package as:   $PKG_ID"

rm -rf "$OUT"
mkdir -p "$OUT" "$DIST"

echo "==> Building the board"
(
  cd "$ROOT"
  MIX_ENV=prod mix deps.get --only prod >/dev/null
  MIX_ENV=prod mix release --overwrite --path "$OUT/release" >/dev/null
)

echo "==> Building the app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macos13.0 -O \
  "$ROOT"/macos/Wallboard/*.swift -o "$APP/Contents/MacOS/VitalAIze"
mv "$OUT/release" "$APP/Contents/Resources/board"
# The release leaves a zipped copy of itself beside it. The app never uses
# it, and Apple's notary opens it and rejects the unsigned programs inside.
rm -f "$APP"/Contents/Resources/board/*.tar.gz

echo "==> Making the icon"
xcrun swift "$ROOT/macos/make-icon.swift" "$OUT/icon.png"
ICONSET="$OUT/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$OUT/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$OUT/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>VitalAIze</string>
  <key>CFBundleDisplayName</key><string>Kyroco VitalAIze</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>VitalAIze</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Kyroco, llc</string>
  <key>NSLocalNetworkUsageDescription</key>
  <string>VitalAIze looks for a hub on your network and sends it this Mac's Claude sessions.</string>
  <key>NSBonjourServices</key><array><string>_wallboard._tcp</string></array>
</dict>
</plist>
EOF

echo "==> Signing everything inside"
# The Erlang engine compiles code as it runs (its JIT), which the hardened
# runtime allows only with this one entitlement.
cat > "$OUT/beam.entitlements" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.cs.allow-jit</key><true/>
</dict></plist>
EOF

sign() {
  codesign --force --timestamp --options runtime -s "$APP_ID" "$@"
}

# Libraries first, then programs, then the app around them.
MACHO=$(python3 - "$APP/Contents/Resources/board" <<'PY'
import os, sys
magic = (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xfe\xed\xfa\xcf')
libs, bins = [], []
for d, _, files in os.walk(sys.argv[1]):
    for n in files:
        p = os.path.join(d, n)
        if os.path.islink(p):
            continue
        with open(p, 'rb') as f:
            if f.read(4) not in magic:
                continue
        (libs if n.endswith(('.so', '.dylib')) else bins).append(p)
print("\n".join(libs + bins))
PY
)
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    */beam.smp) sign --entitlements "$OUT/beam.entitlements" "$f" ;;
    *) sign "$f" ;;
  esac
done <<< "$MACHO"
sign "$APP"
codesign --verify --deep --strict "$APP"
echo "Signed $(printf '%s\n' "$MACHO" | grep -c .) binaries inside, and the app."

echo "==> Packaging"
PKG_ROOT="$OUT/pkgroot"
# Start empty: the board's files are read-only, so copying over an old copy fails.
rm -rf "$PKG_ROOT"
mkdir -p "$PKG_ROOT"
ditto "$APP" "$PKG_ROOT/VitalAIze.app"
pkgbuild --analyze --root "$PKG_ROOT" "$OUT/component.plist" >/dev/null
# Install to /Applications even when another copy of the app sits elsewhere.
/usr/libexec/PlistBuddy -c "Add :0:BundleIsRelocatable bool false" "$OUT/component.plist"
# postinstall restarts a board running from the old copy, then opens VitalAIze
# so setup starts right away.
chmod +x "$ROOT/macos/installer/scripts/postinstall"
# Clear file attributes so the package carries no "._" copies of the script.
xattr -cr "$ROOT/macos/installer/scripts"
pkgbuild --root "$PKG_ROOT" --component-plist "$OUT/component.plist" \
  --identifier "$BUNDLE_ID" --version "$VERSION" --install-location /Applications \
  --scripts "$ROOT/macos/installer/scripts" \
  --sign "$PKG_ID" "$OUT/VitalAIze-component.pkg" >/dev/null

# The installer's own pages: what VitalAIze is before, what to do next after.
DIST_XML="$OUT/distribution.xml"
productbuild --synthesize --package "$OUT/VitalAIze-component.pkg" "$DIST_XML" >/dev/null
python3 - "$DIST_XML" <<'PY'
import sys
path = sys.argv[1]
s = open(path).read()
pages = ('    <title>Kyroco VitalAIze</title>\n'
         '    <welcome file="welcome.html" mime-type="text/html"/>\n'
         '    <conclusion file="conclusion.html" mime-type="text/html"/>\n')
import re
s = re.sub(r'(<installer-gui-script[^>]*>\n)', lambda m: m.group(1) + pages, s, count=1)
assert 'welcome.html' in s, "could not add the installer pages"
open(path, 'w').write(s)
PY
PKG="$DIST/VitalAIze-$VERSION.pkg"
productbuild --distribution "$DIST_XML" --resources "$ROOT/macos/installer" \
  --package-path "$OUT" --sign "$PKG_ID" "$PKG" >/dev/null
SIG=$(pkgutil --check-signature "$PKG"); sed -n "2,3p" <<< "$SIG"

if [ -n "$NOTARY_PROFILE" ]; then
  echo "==> Notarizing (this takes a few minutes)"
  xcrun notarytool submit "$PKG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$PKG"
  spctl --assess --type install -vv "$PKG"
else
  echo "Not notarized: pass --notary-profile NAME to notarize and staple."
fi

echo
echo "Built $PKG"
