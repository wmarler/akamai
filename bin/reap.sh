#!/usr/bin/env bash
#
# reap.sh [--all]
#
# Tear down instances whose EXPIRES_AT has passed (or every instance, with
# --all). Intended to run from the akamai-reaper.timer systemd unit every few
# minutes; also useful by hand. Each teardown is a separate deprovision.sh
# invocation so one stuck instance does not block the others.
#
# It also reports (but does not touch) libvirt domains that look like ours
# (akamai-*) yet have no registry entry, so an operator notices drift.

source "$(dirname "$0")/../lib/common.sh"

LOG_TAG="reap"
ALL=0
[[ "${1:-}" == "--all" ]] && ALL=1

load_config

now="$(date +%s)"
reaped=0 kept=0 failed=0

for name in $(list_instances); do
  expires="$(sed -nE 's/^EXPIRES_AT=//p' "$(instance_file "$name")" | tr -d "'")"
  expires_epoch="$(date -d "$expires" +%s 2>/dev/null || echo 0)"
  if (( ALL )) || (( expires_epoch <= now )); then
    log "${name}: expired at ${expires}; tearing down"
    if "${AKAMAI_DIR}/bin/deprovision.sh" "$name"; then
      reaped=$(( reaped + 1 ))
    else
      failed=$(( failed + 1 ))
    fi
  else
    kept=$(( kept + 1 ))
  fi
done

# Drift check: domains named like ours with no registry entry.
while read -r dom; do
  [[ -n "$dom" ]] || continue
  n="${dom#akamai-}"
  instance_exists "$n" || warn "libvirt domain ${dom} has no registry entry (orphan?)"
done < <(virsh_ list --all --name 2>/dev/null | grep -E '^akamai-' || true)

log "reaped=${reaped} kept=${kept} failed=${failed}"
(( failed == 0 ))
