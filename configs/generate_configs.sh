#!/usr/bin/env bash
#
# Fill in configs/*.template from configs/actual/secrets and write the results
# to configs/actual/. Those are the files to copy into place by hand (see
# configs/README.md). This script writes nowhere else.

source /home/osmc/akamai/lib/common.sh
source /home/osmc/akamai/lib/vm.sh   # for render_template

LOG_TAG="generate-configs"
load_config

IN="${AKAMAI_DIR}/configs"
OUT="${AKAMAI_DIR}/configs/actual"
mkdir -p "$OUT"

# Dots in the domain (and any regex metachars in the prefix) must be escaped
# for the catch-all server_name regex.
BASE_DOMAIN_REGEX="${BASE_DOMAIN//./\\.}"
INSTANCE_PREFIX_REGEX="$(printf '%s' "$INSTANCE_PREFIX" | sed 's/[][().^$*+?{|}\\]/\\&/g')"

render() {
  render_template "${IN}/$1" >"${OUT}/$2" \
    AKAMAI_DIR "$AKAMAI_DIR" \
    SERVICE_USER "$SERVICE_USER" \
    PORTAL_HOST "$PORTAL_HOST" \
    BASE_DOMAIN "$BASE_DOMAIN" \
    BASE_DOMAIN_REGEX "$BASE_DOMAIN_REGEX" \
    INSTANCE_PREFIX "$INSTANCE_PREFIX" \
    INSTANCE_PREFIX_REGEX "$INSTANCE_PREFIX_REGEX" \
    WEB_LISTEN_PORT "$WEB_LISTEN_PORT" \
    NGINX_INSTANCE_DIR "$NGINX_INSTANCE_DIR" \
    NGINX_SSL_SNIPPET "$NGINX_SSL_SNIPPET"
  log "wrote ${OUT}/$2"
}

render nginx-portal.conf.template      "${PORTAL_HOST}.conf"
render sudoers.template                "sudoers"
render akamai-web.service.template     "akamai-web.service"
render akamai-reaper.service.template  "akamai-reaper.service"
render akamai-reaper.timer.template    "akamai-reaper.timer"

visudo -cf "${OUT}/sudoers" >/dev/null && log "sudoers syntax OK"
