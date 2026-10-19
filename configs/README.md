These templates back the hand-modified and installed configs that I placed on my system to make the demonstration work.

The actual config files are not part of the repository.

---

## How the templates are used

```bash
cp secrets.example secrets   # then edit it (set AKAMAI_DIR to this checkout)
configs/generate_configs.sh  # fills *.template -> configs/actual/
```

Copying the results into place is done by hand

## What gets added outside this directory

### 1. Service account

No shell, no home, not in `libvirt`/`docker`/`sudo`. Its only privilege is
the sudoers rule below.

### 2. Permissions inside the checkout

| Path | Owner / mode | Why |
|------|--------------|-----|
| `secrets` | `0640` | The single source of truth for configs. note: the backend web/server.py service references it, so it must be readable by the service account  |
| `state/`, `state/instances/`, `state/vms/` | `root:root` `0755` | Written only by the root-run scripts; readable so web/server.py can list instances. |
| `state/jobs/` | `akamai-web:akamai-web` `0750` | The only directory web/server.py writes. |
| `images/flatcar_production_qemu_image.img` | `0644` | Read by `libvirt-qemu`, which runs the guests. `bin/fetch-image.sh` sets this. |
| `bin/*.sh`, `lib/*.sh` | **not** writable by the service account | They run as root via sudo. Ownership same as the repository root is fine. |


### 3. nginx

The provisioner writes (and removes on teardown) one `FQDN.conf` per live guest into
my existing nginx/sites-available dir. Each file is rendered from
`nginx/instance.conf.template`.

The `PORTAL_HOST` server block (proxy to web/server.py) includes a regex catch-all for `akamai-*.wmarler.com` that returns
a short "no live instance" page when there is no matching `FQDN.conf` file. Exact names
win over the regex.

Modifications to the nginx sites-available dir require a reload of nginx; this is gated
by running "nginx -t" first.

### 6. DNS

`CNAME akamai.wmarler.com -> wmarler.com`, proxied — already exists.
Instances get their own records at provision time.

## Removing it

Some quick notes for my future self

```bash
bin/reap.sh --all
systemctl disable --now akamai-web.service akamai-reaper.timer
rm /etc/systemd/system/akamai-{web.service,reaper.service,reaper.timer}; systemctl daemon-reload
rm /etc/sudoers.d/akamai-portal
# drop the include/upstream/server block from the nginx config, then:
rmdir /etc/nginx/sites-available/akamai.d
docker exec nginx-waf nginx -t && systemctl reload nginx
userdel <service account>
```
