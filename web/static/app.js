/* Progressive enhancement for the portal. Both pages work without this
 * file (plain form posts + meta refresh); with it, submissions happen over
 * fetch(), the instance table fills itself in, and the job page streams. */
(function () {
  "use strict";

  const $ = (sel) => document.querySelector(sel);

  function fmtTime(iso) {
    if (!iso) return "";
    const d = new Date(iso);
    return isNaN(d) ? iso : d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
  }

  function relTime(iso) {
    const ms = new Date(iso) - Date.now();
    const min = Math.round(Math.abs(ms) / 60000);
    const txt = min < 60 ? `${min} min` : `${Math.round(min / 60 * 10) / 10} h`;
    return ms < 0 ? `${txt} ago` : `in ${txt}`;
  }

  /* ---------------- index page ---------------- */
  const form = $("#provision-form");
  if (form) {
    const srcLink = $("#source-link");
    if (srcLink && !srcLink.getAttribute("href")) $("#source").remove();

    const err = $("#form-error");
    const btn = $("#submit");
    const nameInput = $("#name");
    nameInput.addEventListener("input", () => {
      // Help the user along: lower-case as they type, strip anything else.
      const clean = nameInput.value.toLowerCase().replace(/[^a-z0-9]/g, "");
      if (clean !== nameInput.value) nameInput.value = clean;
    });

    form.addEventListener("submit", async (ev) => {
      ev.preventDefault();
      err.hidden = true;
      btn.disabled = true;
      try {
        const res = await fetch(form.action, {
          method: "POST",
          headers: { "Content-Type": "application/json", "Accept": "application/json" },
          body: JSON.stringify({ name: nameInput.value, message: $("#message").value }),
        });
        const data = await res.json().catch(() => ({}));
        if (res.status === 403 && !data.error) {
          // Non-JSON 403: the WAF (ModSecurity CRS) in front of the portal
          // rejected the request before it reached us.
          throw new Error("The web application firewall in front of this portal blocked that input. Try different wording.");
        }
        if (!res.ok) throw new Error(data.error || `${res.status} ${res.statusText}`);
        window.location.href = data.job_url;
      } catch (e) {
        err.textContent = e.message;
        err.hidden = false;
        btn.disabled = false;
      }
    });

    async function loadInstances() {
      const tbody = $("#instances tbody");
      try {
        const res = await fetch("/api/instances", { headers: { Accept: "application/json" } });
        const data = await res.json();
        $("#capacity").textContent = `(${data.instances.length} of ${data.capacity} slots in use)`;
        if (!data.instances.length) {
          tbody.innerHTML = '<tr><td colspan="3" class="muted">None right now. Be the first.</td></tr>';
          return;
        }
        tbody.innerHTML = "";
        for (const i of data.instances) {
          const tr = document.createElement("tr");
          const a = document.createElement("a");
          a.href = i.url; a.textContent = i.fqdn; a.target = "_blank"; a.rel = "noopener";
          const td1 = document.createElement("td"); td1.appendChild(a);
          const td2 = document.createElement("td"); td2.textContent = fmtTime(i.created_at);
          const td3 = document.createElement("td"); td3.textContent = `${fmtTime(i.expires_at)} (${relTime(i.expires_at)})`;
          tr.append(td1, td2, td3);
          tbody.appendChild(tr);
        }
      } catch (e) {
        tbody.innerHTML = '<tr><td colspan="3" class="muted">Could not load instances.</td></tr>';
      }
    }
    loadInstances();
    setInterval(loadInstances, 15000);
  }

  /* ---------------- job page ---------------- */
  const jobId = document.body.dataset.jobId;
  if (jobId) {
    const logEl = $("#log");
    const statusEl = $("#status");
    const posEl = $("#position");
    const elapsedEl = $("#elapsed");
    const result = $("#result");
    const destroyForm = $("#destroy-form");
    const token = document.body.dataset.destroyToken;
    let startedAt = null;
    let finished = false;

    function tickElapsed() {
      if (!startedAt || finished) return;
      const s = Math.round((Date.now() - startedAt) / 1000);
      elapsedEl.textContent = `${s}s elapsed`;
    }
    setInterval(tickElapsed, 1000);

    async function poll() {
      try {
        const res = await fetch(`/api/jobs/${jobId}`, { headers: { Accept: "application/json" } });
        if (!res.ok) return;
        const j = await res.json();
        const stickToBottom = logEl.scrollHeight - logEl.scrollTop - logEl.clientHeight < 40;
        logEl.textContent = j.log;
        if (stickToBottom) logEl.scrollTop = logEl.scrollHeight;
        statusEl.textContent = j.status;
        statusEl.className = `status status-${j.status}`;
        posEl.textContent = j.position > 1 ? `#${j.position} in queue` : "";
        if (j.started_at) startedAt = new Date(j.started_at);
        if (j.status === "succeeded" || j.status === "failed") {
          finished = true;
          if (j.started_at && j.finished_at) {
            elapsedEl.textContent = `took ${Math.round((new Date(j.finished_at) - new Date(j.started_at)) / 1000)}s`;
          }
          if (j.status === "succeeded" && j.kind === "provision" && j.url) {
            $("#result-link").href = j.url;
            $("#result-link").textContent = j.url;
            $("#result-expires").textContent = fmtTime(j.expires_at);
            result.hidden = false;
            if (token) destroyForm.hidden = false;
          }
          return;
        }
      } catch (e) { /* transient; try again */ }
      setTimeout(poll, 2000);
    }
    poll();

    if (destroyForm) {
      destroyForm.addEventListener("submit", async (ev) => {
        ev.preventDefault();
        const btn = destroyForm.querySelector("button");
        btn.disabled = true;
        try {
          const res = await fetch(destroyForm.action, {
            method: "POST",
            headers: { "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({ token }),
          });
          const data = await res.json().catch(() => ({}));
          if (!res.ok) throw new Error(data.error || res.statusText);
          window.location.href = data.job_url;
        } catch (e) {
          alert(e.message);
          btn.disabled = false;
        }
      });
    }
  }
})();
