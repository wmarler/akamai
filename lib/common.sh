#!/usr/bin/env bash
#
# Shared helpers for the provisioning scripts: configuration, logging, input
# validation, locking and the on-disk instance registry.
#
# Scripts source this file, then call load_config. The checkout path comes from
# AKAMAI_DIR in secrets (not from anything committed in the repo).
#
# Nothing here is interactive and nothing here prompts; all scripts are run
# unattended from web/server.py (via sudo) or from a systemd timer.

set -euo pipefail

# Locate secrets: always at <checkout>/secrets (checkout inferred from lib/).
_libdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS_FILE="$(cd "${_libdir}/.." && pwd)/secrets"

# Set by load_config after sourcing secrets.
AKAMAI_DIR=""
STATE_DIR=""
INSTANCE_DIR=""
VM_DIR=""
BASE_IMAGE=""
LOCK_FILE=""

###############################################################################
# Logging
###############################################################################

log()  { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${LOG_TAG:-akamai}" "$*"; }
warn() { log "WARNING: $*" >&2; }
die()  { log "ERROR: $*" >&2; exit 1; }

step() { log "==> $*"; }

###############################################################################
# Configuration
###############################################################################

load_config() {
  [[ -f "$SECRETS_FILE" ]] || die "missing ${SECRETS_FILE} (copy secrets.example to secrets and edit it)"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"

  local var
  for var in AKAMAI_DIR BASE_DOMAIN PORTAL_HOST HOST_BRIDGE POOL_PREFIX POOL_START POOL_END \
             POOL_PREFIX_LEN POOL_GATEWAY POOL_DNS GUEST_MEMORY_MIB GUEST_VCPUS \
             GUEST_BOOT_TIMEOUT INSTANCE_TTL_HOURS SERVICE_USER WEB_LISTEN_PORT \
             NGINX_INSTANCE_DIR NGINX_SSL_SNIPPET NGINX_TEST_CMD NGINX_RELOAD_CMD \
             CLOUDFLARE_PROXIED LIBVIRT_URI INSTANCE_PREFIX; do
    [[ -n "${!var:-}" ]] || die "${var} is not set in ${SECRETS_FILE}"
  done
  RESERVED_NAMES="${RESERVED_NAMES:-}"
  GUEST_SSH_AUTHORIZED_KEYS="${GUEST_SSH_AUTHORIZED_KEYS:-}"

  STATE_DIR="${AKAMAI_DIR}/state"
  INSTANCE_DIR="${STATE_DIR}/instances"
  VM_DIR="${STATE_DIR}/vms"
  BASE_IMAGE="${AKAMAI_DIR}/images/flatcar_production_qemu_image.img"
  LOCK_FILE="${STATE_DIR}/provision.lock"
}

instance_fqdn() { printf '%s%s.%s' "$INSTANCE_PREFIX" "$1" "$BASE_DOMAIN"; }

# User-visible logs (job page): paths under AKAMAI_DIR only, without the checkout prefix.
relpath_in_repo() {
  local p="$1"
  [[ -n "${AKAMAI_DIR:-}" ]] || { printf '%s\n' "$p"; return; }
  case "$p" in
    "${AKAMAI_DIR}/"*) printf '%s\n' "${p#"${AKAMAI_DIR}/"}" ;;
    "${AKAMAI_DIR}") printf '.' ;;
    *) printf '%s\n' "$p" ;;
  esac
}

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
###############################################################################

is_name() { [[ "$1" =~ ^[a-z0-9]{1,32}$ ]]; }

MESSAGE_MAX_LEN=200
is_message() {
  local msg="$1"
  [[ -n "$msg" ]] || return 1
  (( ${#msg} <= MESSAGE_MAX_LEN )) || return 1
  (( $(LC_ALL=C; echo -n "$msg" | wc -c) <= MESSAGE_MAX_LEN * 4 )) || return 1
  ! LC_ALL=C grep -q -P '[\x00-\x1F\x7F]' <<<"$msg"
}

is_reserved() {
  local name="$1" r
  for r in $RESERVED_NAMES; do
    [[ "$name" == "$r" ]] && return 0
  done
  return 1
}

html_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&#39;/g"
}

###############################################################################
# Locking and registry
###############################################################################

acquire_lock() {
  mkdir -p "$STATE_DIR"
  exec 9>"$LOCK_FILE"
  flock -w "${LOCK_WAIT:-600}" 9 || die "could not acquire ${LOCK_FILE} (another operation is running)"
}

instance_file() { printf '%s/%s.env' "$INSTANCE_DIR" "$1"; }

instance_exists() { [[ -f "$(instance_file "$1")" ]]; }

load_instance() {
  local file
  file="$(instance_file "$1")"
  [[ -f "$file" ]] || die "no such instance: $1"
  # shellcheck disable=SC1090
  source "$file"
}

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

list_instances() {
  [[ -d "$INSTANCE_DIR" ]] || return 0
  local f
  for f in "$INSTANCE_DIR"/*.env; do
    [[ -e "$f" ]] || continue
    basename "$f" .env
  done
}

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

mac_for_octet() { printf '52:54:00:61:6b:%02x' "$1"; }

now_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

expiry_from_now() {
  local secs
  secs="$(awk -v h="$INSTANCE_TTL_HOURS" 'BEGIN { printf "%d", h * 3600 }')"
  date -u -d "@$(( $(date +%s) + secs ))" +%Y-%m-%dT%H:%M:%SZ
}

virsh_() { virsh -q -c "$LIBVIRT_URI" "$@"; }
