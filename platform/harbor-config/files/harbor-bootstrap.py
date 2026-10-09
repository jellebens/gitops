#!/usr/bin/env python3
"""Reconcile Harbor projects, proxy-cache endpoints, robots, retention and GC
against the declared config (card #337). Stdlib only, so it runs on a plain
python image.

Idempotent: every object is read first and only created or updated when it is
missing or differs from the config. It NEVER deletes anything and never
touches an object that is not in the config (e.g. the hand-made projects
`library`, `jupiter`, `ceres`).

Environment:
  CONFIG             path to the JSON config (rendered from values.yaml)
  HARBOR_URL         API base, e.g. http://harbor.harbor.svc
  HARBOR_USER        admin user (default: admin)
  HARBOR_PASSWORD    admin password
  HARBOR_CA          optional CA bundle for an https HARBOR_URL
  DRY_RUN            "true": GETs only, log what would change, mutate nothing
  <robot secretEnv>  the sealed secret each robot gets (see config `robots`)

Exit codes: 0 = converged (or Harbor not reachable yet: nothing to configure,
the next scheduled run retries); 1 = at least one object failed to reconcile.
"""

import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

GIB = 1024 ** 3


class Harbor:
    def __init__(self, url, user, password, cafile=None, dry_run=False):
        self.base = url.rstrip("/")
        self.auth = self._basic(user, password)
        self.dry_run = dry_run
        self.ctx = ssl.create_default_context(cafile=cafile) if cafile else None

    @staticmethod
    def _basic(user, password):
        raw = f"{user}:{password}".encode()
        return "Basic " + base64.b64encode(raw).decode()

    def request(self, method, path, body=None, auth=None, timeout=20):
        """Return (status, parsed body or None, headers). Never raises on HTTP errors."""
        if self.dry_run and method != "GET":
            raise RuntimeError(f"dry-run guard: refusing {method} {path}")
        url = self.base + path
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", auth or self.auth)
        req.add_header("Accept", "application/json")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=timeout, context=self.ctx) as r:
                return r.status, _parse(r.read()), r.headers
        except urllib.error.HTTPError as e:
            return e.code, _parse(e.read()), e.headers

    def get(self, path, **kw):
        return self.request("GET", path, **kw)


def _parse(raw):
    if not raw:
        return None
    try:
        return json.loads(raw)
    except ValueError:
        return raw.decode(errors="replace")


