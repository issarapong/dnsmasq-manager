#!/bin/bash
# ประกอบ Masq.app จาก executable ที่ SwiftPM สร้าง
# ใช้ ad-hoc signature พอ เพราะเป็นเครื่องมือที่รันเฉพาะเครื่องตัวเอง
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Masq.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Masq"

echo "==> ประกอบ $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Masq"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> ลงลายเซ็นแบบ ad-hoc"
codesign --force --deep --sign - "$APP"

echo
echo "เสร็จแล้ว: $(pwd)/$APP"
echo "เปิดด้วย:  open $APP"
echo "ติดตั้ง:   cp -R $APP /Applications/"
