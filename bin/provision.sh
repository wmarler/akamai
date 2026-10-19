#!/usr/bin/env bash
#
# provision.sh NAME MESSAGE
#
# Bring up one ephemeral guest end to end:
#
#   1. validate input and refuse reserved / already-taken names
#   2. allocate a static address + MAC from the pool
#   3. create CNAME INSTANCE_PREFIXNAME.BASE_DOMAIN -> BASE_DOMAIN at Cloudflare
#   4. build an Ignition config (Butane) carrying the user's message
#   5. start a transient libvirt/KVM domain from a qcow2 overlay
#   6. wait for the guest's nginx to answer
#   7. add an nginx server block on the hypervisor and reload
#
# Steps are ordered so that the cheapest-to-undo work happens first, and any
# failure after step 2 rolls back everything done so far (DNS record, domain,
# disk, registry entry). Output is the job log streamed by web/server.py.
#
# Runs as root via a sudoers rule restricted to this exact path; the only
# caller is the web service, but it is equally usable from a shell.

source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/cloudflare.sh"
source "$(dirname "$0")/../lib/vm.sh"
source "$(dirname "$0")/../lib/nginx.sh"

LOG_TAG="provision"

usage() {
  cat <<'EOF'
Usage: provision.sh NAME MESSAGE

  NAME     subdomain label: [a-z0-9]{1,32}
  MESSAGE  text the new site will display: 1-200 printable characters

Environment (development only; sudo strips these for the web service):
  SKIP_DNS=1     do not create the Cloudflare record
  SKIP_NGINX=1   do not touch the hypervisor's nginx
EOF
}

[[ $# -eq 2 ]] || { usage >&2; exit 2; }
NAME="$1"
MESSAGE="$2"

load_config

is_name "$NAME"       || die "invalid name '${NAME}': use 1-32 lower-case letters and digits"
is_message "$MESSAGE" || die "invalid message: 1-${MESSAGE_MAX_LEN} printable characters, no control characters"
is_reserved "$NAME"   && die "'${NAME}' is reserved"

FQDN="$(instance_fqdn "$NAME")"
VM_NAME="akamai-${NAME}"
SKIP_DNS="${SKIP_DNS:-0}"
SKIP_NGINX="${SKIP_NGINX:-0}"

###############################################################################
# Rollback
#
# Each step registers what it did; on any failure the trap undoes it in
# reverse order. Success disarms the trap before exiting.
###############################################################################
ROLLBACK_DNS=0 ROLLBACK_VM=0 ROLLBACK_FILES=0 ROLLBACK_REGISTRY=0 ROLLBACK_NGINX=0
DNS_RECORD_ID=""

rollback() {
  local rc="${1:-1}"
  (( rc == 0 )) && rc=1
  trap - ERR EXIT
  # Nothing in here may abort the handler: every step runs, best effort.
  set +e +o pipefail
  warn "provisioning ${FQDN} failed (exit ${rc}); rolling back"
  (( ROLLBACK_NGINX ))    && { nginx_remove_instance "$FQDN" || true; }
  (( ROLLBACK_VM ))       && { vm_console_tail "$NAME"; vm_destroy "$VM_NAME" || true; }
  (( ROLLBACK_DNS ))      && { cf_delete_record "$DNS_RECORD_ID" || true; }
  (( ROLLBACK_REGISTRY )) && remove_instance "$NAME"
  (( ROLLBACK_FILES ))    && rm -rf "$(vm_dir "$NAME")"
  log "Rollback complete"
  exit "$rc"
}
trap 'rollback $?' ERR
trap 'rc=$?; if (( rc != 0 )); then rollback "$rc"; fi' EXIT

###############################################################################
# 1. Preconditions
###############################################################################
step "Validating request for ${FQDN}"
acquire_lock

instance_exists "$NAME" && die "'${NAME}' already has a live instance"
if virsh_ dominfo "$VM_NAME" >/dev/null 2>&1; then
  die "a libvirt domain named ${VM_NAME} already exists"
fi
if (( ! SKIP_DNS )) && cf_record_exists "$FQDN"; then
  die "${FQDN} already exists in DNS; pick another name"
fi
[[ -r "$BASE_IMAGE" ]] || die "base image missing: ${BASE_IMAGE} (run bin/fetch-image.sh)"
log "Name is available"

###############################################################################
# 2. Address
###############################################################################
step "Allocating an address from ${POOL_PREFIX}.${POOL_START}-${POOL_END}"
read -r IP MAC < <(allocate_address) || die "address pool exhausted; try again later"
log "Allocated ${IP} (${MAC})"

CREATED_AT="$(now_iso)"
EXPIRES_AT="$(expiry_from_now)"

# Register immediately so a concurrent run (after we release the lock on
# exit) cannot pick the same address while we are still booting.
write_instance "$NAME"
ROLLBACK_REGISTRY=1

###############################################################################
# 3. DNS
###############################################################################
if (( SKIP_DNS )); then
  warn "SKIP_DNS set; not creating ${FQDN}"
else
  step "Creating DNS record ${FQDN} CNAME ${BASE_DOMAIN} (proxied=${CLOUDFLARE_PROXIED})"
  DNS_RECORD_ID="$(cf_create_cname "$FQDN" "$BASE_DOMAIN")"
  ROLLBACK_DNS=1
  log "Cloudflare record id ${DNS_RECORD_ID}"
  write_instance "$NAME"
fi

###############################################################################
# 4-5. Guest
###############################################################################
step "Building guest configuration"
mkdir -p "$(vm_dir "$NAME")"
ROLLBACK_FILES=1
vm_build_ignition "$NAME"
vm_create_disk "$NAME"

step "Launching KVM guest ${VM_NAME}"
vm_start "$NAME"
ROLLBACK_VM=1

###############################################################################
# 6. Health
###############################################################################
step "Waiting for the guest to come up"
if ! vm_wait_http "$IP" "$GUEST_BOOT_TIMEOUT"; then
  die "guest did not answer HTTP within ${GUEST_BOOT_TIMEOUT}s"
fi

###############################################################################
# 7. Reverse proxy
###############################################################################
if (( SKIP_NGINX )); then
  warn "SKIP_NGINX set; not configuring the reverse proxy"
else
  step "Configuring reverse proxy ${FQDN} -> ${IP}"
  ROLLBACK_NGINX=1
  nginx_add_instance "$FQDN" "$IP"
fi

trap - ERR EXIT
step "Done: https://${FQDN}/ is live (expires ${EXPIRES_AT})"
# Machine-readable trailer for the web service.
printf 'RESULT url=https://%s/ ip=%s vm=%s expires=%s\n' "$FQDN" "$IP" "$VM_NAME" "$EXPIRES_AT"
