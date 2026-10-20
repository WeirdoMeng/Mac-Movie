#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/build-app.sh

APP="dist/摸鱼视界.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
NAME="摸鱼视界-${VERSION}-arm64"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/moyu-installer.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT
mkdir -p "$STAGING/payload" "$STAGING/disk"
codesign --verify --deep --strict "$APP"
ditto "$APP" "$STAGING/payload/摸鱼视界.app"

# Install to the standard Applications directory instead of relocating to an
# arbitrary older copy found on the recipient's Mac.
pkgbuild --analyze --root "$STAGING/payload" "$STAGING/components.plist"
/usr/bin/python3 - "$STAGING/components.plist" <<'PY'
import plistlib, sys
from pathlib import Path
path = Path(sys.argv[1])
components = plistlib.loads(path.read_bytes())
for component in components:
    component['BundleIsRelocatable'] = False
path.write_bytes(plistlib.dumps(components))
PY
pkgbuild --root "$STAGING/payload" --component-plist "$STAGING/components.plist" \
    --identifier local.macmovie.demo.pkg --version "$VERSION" \
    --install-location /Applications --ownership recommended "dist/$NAME.pkg"

ditto "$APP" "$STAGING/disk/摸鱼视界.app"
ln -s /Applications "$STAGING/disk/应用程序"
cat > "$STAGING/disk/安装说明.txt" <<'TEXT'
摸鱼视界

安装：将“摸鱼视界.app”拖到旁边的“应用程序”，然后从应用程序打开。
更新前请退出旧版本。收藏、历史和自定义快捷键会保留。

系统要求：macOS 13 或更高版本，Apple Silicon（M 系列）芯片。
当前安装包没有 Apple 开发者签名和公证，其他电脑可能显示安全提示。
本文件为测试版本，尚未验证 Intel Mac 兼容性。
TEXT
hdiutil create -volname "摸鱼视界" -srcfolder "$STAGING/disk" \
    -format UDZO -fs HFS+ -ov "dist/$NAME.dmg"
hdiutil verify "dist/$NAME.dmg"
printf 'Packaged: dist/%s.pkg\nPackaged: dist/%s.dmg\n' "$NAME" "$NAME"
