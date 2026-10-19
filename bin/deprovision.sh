#!/usr/bin/env bash
#
# deprovision.sh NAME
#
# Tear down everything provision.sh created for NAME: nginx server block,
# libvirt domain, DNS record, disk/ignition files, registry entry. Each step
# is independent and tolerant of the thing already being gone, so this is
# safe to re-run after a partial failure and is what bin/reap.sh calls.

source /home/osmc/akamai/lib/common.sh
source /home/osmc/akamai/lib/cloudflare.sh
source /home/osmc/akamai/lib/vm.sh
source /home/osmc/akamai/lib/nginx.sh

LOG_TAG="deprovision"

[[ $# -eq 1 ]] || { echo "Usage: deprovision.sh NAME" >&2; exit 2; }
NAME="$1"

load_config

is_name "$NAME" || die "invalid name '${NAME}'"

acquire_lock
instance_exists "$NAME" || die "no such instance: ${NAME}"
load_instance "$NAME"

step "Tearing down ${FQDN} (${VM_NAME}, ${IP})"
failed=0

if (( ${SKIP_NGINX:-0} )); then
  warn "SKIP_NGINX set; leaving nginx alone"
else
  nginx_remove_instance "$FQDN" || failed=1
fi

vm_destroy "$VM_NAME" || failed=1

if [[ -n "${DNS_RECORD_ID:-}" ]]; then
  log "Deleting DNS record ${FQDN} (${DNS_RECORD_ID})"
  cf_delete_record "$DNS_RECORD_ID" || failed=1
else
  log "No DNS record was registered for ${FQDN}"
fi

rm -rf "$(vm_dir "$NAME")"
log "Removed $(vm_dir "$NAME")"

if (( failed )); then
  # Keep the registry entry so the reaper retries and the address stays
  # reserved until the leftovers are really gone.
  die "teardown of ${FQDN} incomplete; registry entry kept for retry"
fi

remove_instance "$NAME"
step "Done: ${FQDN} is gone and ${IP} is back in the pool"
