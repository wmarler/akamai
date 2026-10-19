#!/usr/bin/env bash
#
# Shared helpers for the provisioning scripts: configuration, logging, input
# validation, locking and the on-disk instance registry.
#
# Every script does:   source /home/osmc/akamai/lib/common.sh
# and then calls       load_config
#
# Paths are hard-coded on purpose: this runs on one host, from one checkout.
#
# Nothing here is interactive and nothing here prompts; all scripts are run
# unattended from the web service (via sudo) or from a systemd timer.

set -euo pipefail

AKAMAI_DIR=/home/osmc/akamai
SECRETS_FILE="${AKAMAI_DIR}/configs/actual/secrets"

STATE_DIR="${AKAMAI_DIR}/state"
INSTANCE_DIR="${STATE_DIR}/instances"
VM_DIR="${STATE_DIR}/vms"
BASE_IMAGE="${AKAMAI_DIR}/images/flatcar_production_qemu_image.img"
LOCK_FILE="${STATE_DIR}/provision.lock"

###############################################################################
# Logging
###############################################################################

# All output goes to stdout with a timestamp; the web service captures it and
# shows it to the user as the job log, and journald captures it under systemd.
log()  { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOG_TAG:-akamai}" "$*"; }
warn() { log "WARNING: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

# Print a step banner. Steps are what the user sees progressing in the UI.
step() { log "==> $*"; }

###############################################################################
# Configuration
###############################################################################

# Source configs/actual/secrets and make sure nothing we need is blank.
load_config() {
  [[ -f "$SECRETS_FILE" ]] || die "missing ${SECRETS_FILE} (copy configs/secrets.example and edit it)"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"

  local var
  for var in BASE_DOMAIN PORTAL_HOST HOST_BRIDGE POOL_PREFIX POOL_START POOL_END \
             POOL_PREFIX_LEN POOL_GATEWAY POOL_DNS GUEST_MEMORY_MIB GUEST_VCPUS \
             GUEST_BOOT_TIMEOUT INSTANCE_TTL_HOURS SERVICE_USER WEB_LISTEN_PORT \
             NGINX_INSTANCE_DIR NGINX_SSL_SNIPPET NGINX_TEST_CMD NGINX_RELOAD_CMD \
             CLOUDFLARE_PROXIED LIBVIRT_URI INSTANCE_PREFIX; do
    [[ -n "${!var:-}" ]] || die "${var} is not set in ${SECRETS_FILE}"
  done
  RESERVED_NAMES="${RESERVED_NAMES:-}"
  GUEST_SSH_AUTHORIZED_KEYS="${GUEST_SSH_AUTHORIZED_KEYS:-}"
}

# FQDN for a guest label: INSTANCE_PREFIX + name + . + BASE_DOMAIN
# e.g. bob -> akamai-bob.wmarler.com
instance_fqdn() { printf '%s%s.%s' "$INSTANCE_PREFIX" "$1" "$BASE_DOMAIN"; }

# The Cloudflare token: either CLOUDFLARE_API_TOKEN itself, or read from
# CLOUDFLARE_API_TOKEN_FILE (certbot's cloudflare.ini format, or a bare token).
# Only the root-run scripts call this; the web service never needs the token.
cloudflare_token() {
  if [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    printf '%s' "$CLOUDFLARE_API_TOKEN"
    return
  fi
  local token
  token="$(sed -nE 's/^[[:space:]]*dns_cloudflare_api_token[[:space:]]*=[[:space:]]*//p' "$CLOUDFLARE_API_TOKEN_FILE" | head -1)"
  [[ -n "$token" ]] || token="$(grep -vE '^[[:space:]]*(#|$)' "$CLOUDFLARE_API_TOKEN_FILE" | head -1)"
  token="${token//[[:space:]]/}"
  [[ -n "$token" ]] || die "no token found in ${CLOUDFLARE_API_TOKEN_FILE}"
  printf '%s' "$token"
}

###############################################################################
# Validation
#
# User input reaches these scripts as argv (never via the environment, which
# sudo resets). Every value is re-validated here even though the web service
# already checked it: the scripts must be safe to call directly.
###############################################################################

# Subdomain label: lower-case letters and digits only, 1-32 characters. This is
# deliberately stricter than RFC 1123 (no hyphens) per the UI requirement, and
# it is also what makes the name safe to splice into XML, YAML, nginx config
# and file names without escaping.
is_name() { [[ "$1" =~ ^[a-z0-9]{1,32}$ ]]; }

# The free-text message: 1-200 characters, any printable Unicode, no control
# characters (tabs/newlines included). It is HTML-escaped before it is placed
# in the guest's index.html and never touches a shell or a template directly.
MESSAGE_MAX_LEN=200
is_message() {
  local msg="$1"
  [[ -n "$msg" ]] || return 1
  # Character count in the current locale; byte count as a hard ceiling too.
  (( ${#msg} <= MESSAGE_MAX_LEN )) || return 1
  (( $(LC_ALL=C; echo -n "$msg" | wc -c) <= MESSAGE_MAX_LEN * 4 )) || return 1
  # Reject ASCII control characters (0x00-0x1F, 0x7F).
  ! LC_ALL=C grep -q -P '[\x00-\x1F\x7F]' <<<"$msg"
}

# Refuse names the operator reserved. Names that already exist in DNS are
# refused separately by cloudflare_record_exists.
is_reserved() {
  local name="$1" r
  for r in $RESERVED_NAMES; do
    [[ "$name" == "$r" ]] && return 0
  done
  return 1
}

# HTML-escape stdin -> stdout. Enough for text nodes and double-quoted
# attribute values (&, <, >, ", ').
html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

###############################################################################
# Locking and registry
###############################################################################

# Serialise every mutating operation (provision, deprovision, reap) with a
# single flock. Address allocation, DNS and nginx reloads are not safe to
# interleave, and the host does not need to start two VMs at once anyway.
acquire_lock() {
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock -w "${LOCK_WAIT:-600}" 9 || die "could not acquire ${LOCK_FILE} (another operation is running)"
}

instance_file() { printf '%s/%s.env' "$INSTANCE_DIR" "$1"; }

instance_exists() { [[ -f "$(instance_file "$1")" ]]; }

# Source an instance record, exporting NAME, FQDN, IP, MAC, VM_NAME, ... into
# the caller's shell. Records are written by write_instance below.
load_instance() {
  local file
  file="$(instance_file "$1")"
  [[ -f "$file" ]] || die "no such instance: $1"
  # shellcheck disable=SC1090
  source "$file"
}

# Persist an instance record atomically. Records are world-readable: the web
# service lists them, and they contain nothing sensitive (the message itself
# is base64 so the file stays a clean KEY=VALUE document).
write_instance() {
  local name="$1" file tmp
  file="$(instance_file "$name")"
  tmp="${file}.tmp.$$"
  mkdir -p "$INSTANCE_DIR"
  {
    printf 'NAME=%q\n'          "$name"
    printf 'FQDN=%q\n'          "$FQDN"
    printf 'IP=%q\n'            "$IP"
    printf 'MAC=%q\n'           "$MAC"
    printf 'VM_NAME=%q\n'       "$VM_NAME"
    printf 'CREATED_AT=%q\n'    "$CREATED_AT"
    printf 'EXPIRES_AT=%q\n'    "$EXPIRES_AT"
    printf 'DNS_RECORD_ID=%q\n' "${DNS_RECORD_ID:-}"
    printf 'MESSAGE_B64=%q\n'   "$(printf '%s' "$MESSAGE" | base64 -w0)"
  } >"$tmp"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$file"
}

remove_instance() { rm -f "$(instance_file "$1")"; }

# Names of all registered instances, one per line.
list_instances() {
  [[ -d "$INSTANCE_DIR" ]] || return 0
  local f
  for f in "$INSTANCE_DIR"/*.env; do
    [[ -e "$f" ]] || continue
    basename "$f" .env
  done
}

###############################################################################
# Address allocation
###############################################################################

# Pick the first address in the pool that no registered instance holds and
# that does not answer a ping. The ping is a belt-and-braces check against
# something outside this tool squatting on the pool. Prints "IP MAC".
allocate_address() {
  local -A used=()
  local n ip
  for n in $(list_instances); do
    ip="$(sed -nE 's/^IP=//p' "$(instance_file "$n")")"
    used["$ip"]=1
  done
  local octet
  for (( octet = POOL_START; octet <= POOL_END; octet++ )); do
    ip="${POOL_PREFIX}.${octet}"
    [[ -n "${used[$ip]:-}" ]] && continue
    if ping -c 1 -W 1 "$ip" >/dev/null 2>&1; then
      warn "${ip} is in the pool but answers ping; skipping it"
      continue
    fi
    printf '%s %s\n' "$ip" "$(mac_for_octet "$octet")"
    return 0
  done
  return 1
}

# Deterministic, locally-administered unicast MAC derived from the address so
# the guest's networkd match is unambiguous and ARP tables stay predictable.
# 52:54:00 is the QEMU/KVM OUI; the next two bytes spell "ak".
mac_for_octet() { printf '52:54:00:61:6b:%02x' "$1"; }

###############################################################################
# Misc
###############################################################################

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# Add INSTANCE_TTL_HOURS (fractional allowed) to now and print ISO-8601.
expiry_from_now() {
  local secs
  secs="$(awk -v h="$INSTANCE_TTL_HOURS" 'BEGIN { printf "%d", h * 3600 }')"
  date -u -d "@$(( $(date +%s) + secs ))" +%Y-%m-%dT%H:%M:%SZ
}

virsh_() { virsh -q -c "$LIBVIRT_URI" "$@"; }
