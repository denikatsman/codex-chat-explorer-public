#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release
bin="$(swift build -c release --show-bin-path)"
app="$PWD/dist/Codex Chat Explorer.app"
if [ -e "$app" ]; then
  echo "Remove or move the existing build at $app before rebuilding." >&2
  exit 1
fi
mkdir -p "$app/Contents/MacOS" "$app/Contents/Helpers" "$app/Contents/Resources"
cp "$bin/CodexChats" "$app/Contents/MacOS/CodexChats"
cp "$bin/ExplorerModelWorker" "$bin/SemanticModelWorker" "$app/Contents/Helpers/"
cp -R Assets/CanvasMarkdown "$app/Contents/Resources/CanvasMarkdown"
cp Assets/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp Sources/CMarkdown/LICENSE.md "$app/Contents/Resources/CanvasMarkdown/md4c-LICENSE.md"
cp Prototypes/FlightRecorder/diagnostics.py "$app/Contents/Resources/diagnostics.py"
/usr/bin/python3 - "$app/Contents/Info.plist" <<'PY'
import plistlib, sys
info = {'CFBundleExecutable': 'CodexChats', 'CFBundleIdentifier': 'local.codex-chat-explorer.app',
        'CFBundleName': 'Codex Chat Explorer', 'CFBundleDisplayName': 'Codex Chat Explorer',
        'CFBundlePackageType': 'APPL', 'CFBundleIconFile': 'AppIcon.icns', 'CFBundleShortVersionString': '0.19.1',
        'CFBundleVersion': '62', 'LSMinimumSystemVersion': '13.0', 'NSHighResolutionCapable': True}
with open(sys.argv[1], 'wb') as f:
    plistlib.dump(info, f)
PY
codesign --force --sign - "$app/Contents/Helpers/ExplorerModelWorker"
codesign --force --sign - "$app/Contents/Helpers/SemanticModelWorker"
codesign --force --sign - "$app"
printf 'Built %s\n' "$app"
