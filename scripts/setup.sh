#!/bin/bash
# Installs a decrypted Minecraft IPA into PlayCover, applies the settings that
# work, and patches in the macfix dylib.
#
# usage: scripts/setup.sh <minecraft.ipa>     install, configure and patch
#        scripts/setup.sh --patch-only         re-patch an installed app
#        scripts/setup.sh --patch-only --debuggable   same, attachable by Instruments/lldb
#        scripts/setup.sh --reset-playchain    fix "Couldn't add the Keychain Item" crashes
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE_ID=com.mojang.minecraftpe
PLAYCOVER=/Applications/PlayCover.app
CONTAINER="$HOME/Library/Containers/io.playcover.PlayCover"
APP_DIR="${APP_DIR:-$CONTAINER/Applications/$BUNDLE_ID.app}"
SETTINGS="${SETTINGS:-$CONTAINER/App Settings/$BUNDLE_ID.plist}"
BUILD="$ROOT/build"

die() { echo "error: $*" >&2; exit 1; }
step() { echo "==> $*"; }

quit_game() {
    local pid
    pid=$(pgrep -x minecraftpe || true)
    [ -z "$pid" ] && return
    step "Quitting Minecraft"
    kill -TERM $pid
    for _ in $(seq 1 10); do kill -0 $pid 2>/dev/null || return 0; sleep 1; done
    kill -KILL $pid
}

check_host() {
    [ "$(uname -m)" = arm64 ] || die "needs an Apple Silicon Mac"
    xcrun --find clang >/dev/null 2>&1 || die "install Xcode Command Line Tools: xcode-select --install"
    [ -d "$PLAYCOVER" ] || die "PlayCover not found in /Applications (see README)"
    local build
    build=$(defaults read "$PLAYCOVER/Contents/Info" CFBundleVersion 2>/dev/null || echo 0)
    if [ "$build" -lt 1620 ]; then
        echo "warning: PlayCover build $build is older than the nightly this was tested with (1620)." >&2
        echo "         Older builds crash on launch; see README." >&2
    fi
}

