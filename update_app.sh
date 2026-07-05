#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="WallpaperVideo"
LOCAL_APP="${APP_NAME}.app"
INSTALLED_APP="/Applications/${APP_NAME}.app"

echo "==> Building latest version"
./build_app.sh

WAS_RUNNING=false
if pgrep -x "${APP_NAME}" >/dev/null 2>&1; then
    WAS_RUNNING=true
    echo "==> Quitting running instance"
    pkill -x "${APP_NAME}"
    sleep 1
fi

echo "==> Installing to ${INSTALLED_APP}"
rm -rf "${INSTALLED_APP}"
cp -R "${LOCAL_APP}" "${INSTALLED_APP}"

if [ "${WAS_RUNNING}" = true ]; then
    echo "==> Relaunching"
    open "${INSTALLED_APP}"
fi

echo "==> Update complete: ${INSTALLED_APP}"
