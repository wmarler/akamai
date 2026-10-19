#!/usr/bin/env bash
#
# Guest lifecycle: build an Ignition config with Butane, lay down a qcow2
# overlay on the shared Flatcar base image, define a transient libvirt domain
# that receives the Ignition config over fw_cfg, and wait for the guest's web
# server to answer.
#
# Why libvirt rather than invoking qemu-system-x86_64 directly (as Flatcar's
# own flatcar_production_qemu.sh does)? libvirt owns the process lifecycle,
# the tap device on the bridge, the AppArmor confinement, and the console log,
# and the result is inspectable with the same virsh commands as every other
# guest on the host. Transient domains (virsh create, not define) mean a
# destroyed instance leaves nothing behind in libvirt's state.

BUTANE_IMAGE="${BUTANE_IMAGE:-quay.io/coreos/butane:release}"

vm_dir() { printf '%s/%s' "$VM_DIR" "$1"; }

# vm_build_ignition NAME  (uses FQDN, IP, MAC, MESSAGE, CREATED_AT from caller)
# Produces <vm_dir>/config.ign. The Butane source is staged alongside it so a
# failed build can be inspected after the fact.
vm_build_ignition() {
  local name="$1" dir stage
  dir="$(vm_dir "$name")"
  stage="${dir}/butane"
  mkdir -p "$stage"

  # index.html: the only place user-controlled text goes. It is HTML-escaped
  # here and shipped as a file (Butane "local:"), so it is never interpolated
  # into YAML, JSON or a shell command.
  local escaped
  escaped="$(printf '%s' "$MESSAGE" | html_escape)"
  render_template "${AKAMAI_DIR}/guest/index.html.template" >"${stage}/index.html" \
    MESSAGE_HTML "$escaped" \
    FQDN "$FQDN" \
    NAME "$name" \
    IP "$IP" \
    CREATED_AT "$CREATED_AT" \
    EXPIRES_AT "$EXPIRES_AT"

  # Optional SSH keys, one per line, rendered as a YAML list. Keys are
  # operator-supplied (from secrets), not user input.
  local keys_yaml="" key
  while IFS= read -r key; do
    [[ -n "$key" ]] || continue
    keys_yaml+="        - \"${key}\""$'\n'
  done <<<"$GUEST_SSH_AUTHORIZED_KEYS"
  if [[ -z "$keys_yaml" ]]; then
    keys_yaml="        []"$'\n'
  fi

  render_template "${AKAMAI_DIR}/guest/guest.bu.template" >"${stage}/guest.bu" \
    NAME "$name" \
    FQDN "$FQDN" \
    IP "$IP" \
    PREFIX_LEN "$POOL_PREFIX_LEN" \
    GATEWAY "$POOL_GATEWAY" \
    DNS "$POOL_DNS" \
    MAC "$MAC" \
    SSH_KEYS_YAML "$keys_yaml"

  log "Transpiling Butane -> Ignition (${BUTANE_IMAGE})"
  docker run --rm -i \
    --volume "${stage}:/pwd:ro" --workdir /pwd \
    "$BUTANE_IMAGE" --strict --files-dir /pwd <"${stage}/guest.bu" >"${dir}/config.ign.tmp"
  mv -f "${dir}/config.ign.tmp" "${dir}/config.ign"
  # Readable by the qemu process (libvirt-qemu), which reads it for fw_cfg.
  chmod 0644 "${dir}/config.ign"
  log "Ignition config: $(relpath_in_repo "${dir}/config.ign") ($(wc -c <"${dir}/config.ign") bytes)"
}

# vm_create_disk NAME -> copy-on-write overlay on the base image. Instances
# share the ~1 GiB base read-only; each overlay starts at a few hundred KiB.
vm_create_disk() {
  local name="$1" dir
  dir="$(vm_dir "$name")"
  [[ -r "$BASE_IMAGE" ]] || die "base image ${BASE_IMAGE} not found; run bin/fetch-image.sh"
  qemu-img create -q -f qcow2 -b "$BASE_IMAGE" -F qcow2 "${dir}/disk.qcow2"
  log "Disk: $(relpath_in_repo "${dir}/disk.qcow2") (qcow2 overlay on $(basename "$BASE_IMAGE"))"
}

