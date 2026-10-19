#!/usr/bin/env python3
"""
web/server.py: a form that provisions an ephemeral Flatcar guest.

Design notes
------------
* Standard library only. There is nothing to install on the hypervisor and
  nothing to keep patched beyond Python itself.
* The service runs as an unprivileged user and never touches DNS, libvirt or
  nginx itself. Each request becomes a *job* that runs ``sudo bin/provision.sh``
  (or ``deprovision.sh``); sudoers restricts that user to exactly those two
  executables. All privileged logic lives in the scripts, which re-validate
  their arguments, so `web/server.py` is not a trust boundary for them.
* Jobs run one at a time from a worker thread; the user watches the script's
  log stream in the browser. Job state is persisted as JSON + log files under
  ``state/jobs`` so a restart does not lose history.
* It binds to loopback only on ``WEB_LISTEN_PORT`` from ``secrets``. nginx
  terminates TLS, applies the WAF, and forwards ``X-Real-IP`` for rate limiting.
"""

from __future__ import annotations

import html
import json
import logging
import queue
import re
import secrets
import shlex
import subprocess
import sys
import threading
import time
import urllib.parse
from dataclasses import asdict, dataclass, field
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Optional

# Bootstrap: find secrets next to this file's checkout. AKAMAI_DIR itself
# comes from secrets after load (see Settings.load / configure_paths).
_CHECKOUT = Path(__file__).resolve().parent.parent
SECRETS_FILE = _CHECKOUT / "secrets"

# Defaults until Settings.load() reads AKAMAI_DIR from secrets.
REPO_DIR = _CHECKOUT
WEB_DIR = _CHECKOUT / "web"
STATE_DIR = _CHECKOUT / "state"
INSTANCE_DIR = STATE_DIR / "instances"
JOBS_DIR = STATE_DIR / "jobs"
PROVISION = _CHECKOUT / "bin" / "provision.sh"
DEPROVISION = _CHECKOUT / "bin" / "deprovision.sh"


def configure_paths(akamai_dir: Path) -> None:
    global REPO_DIR, WEB_DIR, STATE_DIR, INSTANCE_DIR, JOBS_DIR, PROVISION, DEPROVISION
    REPO_DIR = akamai_dir
    WEB_DIR = akamai_dir / "web"
    STATE_DIR = akamai_dir / "state"
    INSTANCE_DIR = STATE_DIR / "instances"
    JOBS_DIR = STATE_DIR / "jobs"
    PROVISION = akamai_dir / "bin" / "provision.sh"
    DEPROVISION = akamai_dir / "bin" / "deprovision.sh"

NAME_RE = re.compile(r"^[a-z0-9]{1,32}$")
MESSAGE_MAX = 200
JOB_ID_RE = re.compile(r"^[a-f0-9]{16}$")
MAX_QUEUE = 5
JOB_RETENTION = timedelta(days=7)

log = logging.getLogger("akamai-web")


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
def load_secrets(path: Path) -> dict[str, str]:
    """Parse the KEY="value" file shared with the bash scripts.

    Only simple assignments are supported, on purpose. Note that this
    process can read every line of the file; if you would rather the web
    service never see the Cloudflare token, leave CLOUDFLARE_API_TOKEN empty
    and point CLOUDFLARE_API_TOKEN_FILE at a root-only file instead -- the
    token is only ever used by the root-run scripts.
    """
    conf: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            continue
        try:
            parts = shlex.split(value, comments=True)
        except ValueError:
            continue
        conf[key] = parts[0] if parts else ""
    return conf


@dataclass(frozen=True)
class Settings:
    base_domain: str
    site_host: str  # PORTAL_HOST in secrets: nginx vhost that proxies here
    listen_port: int
    reserved: frozenset[str]
    ttl_hours: float
    pool_size: int
    rate_limit_per_ip: int
    repo_url: str
    instance_prefix: str

    def fqdn(self, name: str) -> str:
        return f"{self.instance_prefix}{name}.{self.base_domain}"

    @classmethod
    def load(cls) -> "Settings":
        if not SECRETS_FILE.is_file():
            sys.exit(f"missing {SECRETS_FILE}; copy secrets.example to secrets and edit it")
        c = load_secrets(SECRETS_FILE)
        try:
            configure_paths(Path(c["AKAMAI_DIR"]))
            return cls(
                base_domain=c["BASE_DOMAIN"],
                site_host=c["PORTAL_HOST"],
                listen_port=int(c["WEB_LISTEN_PORT"]),
                reserved=frozenset(c.get("RESERVED_NAMES", "").split()),
                ttl_hours=float(c.get("INSTANCE_TTL_HOURS", "2")),
                pool_size=int(c["POOL_END"]) - int(c["POOL_START"]) + 1,
                rate_limit_per_ip=int(c.get("RATE_LIMIT_PER_IP_PER_HOUR", "3")),
                repo_url=c.get("REPO_URL", ""),
                instance_prefix=c["INSTANCE_PREFIX"],
            )
        except (KeyError, ValueError) as exc:
            sys.exit(f"bad or missing setting in {path}: {exc}")