check_decrypted() {
    local ipa="$1" tmp info
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN
    unzip -q -o "$ipa" 'Payload/*.app/minecraftpe' -d "$tmp" || die "no Minecraft executable in $ipa"
    info=$(otool -l "$tmp"/Payload/*.app/minecraftpe) || die "could not read the executable in $ipa"
    case "$info" in
        *LC_ENCRYPTION_INFO_64*) ;;
        *) die "unexpected executable in $ipa (no encryption info)" ;;
    esac
    [[ "$info" == *"cryptid 0"* ]] || die "this IPA is still FairPlay-encrypted; PlayCover needs a decrypted one"
}

quit_playcover() {
    # PlayCover keeps app settings in memory and writes them back when it
    # launches an app, which would undo the settings applied below.
    pgrep -x PlayCover >/dev/null || return 0
    osascript -e 'quit app "PlayCover"' >/dev/null 2>&1 || true
    for _ in $(seq 1 10); do pgrep -x PlayCover >/dev/null || return 0; sleep 1; done
    die "quit PlayCover and run the script again"
}

install_ipa() {
    local ipa="$1"
    [ -f "$ipa" ] || die "no such file: $ipa"
    check_decrypted "$ipa"
    quit_game

    local exe="$APP_DIR/minecraftpe" before=0 last=""
    [ -f "$exe" ] && before=$(stat -f %m "$exe")
    step "Installing into PlayCover"
    open -a PlayCover "$ipa"
    # Done once the new executable exists, carries PlayTools, verifies, and has
    # stopped changing.
    for _ in $(seq 1 300); do
        sleep 1
        [ -f "$exe" ] && [ -f "$SETTINGS" ] || continue
        local now
        now=$(stat -f %m "$exe")
        [ "$now" -gt "$before" ] || continue
        [[ "$(otool -L "$exe")" == *PlayTools.framework* ]] || continue
        codesign -v "$APP_DIR" 2>/dev/null || continue
        if [ "$now" = "$last" ]; then
            quit_playcover
            return
        fi
        last=$now
    done
    die "PlayCover did not finish installing within 5 minutes"
}

reset_playchain() {
    # A keychain database left by an older PlayTools makes the game abort on
    # launch with "Couldn't add the Keychain Item".
    local chain="$CONTAINER/PlayChain"
    ls "$chain/$BUNDLE_ID".* >/dev/null 2>&1 || { step "No PlayChain database to reset"; return; }
    quit_game
    local backup="$chain/backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$backup"
    mv "$chain/$BUNDLE_ID".* "$backup/"
    step "Moved PlayChain database to $backup"
}

configure() {
    [ -f "$SETTINGS" ] || die "PlayCover settings not found; install the IPA first"
    quit_playcover
    step "Applying PlayCover settings"
    # Keymapping's fake mouse crashes the game; it has native mouse/keyboard support.
    plutil -replace keymapping -bool false "$SETTINGS"
    # 1080p at 16:10 matches a MacBook's fullscreen shape closely.
    plutil -replace resolution -integer 2 "$SETTINGS"
    plutil -replace aspectRatio -integer 2 "$SETTINGS"
    plutil -replace windowWidth -integer 1728 "$SETTINGS"
    plutil -replace windowHeight -integer 1080 "$SETTINGS"
    # GPU time scales with pixels: at 1.5 (2592x1620) busy scenes miss the 120 Hz budget.
    plutil -replace customScaler -float 1.25 "$SETTINGS"
}

patch_app() {
    [ -f "$APP_DIR/minecraftpe" ] || die "Minecraft is not installed in PlayCover"
    quit_game

    step "Building libmacfix.dylib"
    mkdir -p "$BUILD"
    local sdk
    sdk=$(xcrun --sdk macosx --show-sdk-path)
    xcrun clang -target arm64-apple-ios15.0-macabi \
        -isysroot "$sdk" -iframework "$sdk/System/iOSSupport/System/Library/Frameworks" \
        -dynamiclib -fobjc-arc -framework Foundation -framework GameController -framework QuartzCore \
        -framework UIKit -framework Metal -framework CoreImage -framework ImageIO -framework CoreGraphics -framework IOKit \
        -install_name @executable_path/Frameworks/libmacfix.dylib \
        -o "$BUILD/libmacfix.dylib" "$ROOT/macfix/macfix.m" "$ROOT/macfix/agent.m"
    codesign -f -s - "$BUILD/libmacfix.dylib"

    step "Patching the app"
    local ent="$BUILD/entitlements.plist"
    codesign -d --entitlements - --xml "$APP_DIR" > "$ent" 2>/dev/null
    # Profiling only: lets xctrace/lldb attach. Plain runs drop it again.
    /usr/libexec/PlistBuddy -c "Delete :com.apple.security.get-task-allow" "$ent" >/dev/null 2>&1 || true
    if [ "$DEBUGGABLE" = 1 ]; then
        /usr/libexec/PlistBuddy -c "Add :com.apple.security.get-task-allow bool true" "$ent"
    fi
    cp "$BUILD/libmacfix.dylib" "$APP_DIR/Frameworks/libmacfix.dylib"
    python3 "$ROOT/scripts/patch_app.py" "$APP_DIR/minecraftpe"
    # Marks the app as a game so fullscreen gets macOS Game Mode.
    plutil -replace LSApplicationCategoryType -string public.app-category.games "$APP_DIR/Info.plist"
    plutil -replace GCSupportsGameMode -bool true "$APP_DIR/Info.plist"
    codesign -f -s - --entitlements "$ent" "$APP_DIR"
    codesign -v "$APP_DIR"
}

DEBUGGABLE=0

main() {
    check_host
    if [ "${2:-}" = --debuggable ]; then
        DEBUGGABLE=1
    fi
    case "${1:-}" in
        --patch-only) patch_app ;;
        --reset-playchain) reset_playchain; exit 0 ;;
        ""|-h|--help) sed -n '2,7p' "$0"; exit 0 ;;
        *) install_ipa "$1"; configure; patch_app ;;
    esac
    step "Done. Launch Minecraft from PlayCover."
}

main "$@"
