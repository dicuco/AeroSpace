#!/usr/bin/env bash
# Build an optimized AeroSpace.app without Xcode.
#
# build-release.sh needs Xcode: it drives xcodebuild to produce the App Bundle.
# This script does the packaging by hand instead, so an optimized build is
# possible with only the Command Line Tools installed.
#
# It also works around two things that otherwise break a Command-Line-Tools-only
# build. Both are applied to a throwaway copy of the tree, never to your sources,
# so this fork stays rebasable onto upstream:
#
#   1. SwiftUI's @State is a macro in recent SDKs, and the macro plugin ships
#      inside Xcode. Without it the module does not compile, so the two uses in
#      the tree are expanded by hand into their property-wrapper equivalent.
#   2. AeroSpace resets its own Accessibility approval whenever the first
#      permission check fails, so that a rebuild (new signature) cannot leave a
#      stale grant behind. With a locally signed build that erases the approval
#      the user just granted, making the app impossible to authorize.
#
# Usage:
#   ./build-local.sh              build to .local/AeroSpace.app
#   ./build-local.sh --install    also install it to /Applications

set -euo pipefail
cd "$(dirname "$0")"
REPO="$PWD"
BUILD_DIR="$REPO/.local-build"   # persistent, so rebuilds are incremental
OUT_DIR="$REPO/.local"
APP="$OUT_DIR/AeroSpace.app"

install=0
while test $# -gt 0; do
    case $1 in
        --install) install=1; shift ;;
        *) echo "Unknown option $1" >&2; exit 1 ;;
    esac
done

echo "==> Syncing sources to $BUILD_DIR"
mkdir -p "$BUILD_DIR"
rsync -a --delete \
    --exclude='.git' --exclude='.build' --exclude='.local' --exclude='.local-build' \
    --exclude='.debug' --exclude='.release' --exclude='.deps' \
    "$REPO/" "$BUILD_DIR/"
# getDefaultConfigUrlFromProject() walks up from #filePath looking for a .git
# directory, and loops forever if it never finds one. The packaged app reads its
# config from Contents/Resources instead, but keep this as a backstop.
mkdir -p "$BUILD_DIR/.git"

echo "==> Applying local-build workarounds (on the copy only)"
python3 - "$BUILD_DIR" <<'PYEOF'
import pathlib, sys
base = pathlib.Path(sys.argv[1])

def patch(rel, old, new, label):
    p = base / rel
    s = p.read_text()
    if new in s:
        print(f"    - {label}: already applied")
        return
    if old not in s:
        sys.exit(f"ERROR: {label}: pattern not found in {rel}.\n"
                 f"Upstream changed this code; update build-local.sh.")
    p.write_text(s.replace(old, new))
    print(f"    - {label}: ok")

patch("Sources/AppBundle/ui/SecureInputView.swift",
      "    @State var isMinimized: Bool = true\n",
      "    private var _isMinimized = State(initialValue: true)\n"
      "    var isMinimized: Bool {\n"
      "        get { _isMinimized.wrappedValue }\n"
      "        nonmutating set { _isMinimized.wrappedValue = newValue }\n"
      "    }\n",
      "@State shim (SecureInputView)")

patch("Sources/AppBundle/ui/VolumeView.swift",
      "    @State var volume: Float? = nil\n",
      "    private var _volume: State<Float?>\n"
      "    var volume: Float? {\n"
      "        get { _volume.wrappedValue }\n"
      "        nonmutating set { _volume.wrappedValue = newValue }\n"
      "    }\n"
      "    init(volume: Float? = nil) { self._volume = State(initialValue: volume) }\n",
      "@State shim (VolumeView)")

patch("Sources/AppBundle/util/accessibility.swift",
      '    _ = try? Process.run(URL(filePath: "/usr/bin/tccutil"), arguments: ["reset", "Accessibility", aeroSpaceAppId])\n',
      "    // Disabled for locally signed builds: this would erase the approval the user just granted.\n",
      "Accessibility self-reset disabled")
PYEOF

echo "==> Building (release)"
cd "$BUILD_DIR"
swift build -c release --product AeroSpaceApp
swift build -c release --product aerospace
BIN_PATH="$(swift build -c release --product aerospace --show-bin-path)"
cd "$REPO"

echo "==> Packaging $APP"
rm -rf "$OUT_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD_DIR/.build/release/AeroSpaceApp" "$APP/Contents/MacOS/AeroSpace"
cp "$BIN_PATH/aerospace" "$OUT_DIR/aerospace"
cp docs/config-examples/default-config.toml "$APP/Contents/Resources/default-config.toml"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Icon: the real build uses actool to compile the asset catalog. iconutil can
# produce an equivalent .icns from the single source PNG.
if command -v iconutil > /dev/null && test -f resources/Assets.xcassets/AppIcon.appiconset/icon.png; then
    iconset="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        sips -z $size $size resources/Assets.xcassets/AppIcon.appiconset/icon.png \
            --out "$iconset/icon_${size}x${size}.png" > /dev/null 2>&1
        sips -z $((size * 2)) $((size * 2)) resources/Assets.xcassets/AppIcon.appiconset/icon.png \
            --out "$iconset/icon_${size}x${size}@2x.png" > /dev/null 2>&1
    done
    iconutil -c icns "$iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2> /dev/null \
        && echo "    - icon built"
fi

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>AeroSpace</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIdentifier</key>
	<string>bobko.aerospace</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>AeroSpace</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>0.0.0-LOCAL</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>13.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSPrincipalClass</key>
	<string>NSApplication</string>
</dict>
</plist>
PLIST

echo "==> Signing"
# Ad-hoc is enough for TCC as long as the signature is stable, i.e. as long as
# the bundle is not re-signed after the Accessibility approval is granted.
codesign --force --sign - --entitlements resources/AeroSpace.entitlements "$APP"
codesign --verify --strict "$APP"
codesign --force --sign - "$OUT_DIR/aerospace"

if test $install == 1; then
    echo "==> Installing to /Applications"
    if pgrep -x AeroSpace > /dev/null; then
        pkill -x AeroSpace || true
    fi
    rm -rf /Applications/AeroSpace.app
    cp -R "$APP" /Applications/AeroSpace.app
    echo "    - /Applications/AeroSpace.app"
fi

echo
echo "Done."
echo "  app: $APP"
echo "  cli: $OUT_DIR/aerospace"
