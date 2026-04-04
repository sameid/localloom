#!/bin/bash
set -euo pipefail

# LocalLoom - Build .app bundle script
# Usage: ./make-app.sh [--sign IDENTITY]

APP_NAME="LocalLoom"
BUILD_DIR=".build/release"
APP_BUNDLE="${APP_NAME}.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

SIGN_IDENTITY=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --sign)
            SIGN_IDENTITY="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            echo "Usage: $0 [--sign IDENTITY]"
            exit 1
            ;;
    esac
done

echo "==> Building ${APP_NAME} (Release)..."
swift build -c release

echo "==> Creating app bundle..."

# Clean previous bundle
rm -rf "${APP_BUNDLE}"

# Create directory structure
mkdir -p "${MACOS}"
mkdir -p "${RESOURCES}"

# Copy binary
cp "${BUILD_DIR}/${APP_NAME}" "${MACOS}/${APP_NAME}"

# Copy Info.plist
cp "Info.plist" "${CONTENTS}/Info.plist"

# Copy SPM resource bundles if they exist
if [ -d "${BUILD_DIR}/LocalLoom_LocalLoom.bundle" ]; then
    cp -R "${BUILD_DIR}/LocalLoom_LocalLoom.bundle" "${RESOURCES}/"
fi

# Copy ngrok binary if it exists in various locations
NGROK_SOURCE=""
if [ -f "Sources/LocalLoom/Resources/ngrok" ]; then
    NGROK_SOURCE="Sources/LocalLoom/Resources/ngrok"
elif [ -f "Resources/ngrok" ]; then
    NGROK_SOURCE="Resources/ngrok"
elif command -v ngrok &> /dev/null; then
    NGROK_PATH=$(command -v ngrok)
    echo "==> Found ngrok at ${NGROK_PATH}, copying to bundle..."
    NGROK_SOURCE="${NGROK_PATH}"
fi

if [ -n "${NGROK_SOURCE}" ]; then
    cp "${NGROK_SOURCE}" "${RESOURCES}/ngrok"
    chmod 755 "${RESOURCES}/ngrok"
    echo "==> Bundled ngrok binary"
else
    echo "==> WARNING: ngrok binary not found. The app will search for ngrok in PATH at runtime."
    echo "    To bundle ngrok, place it at Sources/LocalLoom/Resources/ngrok"
fi

# Set executable permissions
chmod 755 "${MACOS}/${APP_NAME}"

# Code sign if identity provided
if [ -n "${SIGN_IDENTITY}" ]; then
    echo "==> Code signing with identity: ${SIGN_IDENTITY}"
    codesign --force --deep --sign "${SIGN_IDENTITY}" \
        --entitlements "LocalLoom.entitlements" \
        --options runtime \
        "${APP_BUNDLE}"
    echo "==> Code signing complete"
else
    # Ad-hoc sign for local use
    echo "==> Ad-hoc code signing..."
    codesign --force --deep --sign - \
        --entitlements "LocalLoom.entitlements" \
        "${APP_BUNDLE}"
fi

echo ""
echo "==> Build complete!"
echo "    ${APP_BUNDLE}"
echo ""
echo "    To run: open ${APP_BUNDLE}"
echo "    To install: cp -R ${APP_BUNDLE} /Applications/"
echo ""

# Show bundle size
BUNDLE_SIZE=$(du -sh "${APP_BUNDLE}" | cut -f1)
echo "    Bundle size: ${BUNDLE_SIZE}"
