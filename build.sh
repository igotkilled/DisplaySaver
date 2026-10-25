#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DisplaySaver"
APP_BUNDLE="${APP_NAME}.app"
TMP_BUILD="/tmp/${APP_NAME}_build"
TMP_BUNDLE="${TMP_BUILD}/${APP_BUNDLE}"
CONTENTS_DIR="${TMP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

echo "Compiling ${APP_NAME}..."
rm -rf "${TMP_BUILD}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}" "${TMP_BUILD}/Sources"
cp -R Sources/DisplaySaver "${TMP_BUILD}/Sources/"
xattr -cr "${TMP_BUILD}/Sources" || true

swiftc \
    -O \
    -module-cache-path /tmp/swift-module-cache \
    -target arm64-apple-macosx13.0 \
    -framework AppKit \
    -framework SwiftUI \
    -framework CoreGraphics \
    -framework IOKit \
    -framework ServiceManagement \
    "${TMP_BUILD}/Sources/DisplaySaver/"*.swift \
    -o "${MACOS_DIR}/${APP_NAME}"

cp Info.plist "${CONTENTS_DIR}/Info.plist"
if [ -f "AppIcon.icns" ]; then
    cp AppIcon.icns "${RESOURCES_DIR}/AppIcon.icns"
fi

xattr -cr "${TMP_BUNDLE}" || true

# Automatically pick up Developer ID Application or Apple Development certificate if available in Keychain,
# falling back to ad-hoc signing ("-") on CI or machines without an Apple Developer certificate.
SIGN_IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -n 1 | awk '{print $2}' || true)
fi
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Apple Development: JAMES MICHAEL SAVOIE" | head -n 1 | awk '{print $2}' || true)
fi
if [ -z "${SIGN_IDENTITY}" ]; then
    SIGN_IDENTITY="-"
fi

echo "Signing ${APP_BUNDLE} with identity: ${SIGN_IDENTITY}..."
if [ "${SIGN_IDENTITY}" = "-" ]; then
    codesign --force --deep --sign - --identifier com.jamessavoie.DisplaySaver "${TMP_BUNDLE}"
else
    codesign --force --deep --options runtime --sign "${SIGN_IDENTITY}" --identifier com.jamessavoie.DisplaySaver "${TMP_BUNDLE}"
fi

rm -rf "${APP_BUNDLE}"
cp -R "${TMP_BUNDLE}" "${APP_BUNDLE}"
cp -R "${TMP_BUNDLE}" "/Applications/${APP_BUNDLE}" 2>/dev/null || true

echo "Built and signed ${APP_BUNDLE} successfully!"
