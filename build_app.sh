#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="WallpaperVideo"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"

echo "==> Building release binary"
swift build -c release

echo "==> Assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
cp "Resources/MenuBarIcon.png" "${APP_BUNDLE}/Contents/Resources/MenuBarIcon.png"

echo "==> Ad-hoc code signing"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Done: $(pwd)/${APP_BUNDLE}"
echo "Open with: open ${APP_BUNDLE}"
