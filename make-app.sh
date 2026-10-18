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
if [ -s "Sources/LocalLoom/Resources/ngrok" ]; then
    NGROK_SOURCE="Sources/LocalLoom/Resources/ngrok"
elif [ -s "Resources/ngrok" ]; then
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

# Bundle Node.js and localloom-server for "This Mac" mode. Official Node builds only link
# system libraries (unlike Homebrew's), so the bundled copy runs on any Mac. Built for
# this machine's architecture only.
NODE_VERSION="24.18.0"
case "$(uname -m)" in
    arm64)  NODE_ARCH="arm64"; NODE_SHA256="e1a97e14c99c803e96c7339403282ea05a499c32f8d83defe9ef5ec66f979ed1" ;;
    x86_64) NODE_ARCH="x64";   NODE_SHA256="dfd0dbd3e721503434df7b7205e719f61b3a3a31b2bcf9729b8b91fea240f080" ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
NODE_DIST="node-v${NODE_VERSION}-darwin-${NODE_ARCH}"
NODE_CACHE=".build/node"

if [ ! -f "${NODE_CACHE}/${NODE_DIST}/bin/node" ]; then
    echo "==> Downloading Node.js ${NODE_VERSION} (${NODE_ARCH})..."
    mkdir -p "${NODE_CACHE}"
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${NODE_DIST}.tar.gz" -o "${NODE_CACHE}/${NODE_DIST}.tar.gz"
    echo "${NODE_SHA256}  ${NODE_CACHE}/${NODE_DIST}.tar.gz" | shasum -a 256 -c - >/dev/null
    tar -xzf "${NODE_CACHE}/${NODE_DIST}.tar.gz" -C "${NODE_CACHE}" "${NODE_DIST}/bin/node"
    rm "${NODE_CACHE}/${NODE_DIST}.tar.gz"
fi

cp "${NODE_CACHE}/${NODE_DIST}/bin/node" "${RESOURCES}/node"
chmod 755 "${RESOURCES}/node"
mkdir -p "${RESOURCES}/server"
cp -R server/package.json server/src "${RESOURCES}/server/"
echo "==> Bundled Node.js ${NODE_VERSION} and localloom-server"

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
