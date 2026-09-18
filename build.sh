#!/bin/bash
# Builds MemoryManager and wraps it in a .app bundle.
#
#   ./build.sh              release build  -> build/Memory Manager - MacOS.app
#   ./build.sh --run        build, then launch
#   ./build.sh --install    build, then install into /Applications and launch it there
#   ./build.sh debug        debug build
#   ./build.sh --icon       regenerate Resources/AppIcon.icns first
#
# Xcode is not required; the Command Line Tools toolchain is enough.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG=release
RUN=0
INSTALL=0
ICON=0
for arg in "$@"; do
	case "$arg" in
		debug) CONFIG=debug ;;
		release) CONFIG=release ;;
		--run|-r) RUN=1 ;;
		--install|-i) INSTALL=1 ;;
		--icon) ICON=1 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

APP_NAME="Memory Manager - MacOS"
BUNDLE="build/${APP_NAME}.app"
INSTALLED="/Applications/${APP_NAME}.app"

if [ "$ICON" -eq 1 ] || [ ! -f Resources/AppIcon.icns ]; then
	echo "==> rendering app icon"
	swift Resources/make-icon.swift
fi

echo "==> swift build -c ${CONFIG}"
swift build -c "$CONFIG"
BINARY="$(swift build -c "$CONFIG" --show-bin-path)/MemoryManager"

echo "==> assembling ${BUNDLE}"
rm -rf "$BUNDLE"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "$BINARY" "${BUNDLE}/Contents/MacOS/MemoryManager"
cp Resources/Info.plist "${BUNDLE}/Contents/Info.plist"
cp Resources/AppIcon.icns "${BUNDLE}/Contents/Resources/AppIcon.icns"

# Ad-hoc signature. Without one, macOS re-prompts for folder access on every launch
# and the app cannot keep a stable identity in Privacy & Security.
codesign --force --sign - --timestamp=none "$BUNDLE" >/dev/null 2>&1 \
	|| echo "    (codesign failed; the app still runs but will re-ask for folder access)"

echo "==> built ${BUNDLE}"

if [ "$INSTALL" -eq 1 ]; then
	echo "==> installing to ${INSTALLED}"
	# Quit a running copy first, or the replace fails while the binary is mapped.
	pkill -f "${INSTALLED}/Contents/MacOS/MemoryManager" 2>/dev/null || true
	sleep 1
	rm -rf "$INSTALLED"
	cp -R "$BUNDLE" "$INSTALLED"
	# Nudge Launch Services so the icon and Spotlight entry refresh immediately.
	touch "$INSTALLED"
	/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister \
		-f "$INSTALLED" >/dev/null 2>&1 || true
	echo "==> installed. It is now in Launchpad and Spotlight as \"${APP_NAME}\"."
fi

if [ "$RUN" -eq 1 ] || [ "$INSTALL" -eq 1 ]; then
	if [ "$INSTALL" -eq 1 ]; then
		open "$INSTALLED"
	else
		open "$BUNDLE"
	fi
fi