# vm_start NAME -> renders the domain XML and starts a transient domain.
vm_start() {
  local name="$1" dir
  dir="$(vm_dir "$name")"
  : >"${dir}/console.log"
  chmod 0644 "${dir}/console.log"

  render_template "${AKAMAI_DIR}/guest/domain.xml.template" >"${dir}/domain.xml" \
    VM_NAME "$VM_NAME" \
    FQDN "$FQDN" \
    NAME "$name" \
    IP "$IP" \
    MAC "$MAC" \
    CREATED_AT "$CREATED_AT" \
    EXPIRES_AT "$EXPIRES_AT" \
    MEMORY_MIB "$GUEST_MEMORY_MIB" \
    VCPUS "$GUEST_VCPUS" \
    BRIDGE "$HOST_BRIDGE" \
    BASE_IMAGE "$BASE_IMAGE" \
    DISK_PATH "${dir}/disk.qcow2" \
    IGNITION_PATH "${dir}/config.ign" \
    CONSOLE_LOG "${dir}/console.log"

  log "Starting libvirt domain ${VM_NAME} (${GUEST_VCPUS} vCPU, ${GUEST_MEMORY_MIB} MiB, ${MAC} on ${HOST_BRIDGE})"
  virsh_ create "${dir}/domain.xml" >/dev/null
}

vm_is_running() {
  virsh_ domstate "$1" 2>/dev/null | grep -q '^running$'
}

# vm_destroy VM_NAME: stop the domain if it exists. Transient domains vanish
# from libvirt on destroy; a defined one would additionally be undefined.
vm_destroy() {
  local vm="$1"
  if virsh_ dominfo "$vm" >/dev/null 2>&1; then
    log "Destroying libvirt domain ${vm}"
    virsh_ destroy "$vm" >/dev/null 2>&1 || true
    virsh_ undefine "$vm" >/dev/null 2>&1 || true
  fi
}

# vm_wait_http IP TIMEOUT_SECS: poll the guest until its nginx answers. The
# guest has to boot, apply Ignition, bring up networking, and pull the nginx
# image, so this normally takes 30-90 s on a warm host.
vm_wait_http() {
  local ip="$1" timeout="$2" start now code
  start="$(date +%s)"
  log "Waiting up to ${timeout}s for http://${ip}/ to answer"
  while :; do
    code="$(curl --silent --output /dev/null --max-time 3 --write-out '%{http_code}' "http://${ip}/" || true)"
    if [[ "$code" == "200" ]]; then
      log "Guest is serving HTTP after $(( $(date +%s) - start ))s"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start >= timeout )); then
      return 1
    fi
    sleep 3
  done
}

# Print the tail of the guest console log, for failure diagnostics.
vm_console_tail() {
  local name="$1" f
  f="$(vm_dir "$name")/console.log"
  [[ -r "$f" ]] || return 0
  log "Last lines of guest console:"
  tail -n 25 "$f" 2>/dev/null | sed 's/^/    | /' || true
}

###############################################################################
# Template rendering
#
# render_template FILE KEY VALUE [KEY VALUE ...] -> stdout
#
# Replaces @@KEY@@ tokens. Values are substituted with bash string replacement
# rather than sed, so no character in a value is special -- which matters for
# the HTML-escaped message and for SSH keys. Callers remain responsible for
# only passing values that are valid in the target format.
###############################################################################
render_template() {
  local file="$1"; shift
  local content
  content="$(<"$file")"
  # bash >= 5.2 expands an unquoted "&" in the replacement to the matched
  # text (patsub_replacement). The HTML-escaped message is full of "&", so
  # quote the replacement and switch the option off for good measure.
  shopt -u patsub_replacement 2>/dev/null || true
  while (( $# >= 2 )); do
    content="${content//"@@$1@@"/"$2"}"
    shift 2
  done
  if [[ "$content" =~ @@[A-Z_]+@@ ]]; then
    die "unrendered placeholder ${BASH_REMATCH[0]} in $(basename "$file")"
  fi
  printf '%s\n' "$content"
}
