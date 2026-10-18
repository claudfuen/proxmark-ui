#!/bin/bash
# Packages ProxmarkUI as a self-contained, double-clickable ProxmarkUI.app.
#
# "Self-contained" means the bundle carries everything it needs to talk to a
# Proxmark3: the Iceman `proxmark3` client, the handful of Homebrew dylibs it
# links against (relinked to load from inside the bundle), and the client's
# data files (dictionaries, resources, scripts). A fresh copy of the app runs
# with nothing installed, symlinked, or on PATH.
#
# Ad-hoc signed only - fine to run locally; Gatekeeper will still warn on a copy
# downloaded from the internet until it's notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
PM3_JOBS="${PM3_JOBS:-8}"
if [[ ! "$PM3_JOBS" =~ ^[1-9][0-9]*$ ]]; then
    echo "error: PM3_JOBS must be a positive integer." >&2
    exit 1
fi
PMUI_VERSION="${PMUI_VERSION:-}"
if [[ -z "$PMUI_VERSION" ]]; then
    VERSION_TAG="$(git describe --tags --abbrev=0 --match 'v[0-9]*.[0-9]*.[0-9]*' HEAD 2>/dev/null || true)"
    if [[ -n "$VERSION_TAG" ]]; then
        PMUI_VERSION="$(printf '%s' "$VERSION_TAG" | cut -c 2-)"
    else
        PMUI_VERSION="0.1.0"
    fi