class Reconciler:
    def __init__(self, h, cfg):
        self.h = h
        self.cfg = cfg
        self.failed = False
        self.registry_ids = {}

    # -- helpers -----------------------------------------------------------
    def log(self, msg):
        print(msg, flush=True)

    def fail(self, msg):
        self.log(f"ERROR {msg}")
        self.failed = True

    def change(self, what, method, path, body=None, ok=(200, 201)):
        """Perform (or, in dry-run, only announce) a mutating call."""
        if self.h.dry_run:
            self.log(f"DRY-RUN would {what}: {method} {path}")
            return True, None
        status, resp, headers = self.h.request(method, path, body)
        if status in ok:
            self.log(f"{what}: done ({status})")
            return True, headers
        self.fail(f"{what}: {method} {path} -> {status} {resp}")
        return False, None

    def q(self, s):
        return urllib.parse.quote(s, safe="")

    # -- registries (proxy-cache upstreams) --------------------------------
    def registries(self):
        status, existing, _ = self.h.get("/api/v2.0/registries?page_size=100")
        if status != 200:
            self.fail(f"list registries -> {status} {existing}")
            return
        by_name = {r["name"]: r for r in existing or []}
        for want in self.cfg.get("registries", []):
            name = want["name"]
            have = by_name.get(name)
            if have is None:
                body = {
                    "name": name,
                    "type": want["type"],
                    "url": want["url"],
                    "description": want.get("description", ""),
                    "insecure": False,
                }
                ok, _ = self.change(f"registry {name}: create", "POST", "/api/v2.0/registries", body)
                if ok and not self.h.dry_run:
                    s, again, _ = self.h.get("/api/v2.0/registries?page_size=100")
                    for r in again or []:
                        if r["name"] == name:
                            self.registry_ids[name] = r["id"]
                continue
            self.registry_ids[name] = have["id"]
            if have.get("type") != want["type"]:
                self.fail(f"registry {name}: type is {have.get('type')}, want {want['type']} "
                          "(the type cannot be changed; delete it in the UI to recreate)")
                continue
            if have.get("url") != want["url"] or have.get("description", "") != want.get("description", ""):
                body = {"url": want["url"], "description": want.get("description", "")}
                self.change(f"registry {name}: update url/description", "PUT",
                            f"/api/v2.0/registries/{have['id']}", body)
            else:
                self.log(f"registry {name} ({have['id']}): ok")

    # -- projects ----------------------------------------------------------
    def project(self, want):
        name = want["name"]
        public = "true" if want.get("public") else "false"
        status, have, _ = self.h.get(f"/api/v2.0/projects/{self.q(name)}")
        if status == 404:
            have = None
        elif status != 200:
            self.fail(f"project {name}: get -> {status} {have}")
            return None
        # Scan on push (Trivy): managed only when the project declares autoScan,
        # so projects without the key keep whatever the UI set (#340).
        auto_scan = None
        if want.get("autoScan") is not None:
            auto_scan = "true" if want.get("autoScan") else "false"
        if have is None:
            body = {"project_name": name, "metadata": {"public": public}}
            if auto_scan is not None:
                body["metadata"]["auto_scan"] = auto_scan
            if want.get("storageLimitGi") is not None:
                body["storage_limit"] = int(want["storageLimitGi"] * GIB)
            if want.get("proxyCache"):
                reg = self.registry_ids.get(want["proxyCache"])
                if reg is None:
                    if not self.h.dry_run:
                        self.fail(f"project {name}: registry {want['proxyCache']} has no id, skipped")
                        return None
                    reg = -1
                body["registry_id"] = reg
            ok, _ = self.change(f"project {name}: create", "POST", "/api/v2.0/projects", body)
            if not ok or self.h.dry_run:
                return None
            status, have, _ = self.h.get(f"/api/v2.0/projects/{self.q(name)}")
            if status != 200:
                self.fail(f"project {name}: re-read after create -> {status}")
                return None
            return have

        self.log(f"project {name} ({have['project_id']}): exists")
        meta = have.get("metadata") or {}
        if meta.get("public", "false") != public:
            self.change(f"project {name}: public -> {public}", "PUT",
                        f"/api/v2.0/projects/{self.q(name)}", {"metadata": {"public": public}})
        if auto_scan is not None and meta.get("auto_scan", "false") != auto_scan:
            self.change(f"project {name}: auto_scan -> {auto_scan}", "PUT",
                        f"/api/v2.0/projects/{self.q(name)}", {"metadata": {"auto_scan": auto_scan}})
        if want.get("proxyCache"):
            reg = self.registry_ids.get(want["proxyCache"])
            if have.get("registry_id") != reg:
                self.fail(f"project {name}: proxies registry id {have.get('registry_id')}, want "
                          f"{reg} ({want['proxyCache']}); Harbor cannot re-point a proxy-cache "
                          "project, recreate it by hand")
        elif have.get("registry_id"):
            self.fail(f"project {name}: is a proxy cache but is declared as a normal project")
        self.quota(have, want)
        return have

    def quota(self, have, want):
        if want.get("storageLimitGi") is None:
            return
        name, pid = have["name"], have["project_id"]
        target = int(want["storageLimitGi"] * GIB)
        status, quotas, _ = self.h.get(f"/api/v2.0/quotas?reference=project&reference_id={pid}")
        if status != 200 or not quotas:
            self.fail(f"project {name}: quota lookup -> {status} {quotas}")
            return
        qid, hard = quotas[0]["id"], quotas[0].get("hard", {}).get("storage")
        if hard == target:
            self.log(f"project {name}: quota {want['storageLimitGi']}Gi ok")
            return
        self.change(f"project {name}: quota {hard} -> {target} bytes", "PUT",
                    f"/api/v2.0/quotas/{qid}", {"hard": {"storage": target}})

    # -- retention ---------------------------------------------------------
    @staticmethod
    def retention_rules(rules):
        out = []
        for r in rules:
            template = r["template"]
            params = {} if template == "always" else {template: r["value"]}
            out.append({
                "disabled": False,
                "action": "retain",
                "template": template,
                "params": params,
                "tag_selectors": [{
                    "kind": "doublestar",
                    "decoration": "matches",
                    "pattern": r.get("tags", "**"),
                    "extras": json.dumps({"untagged": bool(r.get("untagged", False))}),
                }],
                "scope_selectors": {"repository": [{
                    "kind": "doublestar",
                    "decoration": "repoMatches",
                    "pattern": r.get("repositories", "**"),
                }]},
            })
        return out

    @staticmethod
    def rule_key(rule):
        tag = (rule.get("tag_selectors") or [{}])[0]
        repo = ((rule.get("scope_selectors") or {}).get("repository") or [{}])[0]
        try:
            untagged = bool(json.loads(tag.get("extras") or "{}").get("untagged", False))
        except ValueError:
            untagged = False
        params = {k: int(v) for k, v in (rule.get("params") or {}).items()}
        return (rule.get("action"), rule.get("template"), json.dumps(params, sort_keys=True),
                tag.get("decoration"), tag.get("pattern"), untagged,
                repo.get("decoration"), repo.get("pattern"), bool(rule.get("disabled")))

    def retention(self, have, want):
        ret = want.get("retention")
        if not ret or have is None:
            return
        name, pid = have["name"], have["project_id"]
        policy = {
            "algorithm": "or",
            "rules": self.retention_rules(ret["rules"]),
            "trigger": {"kind": "Schedule", "settings": {"cron": ret["cron"]}},
            "scope": {"level": "project", "ref": pid},
        }
        rid = (have.get("metadata") or {}).get("retention_id")
        if not rid:
            self.change(f"project {name}: create retention policy", "POST",
                        "/api/v2.0/retentions", policy)
            return
        status, cur, _ = self.h.get(f"/api/v2.0/retentions/{rid}")
        if status != 200:
            self.fail(f"project {name}: get retention {rid} -> {status} {cur}")
            return
        same_rules = sorted(map(self.rule_key, cur.get("rules") or [])) == \
            sorted(map(self.rule_key, policy["rules"]))
        cur_cron = ((cur.get("trigger") or {}).get("settings") or {}).get("cron")
        if same_rules and cur_cron == ret["cron"] and cur.get("algorithm") == "or":
            self.log(f"project {name}: retention {rid} ok")
            return
        policy["id"] = int(rid)
        self.change(f"project {name}: update retention policy {rid}", "PUT",
                    f"/api/v2.0/retentions/{rid}", policy)

    # -- robots ------------------------------------------------------------
    def robot_login_ok(self, full_name, secret):
        """True if Harbor accepts the robot's credentials.

        GET /v2/ with basic auth: 200 = valid, 401 = wrong. (The API endpoints and
        /service/token silently fall back to anonymous on bad credentials, so
        they cannot tell the difference; checked against Harbor 2026-10-08.)
        """
        status, _, _ = self.h.get("/v2/", auth=Harbor._basic(full_name, secret))
        if status not in (200, 401):
            self.log(f"WARN robot {full_name}: /v2/ login check returned {status}")
        return status == 200

    def find_project_robot(self, project, short):
        """(lookup_ok, robot or None) for robot$<project>+<short>.

        Harbor's GET /robots only returns project robots when queried with
        Level=project and the project's id; a plain list returns system robots only.
        """
        status, proj, _ = self.h.get(f"/api/v2.0/projects/{self.q(project)}")
        if status == 404 and self.h.dry_run:
            return True, None          # project would be created first
        if status != 200:
            self.fail(f"robot {project}+{short}: get project -> {status} {proj}")
            return False, None
        query = self.q(f"Level=project,ProjectID={proj['project_id']}")
        status, robots, _ = self.h.get(f"/api/v2.0/robots?page_size=100&q={query}")
        if status != 200:
            self.fail(f"robot {project}+{short}: list robots -> {status} {robots}")
            return False, None
        full = f"robot${project}+{short}"
        return True, next((r for r in robots or [] if r.get("name") == full), None)

    def robots(self):
        wanted = self.cfg.get("robots", [])
        if not wanted:
            return
        for want in wanted:
            project, short = want["project"], want["name"]
            full = f"robot${project}+{short}"
            secret = os.environ.get(want["secretEnv"], "")
            if not secret:
                self.fail(f"robot {full}: env {want['secretEnv']} is empty (SealedSecret not unsealed?)")
                continue
            access = sorted({(a["resource"], a["action"]) for a in want["access"]})
            perms = [{"kind": "project", "namespace": project,
                      "access": [{"resource": r, "action": a, "effect": "allow"} for r, a in access]}]
            found, have = self.find_project_robot(project, short)
            if not found:
                continue
            if have is None:
                body = {"name": short, "description": want.get("description", ""), "level": "project",
                        "duration": -1, "disable": False, "secret": secret, "permissions": perms}
                ok, _ = self.change(f"robot {full}: create", "POST", "/api/v2.0/robots", body)
                if not ok or self.h.dry_run:
                    continue
                found, have = self.find_project_robot(project, short)
                if not found or have is None:
                    self.fail(f"robot {full}: not found after create")
                    continue
            else:
                self.log(f"robot {have['name']} ({have['id']}): exists")
                cur = sorted({(a.get("resource"), a.get("action"))
                              for p in have.get("permissions") or [] if p.get("namespace") == project
                              for a in p.get("access") or []})
                if cur != access or have.get("disable") or want.get("description", "") != have.get("description", ""):
                    body = dict(have)
                    body.update({"permissions": perms, "disable": False,
                                 "description": want.get("description", "")})
                    self.change(f"robot {full}: update permissions/description", "PUT",
                                f"/api/v2.0/robots/{have['id']}", body)
            # The secret: Harbor stores only a hash, so test it by logging in and set it
            # (PATCH = "refresh secret" with a given value) only when the login fails.
            if self.robot_login_ok(have["name"], secret):
                self.log(f"robot {have['name']}: sealed secret matches")
            else:
                self.change(f"robot {have['name']}: set secret from SealedSecret", "PATCH",
                            f"/api/v2.0/robots/{have['id']}", {"secret": secret})

    # -- garbage collection ------------------------------------------------
    def gc(self):
        want = self.cfg.get("gc")
        if not want:
            return
        body = {"schedule": {"type": "Custom", "cron": want["cron"]},
                "parameters": {"delete_untagged": bool(want.get("deleteUntagged", True)),
                               "workers": int(want.get("workers", 1))}}
        status, cur, _ = self.h.get("/api/v2.0/system/gc/schedule")
        if status != 200:
            self.fail(f"gc schedule get -> {status} {cur}")
            return
        sched = (cur or {}).get("schedule") if isinstance(cur, dict) else None
        if not sched or sched.get("type") in (None, "", "None"):
            self.change("gc schedule: create", "POST", "/api/v2.0/system/gc/schedule", body)
            return
        # GET returns the parameters as a JSON string in job_parameters, not as
        # the `parameters` object that POST/PUT take.
        params = cur.get("parameters")
        if not isinstance(params, dict):
            try:
                params = json.loads(cur.get("job_parameters") or "{}")
            except ValueError:
                params = {}
        if (sched.get("type") == "Custom" and sched.get("cron") == want["cron"]
                and bool(params.get("delete_untagged")) == body["parameters"]["delete_untagged"]
                and int(params.get("workers", 1)) == body["parameters"]["workers"]):
            self.log(f"gc schedule {want['cron']}: ok")
            return
        self.change("gc schedule: update", "PUT", "/api/v2.0/system/gc/schedule", body)

    def run(self):
        self.registries()
        for want in self.cfg.get("projects", []):
            have = self.project(want)
            if have is not None:
                self.retention(have, want)
        self.robots()
        self.gc()
        return 1 if self.failed else 0


