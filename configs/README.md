These templates back the hand-modified and installed configs that I placed on my system to make the demonstration work.

The actual config files are not part of the repository.

---

## How the templates are used

```bash
cp configs/secrets.example configs/actual/secrets   # then edit it
configs/generate_configs.sh                         # fills *.template -> configs/actual/
```

`generate_configs.sh` only writes into `configs/actual/`. Copying the results
into place is done by hand, as listed below. Paths below are the real ones
for this host (`/home/osmc/akamai`, service user `akamai-web`, portal on
`127.0.0.1:8099`).

## What gets added outside this directory

### 1. Service account

```bash
useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin akamai-web
```

No shell, no home, not in `libvirt`/`docker`/`sudo`. Its only privilege is
the sudoers rule below.

### 2. Permissions inside the checkout

| Path | Owner / mode | Why |
|------|--------------|-----|
| `configs/actual/secrets` | `osmc:akamai-web` `0640` | I edit it; the portal reads the non-secret settings; nobody else. |
| `state/`, `state/instances/`, `state/vms/` | `root:root` `0755` | Written only by the root-run scripts; readable so the portal can list instances. |
| `state/jobs/` | `akamai-web:akamai-web` `0750` | The only directory the portal writes. |
| `images/flatcar_production_qemu_image.img` | `0644` | Read by `libvirt-qemu`, which runs the guests. `bin/fetch-image.sh` sets this. |
| `bin/*.sh`, `lib/*.sh` | **not** writable by `akamai-web` | They run as root via sudo. `osmc` ownership is fine. |

```bash
chgrp akamai-web configs/actual/secrets && chmod 0640 configs/actual/secrets
install -d -m 0755 -o root -g root state state/instances state/vms
install -d -m 0750 -o akamai-web -g akamai-web state/jobs
```

### 3. `/etc/sudoers.d/akamai-portal`  ← `configs/actual/sudoers`

```
Defaults:akamai-web !requiretty, env_reset, !lecture
akamai-web ALL=(root) NOPASSWD: /home/osmc/akamai/bin/provision.sh, /home/osmc/akamai/bin/deprovision.sh
```

```bash
visudo -cf configs/actual/sudoers && install -m 0440 -o root -g root configs/actual/sudoers /etc/sudoers.d/akamai-portal
```

### 4. `/etc/systemd/system/`  ← `configs/actual/akamai-web.service`, `akamai-reaper.service`, `akamai-reaper.timer`

* `akamai-web.service`: `web/server.py` as `akamai-web` on `127.0.0.1:8099`.
* `akamai-reaper.timer`: `bin/reap.sh` as root every 5 minutes.

```bash
install -m 0644 configs/actual/akamai-web.service configs/actual/akamai-reaper.service configs/actual/akamai-reaper.timer /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now akamai-web.service akamai-reaper.timer
curl -s http://127.0.0.1:8099/healthz
```

### 5. nginx

Both under paths the `nginx-waf` container already bind-mounts, so the
compose file is untouched.

**a.** The directory the provisioner writes one `FQDN.conf` per live guest
into (and removes on teardown). Each file is rendered from
`nginx/instance.conf.template`.

```bash
mkdir -p /etc/nginx/sites-available/akamai.d
```

**b.** The portal's server block, the `include` for (a), and a regex catch-all
for `akamai-*.wmarler.com` that returns a short "no live instance" page when
there is no matching file in `akamai.d/` (exact names win over the regex).
`configs/actual/akamai.wmarler.com.conf` is the complete file — replace the
existing static-site block with it (or merge the include, upstream, portal
`server`, and catch-all `server` blocks into your layout).

```bash
docker exec nginx-waf nginx -t && systemctl reload nginx
```

### 6. DNS

`CNAME akamai.wmarler.com -> wmarler.com`, proxied — already exists.
Instances get their own records at provision time.

## Removing it

```bash
bin/reap.sh --all
systemctl disable --now akamai-web.service akamai-reaper.timer
rm /etc/systemd/system/akamai-{web.service,reaper.service,reaper.timer}; systemctl daemon-reload
rm /etc/sudoers.d/akamai-portal
# drop the include/upstream/server block from the nginx config, then:
rmdir /etc/nginx/sites-available/akamai.d
docker exec nginx-waf nginx -t && systemctl reload nginx
userdel akamai-web
```