# --------------------------------------------------------------------------- #
# Instance registry (read-only view of what the scripts wrote)
# --------------------------------------------------------------------------- #
def read_env_file(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        if len(v) >= 2 and v[0] == v[-1] and v[0] in "'\"":
            v = v[1:-1]
        out[k] = v
    return out


def list_instances() -> list[dict]:
    items = []
    if not INSTANCE_DIR.is_dir():
        return items
    for f in sorted(INSTANCE_DIR.glob("*.env")):
        try:
            e = read_env_file(f)
            items.append({
                "name": e.get("NAME", f.stem),
                "fqdn": e.get("FQDN", ""),
                "url": f"https://{e.get('FQDN', '')}/",
                "created_at": e.get("CREATED_AT", ""),
                "expires_at": e.get("EXPIRES_AT", ""),
            })
        except OSError:
            continue
    items.sort(key=lambda i: i["created_at"], reverse=True)
    return items


def instance_exists(name: str) -> bool:
    return (INSTANCE_DIR / f"{name}.env").is_file()


# --------------------------------------------------------------------------- #
# Jobs
# --------------------------------------------------------------------------- #
def utcnow() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


@dataclass
class Job:
    id: str
    kind: str                   # "provision" | "deprovision"
    name: str
    message: str
    client_ip: str
    status: str = "queued"      # queued | running | succeeded | failed
    created_at: str = field(default_factory=utcnow)
    started_at: Optional[str] = None
    finished_at: Optional[str] = None
    exit_code: Optional[int] = None
    url: Optional[str] = None
    expires_at: Optional[str] = None
    destroy_token: str = field(default_factory=lambda: secrets.token_urlsafe(24))

    @property
    def json_path(self) -> Path:
        return JOBS_DIR / f"{self.id}.json"

    @property
    def log_path(self) -> Path:
        return JOBS_DIR / f"{self.id}.log"

    def save(self) -> None:
        tmp = self.json_path.with_suffix(".tmp")
        tmp.write_text(json.dumps(asdict(self)), encoding="utf-8")
        tmp.replace(self.json_path)

    def public(self) -> dict:
        """What the browser may see (no destroy token, no client IP)."""
        d = asdict(self)
        d.pop("destroy_token")
        d.pop("client_ip")
        return d

    def log_text(self) -> str:
        try:
            return self.log_path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            return ""


class JobRunner:
    """Executes jobs sequentially in a background thread."""

    def __init__(self) -> None:
        self.jobs: dict[str, Job] = {}
        self.queue: "queue.Queue[str]" = queue.Queue()
        self.lock = threading.Lock()
        JOBS_DIR.mkdir(parents=True, exist_ok=True)
        self._restore()
        threading.Thread(target=self._worker, name="job-worker", daemon=True).start()

    def _restore(self) -> None:
        cutoff = datetime.now(timezone.utc) - JOB_RETENTION
        for f in JOBS_DIR.glob("*.json"):
            try:
                job = Job(**json.loads(f.read_text(encoding="utf-8")))
            except (OSError, ValueError, TypeError):
                continue
            created = datetime.strptime(job.created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            if created < cutoff:
                f.unlink(missing_ok=True)
                job.log_path.unlink(missing_ok=True)
                continue
            if job.status in ("queued", "running"):
                # We were restarted mid-job; the script's own rollback/reaper
                # handles the instance, we only correct the record.
                job.status = "failed"
                job.finished_at = utcnow()
                job.exit_code = -1
                with job.log_path.open("a", encoding="utf-8") as fh:
                    fh.write("\n[web/server.py restarted while this job was active; marking failed]\n")
                job.save()
            self.jobs[job.id] = job

    # -- public API ------------------------------------------------------- #
    def submit(self, kind: str, name: str, message: str, client_ip: str) -> Job:
        job = Job(id=secrets.token_hex(8), kind=kind, name=name, message=message, client_ip=client_ip)
        with self.lock:
            self.jobs[job.id] = job
            job.log_path.write_text("", encoding="utf-8")
            job.save()
        self.queue.put(job.id)
        return job

    def get(self, job_id: str) -> Optional[Job]:
        return self.jobs.get(job_id)

    def queue_depth(self) -> int:
        return sum(1 for j in self.jobs.values() if j.status in ("queued", "running"))

    def position(self, job: Job) -> int:
        """1-based position in line for a queued job (0 if running/done)."""
        if job.status != "queued":
            return 0
        ahead = [j for j in self.jobs.values()
                 if j.status in ("queued", "running") and j.created_at <= job.created_at and j.id != job.id]
        return len(ahead) + 1

    def recent_by_ip(self, client_ip: str, window: timedelta) -> int:
        cutoff = datetime.now(timezone.utc) - window
        n = 0
        for j in self.jobs.values():
            if j.kind != "provision" or j.client_ip != client_ip:
                continue
            created = datetime.strptime(j.created_at, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
            if created >= cutoff:
                n += 1
        return n

    def active_name(self, name: str) -> bool:
        return any(j.name == name and j.status in ("queued", "running") for j in self.jobs.values())

    def recent(self, limit: int = 10) -> list[dict]:
        jobs = sorted(self.jobs.values(), key=lambda j: j.created_at, reverse=True)
        return [j.public() for j in jobs[:limit]]

    # -- worker ----------------------------------------------------------- #
    def _worker(self) -> None:
        while True:
            job_id = self.queue.get()
            job = self.jobs.get(job_id)
            if job is None:
                continue
            try:
                self._run(job)
            except Exception:  # noqa: BLE001 - keep the worker alive no matter what
                log.exception("job %s crashed", job.id)
                job.status, job.exit_code, job.finished_at = "failed", -1, utcnow()
                job.save()

    def _run(self, job: Job) -> None:
        if job.kind == "provision":
            argv = ["sudo", "-n", str(PROVISION), job.name, job.message]
        else:
            argv = ["sudo", "-n", str(DEPROVISION), job.name]
        job.status, job.started_at = "running", utcnow()
        job.save()
        log.info("job %s: %s %s (from %s)", job.id, job.kind, job.name, job.client_ip)
        with job.log_path.open("ab") as fh:
            proc = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=fh, stderr=subprocess.STDOUT,
                                    cwd=str(REPO_DIR), env={"PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
                                                             "LANG": "C.UTF-8"})
            rc = proc.wait()
        job.exit_code = rc
        job.finished_at = utcnow()
        job.status = "succeeded" if rc == 0 else "failed"
        if rc == 0 and job.kind == "provision":
            m = re.search(r"^RESULT url=(\S+) ip=\S+ vm=\S+ expires=(\S+)$", job.log_text(), re.M)
            if m:
                job.url, job.expires_at = m.group(1), m.group(2)
        job.save()
        log.info("job %s: %s exit %s", job.id, job.status, rc)


# --------------------------------------------------------------------------- #
# HTTP
# --------------------------------------------------------------------------- #
class ApiError(Exception):
    def __init__(self, status: HTTPStatus, message: str):
        super().__init__(message)
        self.status = status
        self.message = message


class Handler(BaseHTTPRequestHandler):
    server_version = "akamai-web/1.0"
    sys_version = ""
    settings: Settings
    runner: JobRunner
    templates: dict[str, str]

    # -- plumbing --------------------------------------------------------- #
    def log_message(self, fmt: str, *args) -> None:  # route to logging, include client ip
        log.info("%s %s", self.client_ip(), fmt % args)

    def client_ip(self) -> str:
        return self.headers.get("X-Real-IP") or self.client_address[0]

    def security_headers(self) -> None:
        self.send_header("Content-Security-Policy",
                         "default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; "
                         "connect-src 'self'; form-action 'self'; frame-ancestors 'none'; base-uri 'none'")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "same-origin")
        self.send_header("Cache-Control", "no-store")

    def send_body(self, status: HTTPStatus, body: bytes, ctype: str, extra: Optional[dict] = None) -> None:
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.security_headers()
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def send_json(self, status: HTTPStatus, payload: dict) -> None:
        self.send_body(status, json.dumps(payload).encode(), "application/json; charset=utf-8")

    def send_html(self, status: HTTPStatus, body: str) -> None:
        self.send_body(status, body.encode(), "text/html; charset=utf-8")

    def render(self, template: str, /, **ctx: str) -> str:
        page = self.templates[template]
        for k, v in ctx.items():
            page = page.replace("{{" + k + "}}", html.escape(v, quote=True))
        return page

    def read_form(self) -> dict[str, str]:
        length = int(self.headers.get("Content-Length") or 0)
        if length > 8192:
            raise ApiError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "request too large")
        raw = self.rfile.read(length)
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype == "application/json":
            try:
                data = json.loads(raw or b"{}")
            except ValueError as exc:
                raise ApiError(HTTPStatus.BAD_REQUEST, "invalid JSON") from exc
            if not isinstance(data, dict):
                raise ApiError(HTTPStatus.BAD_REQUEST, "invalid JSON")
            return {str(k): str(v) for k, v in data.items()}
        return {k: v[0] for k, v in urllib.parse.parse_qs(raw.decode("utf-8", "replace"),
                                                          keep_blank_values=True).items()}

    def wants_json(self) -> bool:
        accept = self.headers.get("Accept", "")
        ctype = self.headers.get("Content-Type", "")
        return "application/json" in accept or "application/json" in ctype

    def check_same_origin(self) -> None:
        """Cheap CSRF defence for a cookie-less app: browsers always send
        Sec-Fetch-Site, and Origin on cross-origin POSTs."""
        sfs = self.headers.get("Sec-Fetch-Site")
        if sfs and sfs not in ("same-origin", "none"):
            raise ApiError(HTTPStatus.FORBIDDEN, "cross-site request refused")
        origin = self.headers.get("Origin")
        if origin:
            host = urllib.parse.urlsplit(origin).hostname or ""
            if host not in (self.settings.site_host, (self.headers.get("Host") or "").split(":")[0]):
                raise ApiError(HTTPStatus.FORBIDDEN, "cross-site request refused")

    # -- routing ---------------------------------------------------------- #
    def do_HEAD(self) -> None:  # noqa: N802
        self.do_GET()

    def do_GET(self) -> None:  # noqa: N802
        try:
            path = urllib.parse.urlsplit(self.path).path
            if path == "/":
                return self.page_index()
            if path == "/healthz":
                return self.send_json(HTTPStatus.OK, {"ok": True, "queue": self.runner.queue_depth()})
            if path == "/api/instances":
                return self.send_json(HTTPStatus.OK, {"instances": list_instances(),
                                                      "capacity": self.settings.pool_size})
            if path == "/api/jobs":
                return self.send_json(HTTPStatus.OK, {"jobs": self.runner.recent()})
            m = re.fullmatch(r"/api/jobs/([a-f0-9]{16})", path)
            if m:
                return self.api_job(m.group(1))
            m = re.fullmatch(r"/jobs/([a-f0-9]{16})", path)
            if m:
                return self.page_job(m.group(1))
            if path.startswith("/static/"):
                return self.static(path[len("/static/"):])
            raise ApiError(HTTPStatus.NOT_FOUND, "not found")
        except ApiError as exc:
            self.error(exc)

    def do_POST(self) -> None:  # noqa: N802
        try:
            path = urllib.parse.urlsplit(self.path).path
            self.check_same_origin()
            if path == "/api/provision":
                return self.api_provision()
            m = re.fullmatch(r"/api/jobs/([a-f0-9]{16})/destroy", path)
            if m:
                return self.api_destroy(m.group(1))
            raise ApiError(HTTPStatus.NOT_FOUND, "not found")
        except ApiError as exc:
            self.error(exc)

    def error(self, exc: ApiError) -> None:
        if self.wants_json() or self.path.startswith("/api/"):
            self.send_json(exc.status, {"error": exc.message})
        else:
            self.send_html(exc.status, self.render("error.html", status=str(exc.status.value),
                                                   message=exc.message))

    # -- pages ------------------------------------------------------------ #
    def page_index(self) -> None:
        s = self.settings
        self.send_html(HTTPStatus.OK, self.render(
            "index.html",
            base_domain=s.base_domain,
            site_host=s.site_host,
            instance_prefix=s.instance_prefix,
            ttl=f"{s.ttl_hours:g}",
            message_max=str(MESSAGE_MAX),
            capacity=str(s.pool_size),
            repo_url=s.repo_url,
        ))

    def page_job(self, job_id: str) -> None:
        job = self.runner.get(job_id)
        if job is None:
            raise ApiError(HTTPStatus.NOT_FOUND, "no such job")
        # The destroy token is only ever shown to the browser that created
        # the job (it lands on this page via the redirect/JSON response).
        token = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get("t", [""])[0]
        self.send_html(HTTPStatus.OK, self.render(
            "job.html",
            job_id=job.id,
            name=job.name,
            fqdn=self.settings.fqdn(job.name),
            kind=job.kind,
            status=job.status,
            destroy_token=token if secrets.compare_digest(token, job.destroy_token) else "",
            log=job.log_text(),
            refresh="5" if job.status in ("queued", "running") else "0",
        ))

    def static(self, rel: str) -> None:
        base = (WEB_DIR / "static").resolve()
        target = (base / rel).resolve()
        if base not in target.parents or not target.is_file():
            raise ApiError(HTTPStatus.NOT_FOUND, "not found")
        ctype = {".css": "text/css", ".js": "application/javascript", ".svg": "image/svg+xml",
                 ".png": "image/png", ".ico": "image/x-icon"}.get(target.suffix, "application/octet-stream")
        self.send_body(HTTPStatus.OK, target.read_bytes(), ctype, {"Cache-Control": "public, max-age=300"})

    # -- API -------------------------------------------------------------- #
    def api_job(self, job_id: str) -> None:
        job = self.runner.get(job_id)
        if job is None:
            raise ApiError(HTTPStatus.NOT_FOUND, "no such job")
        payload = job.public()
        payload["log"] = job.log_text()
        payload["position"] = self.runner.position(job)
        self.send_json(HTTPStatus.OK, payload)

    def api_provision(self) -> None:
        form = self.read_form()
        name = (form.get("name") or "").strip()
        message = (form.get("message") or "").strip()
        s = self.settings
        ip = self.client_ip()

        if not NAME_RE.fullmatch(name):
            raise ApiError(HTTPStatus.BAD_REQUEST, "Subdomain must be 1-32 lower-case letters and digits.")
        if name in s.reserved:
            raise ApiError(HTTPStatus.BAD_REQUEST, f"'{name}' is reserved; pick another name.")
        if not message or len(message) > MESSAGE_MAX or not message.isprintable():
            raise ApiError(HTTPStatus.BAD_REQUEST,
                           f"Message must be 1-{MESSAGE_MAX} printable characters on a single line.")
        if instance_exists(name) or self.runner.active_name(name):
            raise ApiError(HTTPStatus.CONFLICT, f"{s.fqdn(name)} is already taken.")
        if len(list_instances()) >= s.pool_size:
            raise ApiError(HTTPStatus.SERVICE_UNAVAILABLE,
                           "All instance slots are in use right now. Instances expire automatically; try again soon.")
        if self.runner.queue_depth() >= MAX_QUEUE:
            raise ApiError(HTTPStatus.SERVICE_UNAVAILABLE, "Too many requests are queued; try again in a minute.")
        if self.runner.recent_by_ip(ip, timedelta(hours=1)) >= s.rate_limit_per_ip:
            raise ApiError(HTTPStatus.TOO_MANY_REQUESTS,
                           f"Limit of {s.rate_limit_per_ip} instances per hour per client reached.")

        job = self.runner.submit("provision", name, message, ip)
        location = f"/jobs/{job.id}?t={job.destroy_token}"
        if self.wants_json():
            payload = job.public()
            payload["job_url"] = location
            payload["destroy_token"] = job.destroy_token
            return self.send_json(HTTPStatus.ACCEPTED, payload)
        self.send_body(HTTPStatus.SEE_OTHER, b"", "text/plain", {"Location": location})

    def api_destroy(self, job_id: str) -> None:
        form = self.read_form()
        job = self.runner.get(job_id)
        token = form.get("token") or ""
        if job is None or job.kind != "provision" or not secrets.compare_digest(token, job.destroy_token):
            raise ApiError(HTTPStatus.FORBIDDEN, "not allowed")
        if not instance_exists(job.name):
            raise ApiError(HTTPStatus.CONFLICT, "that instance is already gone")
        if self.runner.active_name(job.name):
            raise ApiError(HTTPStatus.CONFLICT, "an operation on that instance is already in progress")
        new = self.runner.submit("deprovision", job.name, "", self.client_ip())
        location = f"/jobs/{new.id}"
        if self.wants_json():
            payload = new.public()
            payload["job_url"] = location
            return self.send_json(HTTPStatus.ACCEPTED, payload)
        self.send_body(HTTPStatus.SEE_OTHER, b"", "text/plain", {"Location": location})


# --------------------------------------------------------------------------- #
def main() -> None:
    logging.basicConfig(level=logging.INFO, stream=sys.stdout,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    settings = Settings.load()

    Handler.settings = settings
    Handler.runner = JobRunner()
    Handler.templates = {f.name: f.read_text(encoding="utf-8") for f in (WEB_DIR / "templates").glob("*.html")}

    bind = "127.0.0.1"
    httpd = ThreadingHTTPServer((bind, settings.listen_port), Handler)
    httpd.daemon_threads = True
    log.info("listening on http://%s:%d for %s (instances under *.%s, ttl %gh, capacity %d)",
             bind, settings.listen_port, settings.site_host, settings.base_domain,
             settings.ttl_hours, settings.pool_size)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
