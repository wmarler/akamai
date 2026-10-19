#!/usr/bin/env bash
#
# Cloudflare DNS helpers (API v4, bearer-token auth). Requires curl and jq.
#
# Every request is a single curl call with a short timeout; failures are
# reported with Cloudflare's own error text so they are actionable from the job log.

CF_API="https://api.cloudflare.com/client/v4"

# cf_api METHOD PATH [JSON_BODY]  -> prints the response body, fails on
# transport errors or "success": false.
cf_api() {
  local method="$1" path="$2" body="${3:-}"
  local -a args=(
    --silent --show-error --fail-with-body
    --max-time 20
    --request "$method"
    --header "Authorization: Bearer $(cloudflare_token)"
    --header "Content-Type: application/json"
  )
  [[ -n "$body" ]] && args+=(--data "$body")
  local resp
  if ! resp="$(curl "${args[@]}" "${CF_API}${path}" 2>&1)"; then
    die "Cloudflare API ${method} ${path} failed: $(jq -r '.errors[]?.message' <<<"$resp" 2>/dev/null || printf '%s' "$resp")"
  fi
  if [[ "$(jq -r '.success' <<<"$resp" 2>/dev/null)" != "true" ]]; then
    die "Cloudflare API ${method} ${path} returned an error: $(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp")"
  fi
  printf '%s' "$resp"
}

# Resolve and memoise the zone ID. Cached under state/ 
cf_zone_id() {
  if [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
    printf '%s' "$CLOUDFLARE_ZONE_ID"
    return
  fi
  local cache="${STATE_DIR}/cloudflare_zone_id"
  if [[ -s "$cache" ]]; then
    CLOUDFLARE_ZONE_ID="$(<"$cache")"
    printf '%s' "$CLOUDFLARE_ZONE_ID"
    return
  fi
  local id
  id="$(cf_api GET "/zones?name=${BASE_DOMAIN}&status=active" | jq -r '.result[0].id // empty')"
  [[ -n "$id" ]] || die "no active Cloudflare zone named ${BASE_DOMAIN} is visible to this token"
  mkdir -p "$STATE_DIR"
  printf '%s' "$id" >"$cache"
  CLOUDFLARE_ZONE_ID="$id"
  printf '%s' "$id"
}

# cf_record_lookup FQDN -> prints "ID TYPE CONTENT" for any record of that
# exact name (any type), or nothing.
cf_record_lookup() {
  local fqdn="$1"
  cf_api GET "/zones/$(cf_zone_id)/dns_records?name=${fqdn}&per_page=5" \
    | jq -r '.result[] | [.id, .type, .content] | @tsv'
}

cf_record_exists() { [[ -n "$(cf_record_lookup "$1")" ]]; }

# cf_create_cname FQDN TARGET -> prints the new record ID.
cf_create_cname() {
  local fqdn="$1" target="$2"
  local body
  body="$(jq -nc --arg name "$fqdn" --arg content "$target" --argjson proxied "$CLOUDFLARE_PROXIED" \
    '{type: "CNAME", name: $name, content: $content, ttl: 1, proxied: $proxied,
      comment: "managed by akamai provisioner"}')"
  cf_api POST "/zones/$(cf_zone_id)/dns_records" "$body" | jq -r '.result.id'
}

# cf_delete_record ID. Tolerates an already-deleted record so that rollback
# and reaping are idempotent.
cf_delete_record() {
  local id="$1" resp
  [[ -n "$id" ]] || return 0
  if ! resp="$(curl --silent --max-time 20 --request DELETE \
      --header "Authorization: Bearer $(cloudflare_token)" \
      "${CF_API}/zones/$(cf_zone_id)/dns_records/${id}")"; then
    warn "could not delete DNS record ${id} (transport error)"
    return 1
  fi
  if [[ "$(jq -r '.success' <<<"$resp")" != "true" ]]; then
    if jq -e '.errors[]? | select(.code == 81044)' <<<"$resp" >/dev/null; then
      log "DNS record ${id} was already gone"
      return 0
    fi
    warn "could not delete DNS record ${id}: $(jq -r '[.errors[]?.message] | join("; ")' <<<"$resp")"
    return 1
  fi
}
