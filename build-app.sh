#!/bin/bash
# Builds Loupe and packages it as a proper macOS .app bundle.
#
# Loupe links the official FFmpeg libraries (libavformat/avcodec/avutil/swscale)
# to thumbnail containers QuickLook can't handle (.mkv/.webm), and libmpv to
# *play* those same containers. Those libraries and their whole Homebrew
# dependency chain are copied into the bundle's Frameworks directory and
# rewritten to load via @rpath so the app is self-contained and runs on
# machines without Homebrew.
set -euo pipefail

CONFIG="${1:-release}"
APP_NAME="Loupe"
BUNDLE="$APP_NAME.app"
BUILD_DIR=".build/$CONFIG"
FRAMEWORKS_DIR="$BUNDLE/Contents/Frameworks"

# Homebrew prefix. Apple Silicon uses /opt/homebrew; Intel uses /usr/local.
BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"

echo "==> Building ($CONFIG)..."
swift build -c "$CONFIG"

echo "==> Assembling $BUNDLE..."
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
mkdir -p "$BUNDLE/Contents/Resources"
mkdir -p "$FRAMEWORKS_DIR"

cp "$BUILD_DIR/$APP_NAME" "$BUNDLE/Contents/MacOS/$APP_NAME"
cp "Resources/Info.plist" "$BUNDLE/Contents/Info.plist"

# Stamp a unique CFBundleVersion per build. macOS caches app binaries by
# (bundle id + version); if the version never changes, Launch Services and the
# code-signing cache can relaunch the *previous* binary image after a rebuild —
# which is why a fresh build sometimes doesn't take effect until the 2nd launch.
# A monotonic timestamp forces macOS to treat each build as a new binary.
BUILD_VERSION="$(date +%Y%m%d%H%M%S)"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_VERSION" \
    "$BUNDLE/Contents/Info.plist" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Bundle the FFmpeg dylibs and their transitive Homebrew dependencies.
#
# Strategy: start from the libraries the app links against, then walk each
# dylib's dependencies (otool -L). Any dependency living under the Homebrew
# prefix is a third-party lib we must ship; system libs (/usr/lib,
# /System/...) are always present and left alone. For every bundled dylib we
# rewrite its own id and all its Homebrew-pointing dependencies to @rpath.
# ---------------------------------------------------------------------------

echo "==> Bundling FFmpeg + mpv libraries from $BREW_PREFIX..."

