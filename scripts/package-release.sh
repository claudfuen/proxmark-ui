#!/bin/bash
# Create a downloadable app ZIP and the source needed to redistribute it.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=""
if (( $# > 0 )); then
    VERSION="$1"
fi
if [[ -z "$VERSION" ]]; then
    VERSION="$(printenv PMUI_VERSION || true)"
fi
if [[ -z "$VERSION" ]]; then
    EXACT_TAG="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
    if [[ "$EXACT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        VERSION="$(printf '%s' "$EXACT_TAG" | cut -c 2-)"
    fi
fi
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "usage: scripts/package-release.sh VERSION (or set PMUI_VERSION, or run at a version tag)" >&2
    exit 1
fi
EXACT_TAG="$(git describe --tags --exact-match HEAD 2>/dev/null || true)"
if [[ "$EXACT_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ && "$EXACT_TAG" != "v$VERSION" ]]; then
    echo "error: requested version $VERSION differs from source tag $EXACT_TAG" >&2
    exit 1
fi
APP="dist/ProxmarkUI.app"
[[ -d "$APP" ]] || { echo "error: build the app first" >&2; exit 1; }
if [[ -z "$(printenv PM3_SRC || true)" ]]; then
    PM3_SRC="$HOME/Repos/_vendor/proxmark3"
fi
PM3_SRC="$(cd "$PM3_SRC" && pwd)"
PM3_REV="693ead08038c6ade43833579306e98eb3dd18d8e"
[[ "$(git -C "$PM3_SRC" rev-parse HEAD)" = "$PM3_REV" ]] || {
    echo "error: Iceman checkout is not the release revision" >&2
    exit 1
}
[[ "$(git rev-parse HEAD)" = "$(git rev-parse HEAD^{commit})" ]] || exit 1
if ! git diff --quiet HEAD --; then
    echo "error: commit source changes before packaging a release" >&2
    exit 1
fi

APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[[ "$APP_VERSION" = "$VERSION" ]] || {
    echo "error: app version $APP_VERSION differs from requested $VERSION" >&2
    exit 1
}
APP_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$APP_BUILD" = "$VERSION" ]] || {
    echo "error: app build $APP_BUILD differs from requested $VERSION" >&2
    exit 1
}
codesign --verify --deep --strict "$APP"
PM3_ROOT="$APP/Contents/Resources/pm3"
PM3_BIN="$PM3_ROOT/bin/proxmark3"
UPDATE_HELPER="$APP/Contents/Resources/ProxmarkUIUpdater"
[[ -x "$PM3_BIN" ]] || { echo "error: bundled client missing" >&2; exit 1; }
[[ -x "$UPDATE_HELPER" ]] || { echo "error: app update helper missing" >&2; exit 1; }
codesign --verify --strict "$UPDATE_HELPER"
[[ -s "$PM3_ROOT/share/proxmark3/dictionaries/mfc_default_keys.dic" ]] || {
    echo "error: bundled MIFARE dictionary missing" >&2
    exit 1
}
for target in PM3EASY PM3RDV4; do
    [[ -s "$PM3_ROOT/share/proxmark3/firmware/$target/fullimage.elf" ]] || {
        echo "error: $target firmware missing" >&2
        exit 1
    }
done

for binary in "$APP/Contents/MacOS/ProxmarkUI" "$UPDATE_HELPER" "$PM3_BIN" "$PM3_ROOT"/lib/*.dylib; do
    [[ -f "$binary" ]] || continue
    file "$binary" | grep -q arm64 || {
        echo "error: $binary is not an Apple silicon binary" >&2
        exit 1
    }
    while IFS= read -r dependency; do
        case "$dependency" in
            /System/*|/usr/lib/*|@loader_path/../lib/*) ;;
            *) echo "error: $binary loads unexpected library $dependency" >&2; exit 1 ;;
        esac
    done < <(otool -L "$binary" | tail -n +2 | awk '{print $1}')
done
for lib in "$PM3_ROOT"/lib/*.dylib; do
    [[ -f "$lib" ]] || continue
    case "$(basename "$lib")" in
        liblz4.1.dylib|libreadline.8.dylib) ;;
        *) echo "error: unreviewed bundled library $lib" >&2; exit 1 ;;
    esac
done
VERSION_OUTPUT="$(cd "$(mktemp -d)" && env -i PATH=/usr/bin:/bin "$OLDPWD/$PM3_BIN" --incognito --version 2>&1)"
[[ "$VERSION_OUTPUT" = *"693ead0"* ]] || {
    echo "error: bundled client revision could not be verified offline" >&2
    exit 1
}

mkdir -p dist
ZIP="dist/ProxmarkUI-v$VERSION-macos-arm64.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
unzip -Z -1 "$ZIP" | grep -F -x 'ProxmarkUI.app/Contents/MacOS/ProxmarkUI' >/dev/null

git archive --format=tar.gz --prefix="ProxmarkUI-v$VERSION/" HEAD > "dist/ProxmarkUI-v$VERSION-source.tar.gz"
git -C "$PM3_SRC" archive --format=tar.gz --prefix="Iceman-proxmark3-693ead08038c/" HEAD > dist/Iceman-proxmark3-693ead08038c-source.tar.gz
git -C "$PM3_SRC" bundle create "$PWD/dist/Iceman-proxmark3-693ead08038c.git.bundle" HEAD
git -C "$PM3_SRC" bundle verify "$PWD/dist/Iceman-proxmark3-693ead08038c.git.bundle"

LZ4_ARCHIVE="dist/lz4-1.10.0-source.tar.gz"
if [[ ! -f "$LZ4_ARCHIVE" ]]; then
    curl -fL --retry 3 https://github.com/lz4/lz4/archive/refs/tags/v1.10.0.tar.gz -o "$LZ4_ARCHIVE"
fi
echo "537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b  $LZ4_ARCHIVE" | shasum -a 256 -c -

READLINE_ASSET=""
if compgen -G "$PM3_ROOT/lib/libreadline*.dylib" >/dev/null; then
    READLINE_ASSET="dist/readline-8.3.3-source.tar.gz"
    [[ "$(brew list --versions readline)" = "readline 8.3.3" ]] || {
        echo "error: this release expects GNU Readline 8.3.3 sources" >&2
        exit 1
    }
    [[ -f "$READLINE_ASSET" ]] || {
        echo "error: corresponding Readline source archive is missing" >&2
        exit 1
    }
    echo "021b5a524a37f34d571af8cb93ea7a4509d54f578905620f77cac22023cfb9df  $READLINE_ASSET" | shasum -a 256 -c -
fi
[[ "$(brew list --versions lz4)" = "lz4 1.10.0" ]] || {
    echo "error: this release expects LZ4 1.10.0 sources" >&2
    exit 1
}

cp LICENSE.txt dist/ProxmarkUI-LICENSE.txt
cp THIRD_PARTY_NOTICES.md dist/THIRD_PARTY_NOTICES.md
if [[ "$VERSION" = 0.1.0 ]]; then
    cp docs/RELEASE_NOTES.md dist/PRERELEASE_NOTES.md
else
    rm -f dist/PRERELEASE_NOTES.md
fi
{
    printf '# ProxmarkUI v%s release sources\n\n' "$VERSION"
    printf 'The Apple silicon ZIP was built from this repository release commit and\n'
    printf 'RfidResearchGroup/proxmark3 revision `%s`. The app contains the Iceman\n' "$PM3_REV"
    cat <<'EOF'
client and full firmware images for Proxmark3 Easy and RDV4.

The following files accompany the binary:

EOF
    printf -- '- `ProxmarkUI-v%s-source.tar.gz`: the Swift app, packaging scripts, notices, and documentation at the release commit.\n' "$VERSION"
    cat <<'EOF'
- `Iceman-proxmark3-693ead08038c-source.tar.gz`: the complete tracked Iceman source at the pinned revision.
- `Iceman-proxmark3-693ead08038c.git.bundle`: Iceman Git history needed by its version-generation scripts.
- `lz4-1.10.0-source.tar.gz`: LZ4 source for the bundled dynamic library.
EOF
} > dist/SOURCE_MANIFEST.md
if [[ -n "$READLINE_ASSET" ]]; then
    cat >> dist/SOURCE_MANIFEST.md <<'EOF'
- `readline-8.3.3-source.tar.gz`: GNU Readline 8.3 with the Homebrew 8.3.3 patches and formula for the bundled dynamic library.
EOF
fi
cat >> dist/SOURCE_MANIFEST.md <<'EOF'

The app ZIP carries Iceman's GPL license and the third party notices in
`ProxmarkUI.app/Contents/Resources/licenses/`. The same app license and notices
are attached separately for convenient review. All source assets are available
at no additional charge beside the binary. See `SHA256SUMS.txt` to verify
downloads. The app is ad hoc signed and has not been notarized. Physical
firmware flashing has not been validated in this release.
EOF

assets=(
    "$ZIP"
    "dist/ProxmarkUI-v$VERSION-source.tar.gz"
    dist/Iceman-proxmark3-693ead08038c-source.tar.gz
    dist/Iceman-proxmark3-693ead08038c.git.bundle
    "$LZ4_ARCHIVE"
    dist/ProxmarkUI-LICENSE.txt
    dist/THIRD_PARTY_NOTICES.md
    dist/SOURCE_MANIFEST.md
)
[[ -z "$READLINE_ASSET" ]] || assets+=("$READLINE_ASSET")
(cd dist && shasum -a 256 "${assets[@]/#dist\//}" > SHA256SUMS.txt)
echo "Prepared $ZIP and corresponding source assets"
