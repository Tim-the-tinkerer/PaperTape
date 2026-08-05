#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

LAUNCH=true
for arg in "$@"; do
    case "${arg}" in
        --no-launch) LAUNCH=false ;;
    esac
done

APP="PaperTape.app"
BUNDLE_ID="com.papertape.app"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Version comes from AppInfo.plist — the single source of truth.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' AppInfo.plist 2>/dev/null || true)"
VERSION="${VERSION:-?}"

if [[ ! -f Assets/AppIcon.icns ]]; then
    echo "Generating app icon..."
    swift Scripts/GenerateAppIcon.swift
fi

echo "Building PaperTape ${VERSION} (release)..."
swift build -c release

BIN=".build/release/PaperTape"
if [[ ! -x "${BIN}" ]]; then
    echo "error: expected binary not found at ${BIN}" >&2
    exit 1
fi

echo "Assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
mkdir -p "${APP}/Contents/Resources"
cp "${BIN}" "${APP}/Contents/MacOS/PaperTape"
chmod +x "${APP}/Contents/MacOS/PaperTape"
cp AppInfo.plist "${APP}/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleGetInfoString PaperTape ${VERSION}" \
    "${APP}/Contents/Info.plist" 2>/dev/null || true

if [[ -f Assets/AppIcon.icns ]]; then
    cp Assets/AppIcon.icns "${APP}/Contents/Resources/"
fi

echo "Signing ${APP}..."
xattr -cr "${APP}" 2>/dev/null || true
codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}/Contents/MacOS/PaperTape"
codesign --force --sign - --identifier "${BUNDLE_ID}" --timestamp=none "${APP}"

plutil -lint "${APP}/Contents/Info.plist" >/dev/null
codesign --verify --verbose=2 "${APP}" 2>/dev/null || codesign --verify "${APP}"

if [[ -x /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister ]]; then
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(pwd)/${APP}" 2>/dev/null || true
fi

echo "Done: ${APP} (v${VERSION})"
if [[ "${LAUNCH}" == "true" ]]; then
    pkill -x PaperTape 2>/dev/null || true
    sleep 0.2
    echo "Launching..."
    open "${APP}"
fi
