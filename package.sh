#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DisplaySaver"
VERSION="1.1"
APP_BUNDLE="${APP_NAME}.app"
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
PKG_NAME="${APP_NAME}-${VERSION}-Installer.pkg"

# 1. Build the latest app bundle first
./build.sh

echo "Creating ${DMG_NAME} (Drag-and-Drop Disk Image)..."
TMP_DMG_DIR="/tmp/${APP_NAME}_dmg_staging"
TMP_DMG_PATH="/tmp/${DMG_NAME}"
rm -rf "${TMP_DMG_DIR}" "${TMP_DMG_PATH}" "${DMG_NAME}"
mkdir -p "${TMP_DMG_DIR}"

cp -R "/tmp/${APP_NAME}_build/${APP_BUNDLE}" "${TMP_DMG_DIR}/${APP_BUNDLE}"
ln -s /Applications "${TMP_DMG_DIR}/Applications"
xattr -cr "${TMP_DMG_DIR}" || true

hdiutil create \
    -volname "${APP_NAME}" \
    -srcfolder "${TMP_DMG_DIR}" \
    -ov \
    -format UDZO \
    "${TMP_DMG_PATH}"

cp "${TMP_DMG_PATH}" "${DMG_NAME}"

echo "Creating ${PKG_NAME} (Standard macOS Installer Package)..."
TMP_PKG_PATH="/tmp/${PKG_NAME}"
rm -f "${TMP_PKG_PATH}" "${PKG_NAME}"

pkgbuild \
    --component "/tmp/${APP_NAME}_build/${APP_BUNDLE}" \
    --install-location "/Applications" \
    --identifier "com.jamessavoie.DisplaySaver.pkg" \
    --version "${VERSION}" \
    "${TMP_PKG_PATH}"

cp "${TMP_PKG_PATH}" "${PKG_NAME}"

echo "===================================================="
echo "Created distributable installers:"
echo "  1. ${DMG_NAME} (Drag-to-Applications DMG)"
echo "  2. ${PKG_NAME} (One-click /Applications Installer PKG)"
echo "===================================================="
