#!/bin/bash
# build dnsdev.app — universal binary (Intel + Apple Silicon) เซ็นแบบ ad-hoc
#
# ทำ 2 arch เสมอ เพราะแอปนี้ตั้งใจก็อปข้ามเครื่องได้ และ Sys.prefix ก็หา
# Homebrew prefix ให้เองอยู่แล้วทั้งสองแบบ
set -euo pipefail
cd "$(dirname "$0")"

APP="$HOME/Applications/dnsdev.app"
MIN="14.0"

echo "==> compile app"
for arch in x86_64 arm64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos$MIN" -o "dnsdev-$arch" App.swift
done
lipo -create -output dnsdev dnsdev-x86_64 dnsdev-arm64

# dnsdevd — ตัว proxy ชั้น https  อยู่คนละไบนารีเพราะ launchd ต้องรันมันเดี่ยว ๆ
# เป็น LaunchAgent ตลอดเวลา ส่วน app เป็นแค่หน้าจอที่เปิด ๆ ปิด ๆ
echo "==> compile proxy"
for arch in x86_64 arm64; do
  swiftc -O -parse-as-library -target "$arch-apple-macos$MIN" \
    -o "../proxy/dnsdevd-$arch" ../proxy/Proxy.swift
done
lipo -create -output ../proxy/dnsdevd ../proxy/dnsdevd-arm64 ../proxy/dnsdevd-x86_64
rm -f ../proxy/dnsdevd-arm64 ../proxy/dnsdevd-x86_64

echo "==> bundle -> $APP"
# ปิดตัวที่รันอยู่ก่อน ไม่งั้นเขียนทับ binary ไม่ได้
pkill -f "dnsdev.app/Contents/MacOS/dnsdev" 2>/dev/null || true
sleep 1
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp dnsdev "$APP/Contents/MacOS/dnsdev"
cp ../proxy/dnsdevd "$APP/Contents/MacOS/dnsdevd"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key><string>dnsdev</string>
	<key>CFBundleDisplayName</key><string>dnsdev</string>
	<key>CFBundleExecutable</key><string>dnsdev</string>
	<key>CFBundleIdentifier</key><string>local.dnsdev.menubar</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.1</string>
	<key>CFBundleVersion</key><string>2</string>
	<key>LSMinimumSystemVersion</key><string>$MIN</string>
	<key>LSUIElement</key><true/>
	<key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> sign"
codesign --force --deep --sign - "$APP"

echo "เสร็จ: $APP"