def wait_ready(h, attempts, delay):
    for i in range(1, attempts + 1):
        try:
            status, body, _ = h.get("/api/v2.0/ping", timeout=10)
            if status == 200:
                return True
            print(f"harbor not ready ({status}), attempt {i}/{attempts}", flush=True)
        except (urllib.error.URLError, OSError) as e:
            print(f"harbor unreachable ({e}), attempt {i}/{attempts}", flush=True)
        if i < attempts:
            time.sleep(min(delay * i, 60))
    return False


def main():
    with open(os.environ.get("CONFIG", "/config/config.json"), encoding="utf-8") as f:
        cfg = json.load(f)
    dry = os.environ.get("DRY_RUN", "false").lower() == "true"
    h = Harbor(os.environ["HARBOR_URL"], os.environ.get("HARBOR_USER", "admin"),
               os.environ["HARBOR_PASSWORD"], os.environ.get("HARBOR_CA") or None, dry)
    print(f"harbor-bootstrap against {h.base} (dry_run={dry})", flush=True)

    if not wait_ready(h, int(os.environ.get("READY_ATTEMPTS", "8")),
                      int(os.environ.get("READY_DELAY", "10"))):
        # On a fresh cluster this chart (wave 17) exists before Harbor (wave 18).
        # Nothing to configure yet, and a failing Job here would only add noise;
        # the next scheduled run picks it up.
        print("harbor not reachable: skipping this run, the next one retries", flush=True)
        return 0

    status, me, _ = h.get("/api/v2.0/users/current")
    if status != 200 or not (me or {}).get("sysadmin_flag"):
        print(f"ERROR admin login failed ({status}). The password in the secret no longer "
              "matches Harbor's admin password (changed in the UI?). See the README.", flush=True)
        return 1
    return Reconciler(h, cfg).run()


if __name__ == "__main__":
    sys.exit(main())
