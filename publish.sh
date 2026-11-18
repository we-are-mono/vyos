#!/bin/bash
# Publish the latest build as a GitHub release of this repository.
#
#   ./publish.sh
#
# Uploads the ISO, the eMMC image and their checksums, and an
# image-version.json: the file VyOS's `system update-check url` reads to find
# the newest image for `add system image latest`. The latest release's copy is
# always at
#   https://github.com/<repo>/releases/latest/download/image-version.json
# Needs the GitHub CLI (gh), logged in with write access to the repository.
set -euo pipefail

TOP=$(cd "$(dirname "$0")" && pwd)
. "$TOP/pins.sh"
IMAGES=$BUILD/images

ISO=$(cat "$IMAGES/latest-iso" 2>/dev/null || true)
EMMC=$(cat "$IMAGES/latest-emmc" 2>/dev/null || true)
[ -f "$ISO" ] && [ -f "$EMMC" ] && [ -f "$EMMC.gz" ] \
    || { echo "E: no build to publish; run './build.sh all'"; exit 1; }

# The release records the commit it was built from; it must be one GitHub has.
[ -z "$(git -C "$TOP" status --porcelain)" ] \
    || { echo "E: uncommitted changes; commit and push what this build was made from"; exit 1; }
git -C "$TOP" fetch -q origin
COMMIT=$(git -C "$TOP" rev-parse HEAD)
git -C "$TOP" merge-base --is-ancestor "$COMMIT" "origin/$(git -C "$TOP" rev-parse --abbrev-ref HEAD)" \
    || { echo "E: $COMMIT is not pushed"; exit 1; }

REPO=$(gh repo view --json nameWithOwner --jq .nameWithOwner)
VJSON=$(mktemp)
trap 'rm -f "$VJSON"' EXIT
xorriso -osirrox on -indev "$ISO" -extract /version.json "$VJSON" >/dev/null 2>&1 \
    || { echo "E: cannot read version.json from $ISO"; exit 1; }
VERSION=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$VJSON")
[ -n "$VERSION" ] || { echo "E: cannot read the version from $ISO"; exit 1; }
case "$VERSION" in *-dev) echo "E: $VERSION is a development build; publish full builds only"; exit 1 ;; esac
ISO_NAME=$(basename "$ISO")
EMMC_NAME=$(basename "$EMMC")
gh release view "$VERSION" --repo "$REPO" >/dev/null 2>&1 \
    && { echo "E: release $VERSION exists already"; exit 1; }

STAGE=$BUILD/publish/$VERSION
rm -rf "$STAGE"; mkdir -p "$STAGE"
(cd "$(dirname "$ISO")" && sha256sum "$ISO_NAME") > "$STAGE/$ISO_NAME.sha256"
cp "$EMMC.sha256" "$STAGE/"
python3 - "$STAGE/image-version.json" "$VERSION" "$ISO_NAME" \
    "https://github.com/$REPO/releases/download/$VERSION/$ISO_NAME" <<'PYEOF'
import datetime, json, sys
path, version, image, url = sys.argv[1:]
json.dump([{
    'arch': 'arm64',
    'flavors': ['mono-gateway-dk'],
    'image': image,
    'latest': True,
    'lts': False,
    'release_date': datetime.date.today().isoformat(),
    'release_train': 'rolling',
    'url': url,
    'version': version,
}], open(path, 'w'), indent=2)
PYEOF

cat > "$STAGE/notes.md" <<EOF
VyOS $VERSION for the Mono Gateway DK.

- ASK $ASK_REF, Linux $KERNEL_RELEASE
- vyos-build ${VYOS_BUILD_REF:0:12}
- built from $COMMIT

**New install**: flash \`$EMMC_NAME.gz\` as the README describes.
**Upgrade** a running Gateway: \`add system image latest\` (with
\`system update-check url\` set as in the README), or
\`add system image https://github.com/$REPO/releases/download/$VERSION/$ISO_NAME\`.
EOF

echo "I: publishing $VERSION to $REPO"
gh release create "$VERSION" --repo "$REPO" --target "$COMMIT" --latest \
    --title "VyOS $VERSION" --notes-file "$STAGE/notes.md" \
    "$ISO" "$STAGE/$ISO_NAME.sha256" \
    "$EMMC.gz" "$STAGE/$EMMC_NAME.sha256" \
    "$STAGE/image-version.json"
echo "I: https://github.com/$REPO/releases/tag/$VERSION"