fi
if [[ ! "$PMUI_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: PMUI_VERSION must be a major.minor.patch number." >&2
    exit 1
fi

# Where the Iceman client and its data files live. Override with PM3_SRC if your
# checkout is elsewhere.
PM3_SRC="${PM3_SRC:-$HOME/Repos/_vendor/proxmark3}"
PM3_SRC="$(cd "$PM3_SRC" && pwd)"
PM3_BIN_SRC="$PM3_SRC/client/proxmark3"
PM3_FW_SRC="$PM3_SRC/armsrc/obj/fullimage.elf"

if [[ ! -x "$PM3_BIN_SRC" ]]; then
    echo "error: proxmark3 client not found at $PM3_BIN_SRC" >&2
    echo "       build it first (cd $PM3_SRC && make client) or set PM3_SRC." >&2
    exit 1
fi

# Build both application images from the same checkout as the client. Easy is
# based on upstream PM3GENERIC with PM3EASY LED order and a 256 KB size check.
# Keep LF and ISO 14443-A for the app's EM/HID, Classic, and Ultralight flows.
# The Proxmark flasher checks source versions before writing.
if ! command -v arm-none-eabi-gcc >/dev/null 2>&1; then
    echo "error: an ARM cross toolchain is needed to build matching firmware." >&2
    echo "       Install Arm GNU Toolchain (with C library headers), then rerun." >&2
    exit 1
fi
PM3_REV="$(git -C "$PM3_SRC" rev-parse --short=7 HEAD)"
PM3_FW_STAGE="$(mktemp -d)"
trap 'rm -rf "$PM3_FW_STAGE"' EXIT
PM3_PROBE_DIR="$PM3_FW_STAGE/probe"
mkdir -p "$PM3_PROBE_DIR"
PM3_VERSION="$(cd "$PM3_PROBE_DIR" && "$PM3_BIN_SRC" --incognito --version 2>&1)"
if [[ "$PM3_VERSION" != *"$PM3_REV"* ]]; then
    echo "error: the client at $PM3_BIN_SRC does not match the firmware checkout ($PM3_REV)." >&2
    echo "       Rebuild it with: make -C $PM3_SRC client" >&2
    exit 1
fi

verify_firmware() {
    local expected_platform="$1"
    local actual_platform
    actual_platform="$(sed -n 's/^CACHED_PLATFORM=//p' "$PM3_SRC/.Makefile.options.cache" | head -n 1)"
    if [[ "$actual_platform" != "$expected_platform" || ! -s "$PM3_FW_SRC" ]]; then
        echo "error: firmware build did not produce a $expected_platform fullimage.elf." >&2
        exit 1
    fi
    if ! /usr/bin/strings "$PM3_FW_SRC" | grep -F "$PM3_REV" >/dev/null; then
        echo "error: $expected_platform firmware does not contain source revision $PM3_REV." >&2
        exit 1
    fi
}

echo "==> Building matching Proxmark3 Easy firmware (256 KB)"
EASY_OPTIONS=(
    PLATFORM_FILE=/dev/null PLATFORM=PM3GENERIC PLATFORM_EXTRAS= LED_ORDER=PM3EASY
    PLATFORM_SIZE=256 STANDALONE=
    SKIP_HITAG=1 SKIP_EM4x50=1 SKIP_EM4x70=1 SKIP_ZX8211=1
    SKIP_ISO15693=1 SKIP_LEGICRF=1 SKIP_ISO14443b=1 SKIP_DESFIRE_SIM=1
    SKIP_ICLASS=1 SKIP_SEOS=1 SKIP_FELICA=1 SKIP_NFCBARCODE=1
    SKIP_HFSNIFF=1 SKIP_HFPLOT=1
)
make -C "$PM3_SRC" recovery "${EASY_OPTIONS[@]}" -j "$PM3_JOBS"
verify_firmware PM3GENERIC
EASY_DEFS="$(sed -n 's/^CACHED_PLATFORM_DEFS=//p' "$PM3_SRC/.Makefile.options.cache" | head -n 1)"
for required in LED_ORDER_PM3EASY WITH_LF WITH_GENERAL_HF WITH_ISO14443a; do
    if [[ " $EASY_DEFS " != *" -D$required "* ]]; then
        echo "error: Easy firmware is missing required feature $required." >&2
        exit 1
    fi
done
EASY_RECOVERY_BYTES="$(wc -c < "$PM3_SRC/recovery/recovery.bin" | tr -d ' ')"
if (( EASY_RECOVERY_BYTES > 262144 )); then
    echo "error: Easy firmware does not fit a 256 KB reader ($EASY_RECOVERY_BYTES bytes)." >&2
    exit 1
fi
mkdir -p "$PM3_FW_STAGE/PM3EASY"
cp "$PM3_FW_SRC" "$PM3_FW_STAGE/PM3EASY/fullimage.elf"

echo "==> Building matching Proxmark3 RDV4 firmware"
make -C "$PM3_SRC" recovery PLATFORM_FILE=/dev/null PLATFORM=PM3RDV4 PLATFORM_EXTRAS= LED_ORDER= PLATFORM_SIZE=512 STANDALONE=LF_SAMYRUN -j "$PM3_JOBS"
verify_firmware PM3RDV4
RDV4_DEFS="$(sed -n 's/^CACHED_PLATFORM_DEFS=//p' "$PM3_SRC/.Makefile.options.cache" | head -n 1)"
if [[ " $RDV4_DEFS " != *" -DRDV4 "* ]]; then
    echo "error: RDV4 firmware is missing its hardware target definition." >&2
    exit 1
fi
mkdir -p "$PM3_FW_STAGE/PM3RDV4"
cp "$PM3_FW_SRC" "$PM3_FW_STAGE/PM3RDV4/fullimage.elf"

echo "==> Building ProxmarkUI ($CONFIG)"
swift build -c "$CONFIG"
swift build -c "$CONFIG" --product ProxmarkUIUpdater

BIN=".build/$CONFIG/ProxmarkUI"
HELPER=".build/$CONFIG/ProxmarkUIUpdater"
APP="dist/ProxmarkUI.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ProxmarkUI"
cp "$HELPER" "$APP/Contents/Resources/ProxmarkUIUpdater"
chmod +x "$APP/Contents/Resources/ProxmarkUIUpdater"

# ---------------------------------------------------------------------------
# App icon: the binary draws its own master (AppIcon.swift), sips makes the
# sizes, iconutil packs them.
# ---------------------------------------------------------------------------
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
"$BIN" --render-icon "$ICONSET/master.png"
for s in 16 32 128 256 512; do
    sips -z $s $s "$ICONSET/master.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) "$ICONSET/master.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
rm "$ICONSET/master.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

# ---------------------------------------------------------------------------
# Bundle the Proxmark3 client, its dylibs, and its data files.
#
#   Contents/Resources/pm3/bin/proxmark3           <- the client
#   Contents/Resources/pm3/lib/*.dylib             <- relinked Homebrew deps
#   Contents/Resources/pm3/share/proxmark3/...     <- dictionaries, resources
#
# The client finds its data via `<bindir>/../share/proxmark3/`, so `share` is a
# sibling of `bin`. It finds its dylibs via `@loader_path/../lib/`.
# ---------------------------------------------------------------------------
PM3_ROOT="$APP/Contents/Resources/pm3"
PM3_BIN_DIR="$PM3_ROOT/bin"
PM3_LIB_DIR="$PM3_ROOT/lib"
PM3_SHARE_DIR="$PM3_ROOT/share/proxmark3"
PM3_FW_DIR="$PM3_SHARE_DIR/firmware"
mkdir -p "$PM3_BIN_DIR" "$PM3_LIB_DIR" "$PM3_SHARE_DIR" "$PM3_FW_DIR"

echo "==> Bundling client from $PM3_BIN_SRC"
cp "$PM3_BIN_SRC" "$PM3_BIN_DIR/proxmark3"
chmod +x "$PM3_BIN_DIR/proxmark3"

echo "==> Bundling data files"
for dir in resources dictionaries lualibs luascripts pyscripts cmdscripts; do
    if [[ -d "$PM3_SRC/client/$dir" ]]; then
        cp -R "$PM3_SRC/client/$dir" "$PM3_SHARE_DIR/$dir"
    fi
done

echo "==> Bundling Easy and RDV4 firmware from $PM3_REV"
cp -R "$PM3_FW_STAGE/PM3EASY" "$PM3_FW_STAGE/PM3RDV4" "$PM3_FW_DIR/"
EASY_SHA="$(shasum -a 256 "$PM3_FW_DIR/PM3EASY/fullimage.elf" | awk '{print $1}')"
RDV4_SHA="$(shasum -a 256 "$PM3_FW_DIR/PM3RDV4/fullimage.elf" | awk '{print $1}')"
printf '{"target":"PM3EASY","sourceRevision":"%s","buildPlatform":"PM3GENERIC","ledOrder":"PM3EASY","maxFlashKB":256,"sha256":"%s"}\n' "$PM3_REV" "$EASY_SHA" > "$PM3_FW_DIR/PM3EASY/build.json"
printf '{"target":"PM3RDV4","sourceRevision":"%s","buildPlatform":"PM3RDV4","ledOrder":null,"maxFlashKB":512,"sha256":"%s"}\n' "$PM3_REV" "$RDV4_SHA" > "$PM3_FW_DIR/PM3RDV4/build.json"

# Relink non-system dylibs into the bundle. Walk the dependency closure so a
# Homebrew lib that depends on another Homebrew lib is bundled too.
echo "==> Relinking dylibs"
is_system_lib() {
    case "$1" in
        /usr/lib/*|/System/*) return 0 ;;
        @*) return 0 ;;   # already a bundle-relative path
        *) return 1 ;;
    esac
}

# Queue of Mach-O files whose dependencies still need processing.
queue=("$PM3_BIN_DIR/proxmark3")
while [[ ${#queue[@]} -gt 0 ]]; do
    target="${queue[0]}"
    queue=("${queue[@]:1}")

    # Every non-system dependency of `target`.
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        is_system_lib "$dep" && continue
        name="$(basename "$dep")"
        dest="$PM3_LIB_DIR/$name"

        if [[ ! -f "$dest" ]]; then
            # Resolve symlinks so we copy the real library, then make it writable.
            real="$(readlink -f "$dep" 2>/dev/null || echo "$dep")"
            cp "$real" "$dest"
            chmod u+w "$dest"
            install_name_tool -id "@loader_path/../lib/$name" "$dest"
            queue+=("$dest")   # its own deps may need bundling too
        fi

        # Point `target` at the bundled copy.
        install_name_tool -change "$dep" "@loader_path/../lib/$name" "$target"
    done < <(otool -L "$target" | tail -n +2 | awk '{print $1}')
done

# Keep license texts beside the binaries they cover.
LICENSE_DIR="$APP/Contents/Resources/licenses"
mkdir -p "$LICENSE_DIR"
cp "$PM3_SRC/LICENSE.txt" "$LICENSE_DIR/Iceman-LICENSE.txt"
cp LICENSE.txt "$LICENSE_DIR/ProxmarkUI-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$LICENSE_DIR/THIRD_PARTY_NOTICES.md"
if compgen -G "$PM3_LIB_DIR/liblz4*.dylib" >/dev/null; then
    LZ4_PREFIX="$(brew --prefix lz4)"
    cp "$LZ4_PREFIX/LICENSE" "$LICENSE_DIR/LZ4-LICENSE.txt"
    cp licenses/LZ4-lib-LICENSE.txt "$LICENSE_DIR/LZ4-lib-LICENSE.txt"
fi
if compgen -G "$PM3_LIB_DIR/libreadline*.dylib" >/dev/null; then
    READLINE_PREFIX="$(brew --prefix readline)"
    cp "$READLINE_PREFIX/COPYING" "$LICENSE_DIR/Readline-COPYING.txt"
fi

# ---------------------------------------------------------------------------
# Info.plist
# ---------------------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>ProxmarkUI</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>dev.claudio.proxmarkui</string>
    <key>CFBundleName</key><string>ProxmarkUI</string>
    <key>CFBundleDisplayName</key><string>Proxmark UI</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$PMUI_VERSION</string>
    <key>CFBundleVersion</key><string>$PMUI_VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHumanReadableCopyright</key><string>Open source. No warranty.</string>
</dict>
</plist>
PLIST

# ---------------------------------------------------------------------------
# Code-sign inner-to-outer: dylibs, then the client, then the app. A nested
# Mach-O signed after its container invalidates the container's signature, so
# order matters.
# ---------------------------------------------------------------------------
echo "==> Signing"
for lib in "$PM3_LIB_DIR"/*.dylib; do
    if [[ -e "$lib" ]]; then
        codesign --force --sign - --timestamp=none "$lib" >/dev/null
    fi
done
codesign --force --sign - --timestamp=none "$PM3_BIN_DIR/proxmark3" >/dev/null
codesign --force --sign - --timestamp=none "$APP/Contents/Resources/ProxmarkUIUpdater" >/dev/null
codesign --force --deep --sign - --timestamp=none "$APP" >/dev/null
codesign --verify --deep --strict "$APP"

SIZE="$(du -sh "$APP" | cut -f1)"
echo "Built $APP ($SIZE, self-contained)"
