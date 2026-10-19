# akamai — self-service ephemeral KVM guests from a web form

This is a small, end-to-end piece of infrastructure automation on a single Linux
hypervisor that I self-host. 

I wrote it as an exercise to earn a spot job at Akamai on your HIVE Core Linux
Platforms Team. I want you to see my skills and how I approach this kind of work,
as well as how I document. The provisioning pipeline is observable, rolls itself
back, fails closed, and runs with the least privilege it can, on real hardware,
with real DNS, behind a real WAF.


I **did** use AI assist to create the code of this project. The
infrastructure, Cloudflare proxy (w/API access), Docker-based nginx+waf,
and libvirt hypervisor all predate this demo ... and of course the initiative and
hubris to think that you'd be impressed is 100% my own.

## Concept

A visitor uses the form served by `web/server.py` and submits a hostname and a custom message. This spawns a
QEMU/libvirt-based [Flatcar Container Linux](https://www.flatcar.org/) VM
to run nginx and serve the custom message at `https://akamai-<name>.wmarler.com/` in about
a minute. The VM is destroyed automatically via a reaping command on a systemd timer .


```
                     ┌─────────────────────────────────────────────────────────────┐
  browser            │ hypervisor (Ubuntu 24.04, libvirt 10 / QEMU 8.2, br0)       │
    │                │                                                             │
    │ https          │  nginx + ModSecurity CRS (container, host network)          │
    ▼                │    akamai.wmarler.com ──► 127.0.0.1:WEB_LISTEN_PORT  web/server.py │
 Cloudflare ────────►│    *.wmarler.com (one server block per live guest)          │
  (proxied,          │                               │  sudo (two scripts only)    │
   wildcard TLS)     │                               ▼                             │
    ▲                │                        bin/provision.sh  (root)             │
    │ API            │   ┌──────────────┬────────────┼──────────────┬───────────┐  │
    └────────────────┼── Cloudflare    Butane →     libvirt        health     nginx │
                     │   CNAME         Ignition     transient      poll       block │
                     │                 (fw_cfg)     domain                   +reload│
                     │                               │                             │
                     │                          ┌────▼─────────────────────────┐   │
                     │                          │ guest: Flatcar, static IP    │   │
                     │                          │ from pool, nginx:alpine in   │   │
                     │                          │ Docker serving the message   │   │
                     │                          └──────────────────────────────┘   │
                     └─────────────────────────────────────────────────────────────┘
```

## What happens when you press the button

1. **Validate, twice.** `web/server.py` checks the name (`[a-z0-9]{1,32}`) and the
   message (1–200 printable characters), applies per-client and global rate
   limits, and refuses reserved or already-live names. `provision.sh` then
   re-validates everything from scratch — `web/server.py` is not a trust
   boundary for the root-run scripts.
2. **Allocate.** A static address and a deterministic, locally-administered
   MAC are taken from a small pool on the host bridge, under a `flock` so
   two requests can never collide. The pool size doubles as the hard cap on
   concurrent guests. The address is pinged before use as a guard against
   anything outside this tool squatting on it.
3. **DNS.** `CNAME akamai-<name>.wmarler.com → wmarler.com`, proxied, via the
   Cloudflare v4 API. A name that already exists in the zone is refused.
4. **Build the guest config.** A Butane template is rendered with the
   validated values and transpiled to Ignition (`quay.io/coreos/butane`,
   `--strict`). The user's message is HTML-escaped and shipped as a *file*
   (`local:`), never spliced into YAML, JSON, XML or a shell command.
5. **Boot.** A copy-on-write qcow2 overlay is laid on the shared, checksum-
   verified Flatcar image, and a **transient libvirt domain** is started.
   Ignition reaches the guest over QEMU `fw_cfg`, declared as libvirt's
   native `<sysinfo type='fwcfg'>` so the per-domain AppArmor profile is
   labelled correctly without touching any profile. The guest's serial
   console is captured to a file for post-mortems.
6. **Wait for health.** The provisioner polls the guest's HTTP endpoint (not
   just "the domain is running") — boot, Ignition, static networking,
   `docker pull nginx:alpine`, and the page actually being served. Typically
   40–60 s on this host.
7. **Wire the proxy.** One nginx server block is written for the new
   hostname, `nginx -t` is run, and on success nginx is reloaded. A bad
   render is removed again rather than taking the other sites down.

Every step logs to the job page the user is watching. Any failure after
step 2 runs a rollback that undoes the DNS record, the domain, the disk and
the registry entry in reverse order; the handler itself is immune to errors
(`set +e`) so it always finishes. A systemd timer reaps guests past their
TTL every five minutes and flags any `akamai-*` domain that has no registry
entry.

## Why these choices

* **libvirt rather than bare `qemu-system-x86_64`.** Flatcar's own
  `flatcar_production_qemu.sh` (which I use in my *felix* project) is fine
  for one long-lived VM, but for guests created and destroyed by a web
  request I want something that owns the process lifecycle, the tap device
  on the bridge, the security labelling, and that is inspectable with the
  same `virsh` commands as every other guest on the host. Transient domains
  mean a destroyed guest leaves nothing behind in libvirt's state.
* **Static address pool, not DHCP + ARP scraping.** The proxy entry has to
  be written before the user can use the site; a deterministic address means
  no polling leases, no race, and a predictable cap on resources. Since I
  also own the DHCP server on the network, I can set it not to hand out
  IPs from this reserved range.
* **Ignition over `fw_cfg`, not a config drive or an HTTP fetch.** It is the
  mechanism Flatcar's QEMU image is built for, needs no network to fetch
  configuration, and nothing user-controlled ends up on a listening
  endpoint.
