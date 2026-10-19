#!/usr/bin/env bash
#
# Reverse-proxy wiring on the hypervisor's nginx.
#
# Each instance gets one file in NGINX_INSTANCE_DIR, rendered from
# nginx/instance.conf.template, that terminates TLS with the zone's wildcard
# certificate and proxies to the guest's address on the bridge. The portal's
# own server block (configs/nginx-portal.conf.template) carries an
# "include NGINX_INSTANCE_DIR/*.conf;" so nothing else in the nginx tree is
# touched at runtime.
#
# Every change is validated with NGINX_TEST_CMD before NGINX_RELOAD_CMD. If
# validation fails the new file is removed again, so a bad render can never
# take the rest of the sites down with it.

nginx_conf_path() { printf '%s/%s.conf' "$NGINX_INSTANCE_DIR" "$1"; }

# nginx_add_instance FQDN IP
nginx_add_instance() {
  local fqdn="$1" ip="$2" conf tmp
  conf="$(nginx_conf_path "$fqdn")"
  tmp="${conf}.tmp.$$"
  mkdir -p "$NGINX_INSTANCE_DIR"
  render_template "${AKAMAI_DIR}/nginx/instance.conf.template" >"$tmp" \
    FQDN "$fqdn" \
    IP "$ip" \
    SSL_SNIPPET "$NGINX_SSL_SNIPPET"
  chmod 0644 "$tmp"
  mv -f "$tmp" "$conf"
  log "Wrote ${conf}"

  if ! nginx_test; then
    rm -f "$conf"
    die "nginx rejected the generated configuration; removed ${conf}"
  fi
  nginx_reload
}

# nginx_remove_instance FQDN
nginx_remove_instance() {
  local fqdn="$1" conf
  conf="$(nginx_conf_path "$fqdn")"
  [[ -e "$conf" ]] || return 0
  rm -f "$conf"
  log "Removed ${conf}"
  if nginx_test; then
    nginx_reload
  else
    warn "nginx configuration is invalid after removing ${conf}; not reloading"
    return 1
  fi
}

nginx_test() {
  local out
  if out="$(eval "$NGINX_TEST_CMD" 2>&1)"; then
    log "nginx configuration test passed"
    return 0
  fi
  warn "nginx configuration test failed:"
  printf '%s\n' "$out" | sed 's/^/    | /' >&2
  return 1
}

nginx_reload() {
  log "Reloading nginx (${NGINX_RELOAD_CMD})"
  eval "$NGINX_RELOAD_CMD"
}
