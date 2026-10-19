#!/usr/bin/env bash
#
# list.sh [--json]
#
# Show live instances from the registry alongside what libvirt and nginx
# actually have, so discrepancies are obvious at a glance.

source "$(dirname "$0")/../lib/common.sh"

load_config

JSON=0
[[ "${1:-}" == "--json" ]] && JSON=1

rows=()
for name in $(list_instances); do
  load_instance "$name"
  state="$(virsh_ domstate "$VM_NAME" 2>/dev/null || echo "absent")"
  if [[ -e "${NGINX_INSTANCE_DIR}/${FQDN}.conf" ]]; then proxy=yes; else proxy=no; fi
  rows+=("${NAME}"$'\t'"${IP}"$'\t'"${state}"$'\t'"${proxy}"$'\t'"${CREATED_AT}"$'\t'"${EXPIRES_AT}")
done

if (( JSON )); then
  printf '%s\n' "${rows[@]}" | jq -R -s '
    split("\n") | map(select(length > 0) | split("\t")
      | {name: .[0], ip: .[1], domain_state: .[2], proxied: (.[3] == "yes"),
         created_at: .[4], expires_at: .[5]})'
else
  {
    printf 'NAME\tIP\tDOMAIN\tPROXY\tCREATED\tEXPIRES\n'
    printf '%s\n' "${rows[@]}"
  } | column -t -s $'\t'
fi