# Resolve a possibly-symlinked dylib to its real file so we copy the actual
# versioned binary rather than a relative symlink.
resolve() { python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"; }

# A dependency may be recorded against another dylib as an absolute path, as
# `@loader_path/...` (relative to the referrer's directory), or as
# `@rpath/...` (searched through the referrer's own LC_RPATH entries). Homebrew
# libs use all three — e.g. brotli's sub-libs reference each other via
# `@rpath/libbrotlicommon.1.dylib` resolved through an `@loader_path/../lib`
# rpath. Resolve any of these forms to a concrete file path so the closure walk
# can follow them. `$1` = dependency string, `$2` = the referrer's real path.
resolve_dep() {
    local dep="$1" referrer="$2"
    local referrer_dir
    referrer_dir="$(dirname "$referrer")"
    case "$dep" in
        @loader_path/*|@executable_path/*)
            resolve "$referrer_dir/${dep#@*/}"
            ;;
        @rpath/*)
            local suffix="${dep#@rpath/}" rp candidate
            # Try each LC_RPATH of the referrer, expanding @loader_path within
            # it, and return the first that exists on disk.
            while IFS= read -r rp; do
                case "$rp" in
                    @loader_path/*|@executable_path/*)
                        candidate="$referrer_dir/${rp#@*/}/$suffix" ;;
                    *)
                        candidate="$rp/$suffix" ;;
                esac
                if [ -f "$candidate" ]; then
                    resolve "$candidate"
                    return 0
                fi
            done < <(otool -l "$referrer" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}')
            return 1
            ;;
        /*)
            resolve "$dep"
            ;;
        *)
            return 1
            ;;
    esac
}

# Collect the dependency closure. macOS ships bash 3.2 (no associative
# arrays), so track seen realpaths in a newline-delimited string.
SEEN=$'\n'
QUEUE=()

enqueue() {
    local real
    real="$(resolve "$1")"
    [ -f "$real" ] || return 0
    case "$SEEN" in
        *$'\n'"$real"$'\n'*) : ;;              # already seen
        *) SEEN="$SEEN$real"$'\n'; QUEUE+=("$real") ;;
    esac
}

# Seed with the libraries Loupe links against directly: the four FFmpeg libs
# (for thumbnailing) and libmpv (for playback). libmpv pulls in its own large
# dependency chain — including its own copy of the FFmpeg libs — which the
# closure walk below discovers and bundles automatically.
for lib in libavformat libavcodec libavutil libswscale; do
    enqueue "$BREW_PREFIX/opt/ffmpeg/lib/$lib.dylib"
done
enqueue "$BREW_PREFIX/opt/mpv/lib/libmpv.dylib"

# Walk the closure. QUEUE grows as we discover dependencies. A dependency is a
# lib we must bundle when it resolves to a real file inside the Homebrew tree —
# whether it was recorded as an absolute Homebrew path or indirectly via
# @rpath/@loader_path (which `resolve_dep` expands). System libs (/usr/lib,
# /System/...) resolve outside the Homebrew prefix and are left alone.
i=0
while [ $i -lt ${#QUEUE[@]} ]; do
    cur="${QUEUE[$i]}"
    i=$((i + 1))
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        real="$(resolve_dep "$dep" "$cur")" || continue
        case "$real" in
            "$BREW_PREFIX"/*) enqueue "$real" ;;
        esac
    done < <(otool -L "$cur" | tail -n +2 | awk '{print $1}')
done

echo "    Found ${#QUEUE[@]} libraries to bundle."

# Copy each resolved dylib into Frameworks under its basename.
for src in "${QUEUE[@]}"; do
    base="$(basename "$src")"
    cp -f "$src" "$FRAMEWORKS_DIR/$base"
    chmod u+w "$FRAMEWORKS_DIR/$base"
done

# Rewrite install names: set each lib's id to @rpath/<base>, repoint every
# bundled dependency to @rpath/<dep-base>, and give each dylib an rpath of
# @loader_path so those @rpath references resolve to the Frameworks dir the
# dylib lives in. We rewrite any dependency that resolves into the Homebrew
# tree, regardless of whether it was recorded as an absolute path or via
# @rpath/@loader_path — otherwise a sibling like libbrotlicommon stays an
# unresolved @rpath and the app fails to launch. The original dep string
# (not its resolved path) is what `install_name_tool -change` must match.
for src in "${QUEUE[@]}"; do
    base="$(basename "$src")"
    target="$FRAMEWORKS_DIR/$base"
    install_name_tool -id "@rpath/$base" "$target"
    while IFS= read -r dep; do
        [ -n "$dep" ] || continue
        # A dep already written as @rpath/<base> that we bundled needs no
        # change (the new @loader_path rpath will resolve it), but rewriting it
        # to the canonical basename is harmless and normalizes versioned names.
        real="$(resolve_dep "$dep" "$src")" || continue
        case "$real" in
            "$BREW_PREFIX"/*)
                depbase="$(basename "$real")"
                if [ "$dep" != "@rpath/$depbase" ]; then
                    install_name_tool -change "$dep" "@rpath/$depbase" "$target"
                fi
                ;;
        esac
    done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
    # Ensure @rpath resolves to the dylib's own directory (Frameworks). Harmless
    # if an equivalent rpath already exists.
    install_name_tool -add_rpath "@loader_path" "$target" 2>/dev/null || true
done

# Point the main executable at the bundled libraries: rewrite its Homebrew
# references to @rpath and add an rpath that resolves to Frameworks.
MAIN_BIN="$BUNDLE/Contents/MacOS/$APP_NAME"
while IFS= read -r dep; do
    case "$dep" in
        "$BREW_PREFIX"/*)
            depbase="$(basename "$(resolve "$dep")")"
            install_name_tool -change "$dep" "@rpath/$depbase" "$MAIN_BIN"
            ;;
    esac
done < <(otool -L "$MAIN_BIN" | tail -n +2 | awk '{print $1}')
install_name_tool -add_rpath "@loader_path/../Frameworks" "$MAIN_BIN" 2>/dev/null || true

# App icon: regenerate the .icns from the SVG if missing, then bundle it.
if [ ! -f "Resources/AppIcon.icns" ] && [ -f "make-icon.sh" ]; then
    echo "==> Generating app icon..."
    ./make-icon.sh
fi
if [ -f "Resources/AppIcon.icns" ]; then
    cp "Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
fi

# Code sign: each bundled dylib first, then the app as a whole. Signing the
# dylibs individually (ad-hoc) is required now that install names changed.
echo "==> Code signing bundled libraries (ad-hoc)..."
for dylib in "$FRAMEWORKS_DIR"/*.dylib; do
    codesign --force --sign - "$dylib"
done

echo "==> Code signing app (ad-hoc) with entitlements..."
# --deep is deprecated/unreliable for nested code; the dylibs are already
# signed individually above, so sign only the top-level bundle here.
codesign --force \
    --sign - \
    --entitlements "Resources/Loupe.entitlements" \
    "$BUNDLE"

# Refresh Launch Services so Finder/Dock pick up the icon. Rebuilding and
# ad-hoc re-signing the app in place leaves a stale icon in the LS cache; a
# re-register plus touch is the reliable fix.
echo "==> Refreshing Launch Services registration..."
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
    "$LSREGISTER" -f "$(pwd)/$BUNDLE" || true
fi
touch "$BUNDLE"

# Kill any running instance of the old build. Otherwise `open` just reactivates
# the already-running (stale) process instead of launching the new binary —
# the other half of the "changes don't apply on the first build" problem.
echo "==> Terminating any running instance..."
killall "$APP_NAME" 2>/dev/null || true

echo "==> Done: $(pwd)/$BUNDLE (version $BUILD_VERSION)"
echo "    Run with: open $BUNDLE"
