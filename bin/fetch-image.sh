#!/usr/bin/env bash
#
# fetch-image.sh [CHANNEL]
#
# Download the Flatcar Container Linux QEMU image (qcow2) that every guest
# overlays, verify it against the published DIGESTS, and install it as
# images/flatcar_production_qemu_image.img. Re-running replaces the base
# image atomically; guests already running keep their old backing file open,
# so this is safe while instances exist -- but the next provision will use the
# new image, and the old file is left in place as *.previous until you delete it.
#
# CHANNEL defaults to "stable".

source "$(dirname "$0")/../lib/common.sh"

LOG_TAG="fetch-image"
CHANNEL="${1:-stable}"
[[ "$CHANNEL" =~ ^(stable|beta|alpha|lts)$ ]] || die "unknown channel '${CHANNEL}'"

BASE_URL="https://${CHANNEL}.release.flatcar-linux.net/amd64-usr/current"
FILE="flatcar_production_qemu_image.img"
IMAGE_DIR="$(dirname "$BASE_IMAGE")"
mkdir -p "$IMAGE_DIR"
cd "$IMAGE_DIR"

version="$(curl -fsSL "${BASE_URL}/version.txt" | sed -nE 's/^FLATCAR_VERSION=//p')"
log "Flatcar ${CHANNEL} is ${version:-unknown}"

if [[ -f "$FILE" && -f "${FILE}.version" && "$(<"${FILE}.version")" == "$version" ]]; then
  log "${FILE} is already at ${version}; nothing to do"
  exit 0
fi

log "Downloading ${BASE_URL}/${FILE}"
curl -fL --progress-bar -o "${FILE}.part" "${BASE_URL}/${FILE}"
curl -fsSL -o "${FILE}.DIGESTS" "${BASE_URL}/${FILE}.DIGESTS"

# DIGESTS lists md5/sha1/sha512 lines in "# SHA512 HASH" / "<hash>  <file>"
# format; pull the sha512 for our file and compare.
expected="$(awk -v f="$FILE" 'tolower($0) ~ /^# sha512/ {grab=1; next} grab && $2 == f {print $1; exit}' "${FILE}.DIGESTS")"
[[ -n "$expected" ]] || die "no SHA512 for ${FILE} in DIGESTS"
actual="$(sha512sum "${FILE}.part" | awk '{print $1}')"
[[ "$actual" == "$expected" ]] || die "checksum mismatch for ${FILE}: expected ${expected}, got ${actual}"
log "SHA512 verified"

qemu-img info "${FILE}.part" | sed 's/^/    | /'
qemu-img check -q "${FILE}.part" || die "qemu-img check failed"

[[ -f "$FILE" ]] && mv -f "$FILE" "${FILE}.previous"
mv -f "${FILE}.part" "$FILE"
chmod 0644 "$FILE"
printf '%s\n' "$version" >"${FILE}.version"
log "Installed ${IMAGE_DIR}/${FILE} (${version})"