* **A tiny stdlib-only Python service, not PHP.** nginx and php-fpm run in
  containers on this host, so neither can escalate to the hypervisor. The
  `web/server.py` is a host-side daemon under its own unprivileged account; its
  only privilege is a sudoers rule naming two executables.
* **Bash for the privileged path.** The operations are "run these six
  tools in order and undo them if something fails" — the natural home for
  a shell script with `set -euo pipefail`, a `flock`, and `trap`-driven
  rollback. Everything that is interpolated anywhere is regex-validated
  first; the only free text (the message) is escaped and passed as a file.
* **Fail closed, everywhere.** Unknown placeholder in a template → abort.
  `nginx -t` fails → remove the file. Teardown incomplete → keep the
  registry entry so the address stays reserved and the reaper retries.

## Repository layout

| Path | What |
|------|------|
| `web/server.py` | Form, JSON API, job queue, rate limits, per-job log streaming. Python 3 stdlib only. |
| `web/templates/`, `web/static/` | HTML/CSS/JS. Works without JavaScript; with it, logs stream and the instance table updates. |
| `bin/provision.sh` | Root entry point: name + message in, running guest out, rollback on failure. |
| `bin/deprovision.sh` | Idempotent teardown of one guest (nginx, domain, DNS, files, registry). |
| `bin/reap.sh` | TTL enforcement; run by `akamai-reaper.timer`. `--all` tears everything down. |
| `bin/list.sh` | Registry vs. libvirt vs. nginx, side by side (`--json` too). |
| `bin/fetch-image.sh` | Download + SHA-512 verify the Flatcar QEMU image. |
| `lib/common.sh` | Config loading, validation, logging, locking, address pool, instance registry. |
| `lib/cloudflare.sh`, `lib/vm.sh`, `lib/nginx.sh` | The three integrations, each a page long. |
| `guest/guest.bu.template` | Butane config for the guest (static network, masked updates, `web.service`). |
| `guest/domain.xml.template` | libvirt domain: q35, host-passthrough, qcow2 overlay, bridge NIC, fw_cfg, serial-to-file. |
| `guest/index.html.template` | The page the guest serves. |
| `nginx/instance.conf.template` | Per-guest server block written on the hypervisor. |
| `configs/*.template` + `configs/generate_configs.sh` | nginx vhost, sudoers, systemd units — filled in from the secrets file into `configs/actual/`, then copied into place by hand. |
| `configs/README.md` | **Exactly** what has to be added outside this directory, and why. |
| `secrets.example` | Every deployment-specific value, including `AKAMAI_DIR`. The real `secrets` file is git-ignored. |

Runtime state lives under `state/` (git-ignored): `instances/<name>.env`
registry records, `vms/<name>/` (overlay disk, Ignition, domain XML, console
log, staged Butane), `jobs/` (`web/server.py` job records and logs).

## Running it

I don't go into a bunch of detail here. The point of this repository isn't to
make something portable and reusable for someone else.

The reason I used a "secrets" file and "generate_configs.sh" and other helper
scripts in lib/*.sh was to reduce my own human error in copying and pasting
file paths around. I also didn't want to commit the actual paths on my server
to a public repo. 

```bash
cp secrets.example secrets                             # AKAMAI_DIR, token, zone, domain, pool, paths
bin/fetch-image.sh                                     # ~600 MB, checksum-verified
configs/generate_configs.sh                            # -> configs/actual/*
# then follow configs/README.md (user, sudoers, two systemd units, one nginx file)
```

Some tools, monitoring, etc:

```bash
bin/list.sh                                 # what is live
journalctl -fu akamai-web.service           # web/server.py log (one line per request/job)
systemctl list-timers 'akamai-*'            # reaper schedule
bin/provision.sh bob "Hello"                # What the button in the web UI does, but from the shell
bin/deprovision.sh bob                      # Manually destroy a VM.
virsh -c qemu:///system console akamai-bob  # or state/vms/bob/console.log
```

The scripts honour `SKIP_DNS=1` / `SKIP_NGINX=1` for development (sudo
strips them, so `web/server.py` cannot set them). The checkout path is
`AKAMAI_DIR` in `secrets`.

## Security model, briefly

* `web/server.py`: unprivileged system user, loopback only (`WEB_LISTEN_PORT` in
  `secrets`), behind nginx + ModSecurity CRS at Cloudflare's edge. No cookies or
  sessions; CSRF is handled with `Sec-Fetch-Site`/`Origin` checks, a strict CSP,
  and the destroy action needing a per-job secret that only the creating browser
  ever receives.
* Escalation: `/etc/sudoers.d/akamai-portal` allows exactly
  `bin/provision.sh` and `bin/deprovision.sh`, which must not be writable by
  the service account. The Cloudflare token stays in a root-only file; the
  service account never reads it.
* Guests: 1 vCPU / 1 GiB, no SSH keys, auto-updates masked, nginx container
  read-only with capabilities dropped, addresses confined to the pool, lifetime
  bounded by the reaper.
* Abuse limits: per-client hourly limit, global queue depth, pool-size
  capacity, reserved names, DNS-collision refusal.
* AppArmor enforcing on the transient domain with the `fw_cfg` file.

## What I would do next

* Expose the instance registry and job outcomes as Prometheus metrics
  (provision duration, failures by step, pool occupancy)
* Swap the shell lock/registry for libvirt metadata as the single source of
  truth (the domain XML already carries it) so `list.sh` needs no files.
