# mqtt — platform MQTT broker (EMQX HA cluster)

The **single MQTT broker for everything** (jupiter D1 decision, owner signed
off 2026-07-03): Home Assistant's MQTT integration, zeus (during the
transition), and the jupiter cells/services all connect to
**`mqtt.lab.local:1883`** — never a pod/node IP. Vesta's Mosquitto is
decommissioned after the migration completes (cards #110–#113 track the
bridge, HA repoint, zeus flip and decommission).

## Shape

- **EMQX 5.8.x, 3-node cluster** (`emqx/emqx` official multi-arch image,
  arm64). Replicas spread across k3s nodes with podAntiAffinity; sessions,
  retained messages and the auth DB replicate via mnesia, so one node loss
  does not drop the broker. *Fallback (documented in the D1 sub-decision,
  owner can veto in PR review): single-replica Mosquitto + PVC — simpler, but
  a node failure means a visible outage window, which is not the HA the owner
  asked for.*
- **Cluster discovery**: static DNS SRV on the `mqtt-headless` service
  (`publishNotReadyAddresses: true` so the initial cluster can form).
- **Address**: `LoadBalancer` service pinned to a VIP from the Cilium
  `platform` LB-IPAM pool via `lbipam.cilium.io/ips` + `lb-pool: platform`
  label (per-env in `.config/<env>/mqtt.yaml`). The `mqtt.lab.local` A record
  in the zone-in-git (`.config/<env>/coredns-lab.yaml`) points at the same
  VIP — bump the SOA serial whenever it changes.
- **Persistence**: one `local-path` PVC per replica (mnesia needs POSIX
  semantics; the SMB share is unsuitable — same reasoning as InfluxDB).
- **Auth**: anonymous is denied. Username/password authn against EMQX's
  built-in database, seeded once from the `users.csv` bootstrap file in the
  `mqtt-auth` SealedSecret. Per-user **authz (ACLs)** live in mnesia (added via
  the admin REST API) with a git-managed `file` authz source as the DR fallback
  — see "ACL disaster recovery". The dashboard (`admin` user, password from the
  same secret) is **not** exposed outside the cluster — use
  `kubectl -n mqtt port-forward svc/mqtt-headless 18083:18083` or target a pod.
- **Never on the actuation path**: the broker carries telemetry and
  operational nudges only. Battery actuation stays the cell/zeus direct HA
  call on the site LAN; broker downtime must never abort a control cycle.

## Secret (`mqtt-auth`)

Keys: `node-cookie` (Erlang cluster cookie), `dashboard-password`,
`users.csv` (authn bootstrap, header `user_id,password,is_superuser`).
Sealed with kubeseal against the `sealed-secrets` controller in ns `argocd`;
encrypted values live in `.config/<env>/mqtt.yaml`. To (re)seal a value:

```sh
kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd \
  --namespace mqtt --name mqtt-auth --from-file=/dev/stdin <<< '<value>'
```

For `users.csv`, seal the whole file content (including the header line).
Note the bootstrap file only seeds the built-in DB **when the authenticator
is first created**; add/rotate users afterwards via the dashboard or
`emqx ctl`, or wipe the auth mnesia tables before re-bootstrapping.

## Per-client user management (runbook)

Each client authenticates as its own least-privilege user (never `mqtt-admin`).
Provisioned so far (ACLs mirrored in [`files/acl.conf`](files/acl.conf) for DR —
see "ACL disaster recovery" below):

| user            | allow                                                        | then |
| --------------- | ------------------------------------------------------------ | ---- |
| `homeassistant` | `all homeassistant/#` (own tree — see note below), `subscribe ceres/#` (#293), `publish ceres/+/actuator/+/power_w` (the plug's watts, ceres ADR-0005), `publish ceres/+/actuator/+/set` (#295, v2), `publish ceres/+/sys/alerts/ack`, `ceres/+/sys/advice/ack`, `ceres/sys/alerts/ack` (#302: the ack HA publishes after notifying, echoing the document's traceparent; Robigus opens the span) | `deny all #` |
| `zeus-mqtt`     | `all homeassistant/#`, `all zeus/#`                          | `deny all #` |
| `cell-tervuren` | `all jupiter/tervuren/#`, **`subscribe zeus/tervuren/commander`** | `deny all #` |
| `reporting`     | **`subscribe jupiter/+/plan`, `subscribe jupiter/+/heartbeat`** (no publish) | `deny all #` |
| ~~`pomona`~~, ~~`pomona-demeter`~~, ~~`pomona-ingest`~~ | the v1 world (firmware 1.x, the 0.5.1 controller, the v1 Telegraf bridge) — retired with ceres #295 step 5; delete them on the broker | — |
| `unit-pomona-0001` | v2 node (pomona fw ≥ 2.3.0, #295): publish `ceres/pomona-0001/{tele/#, actuator/+/state, actuator/+/reason, dose/result, sys/status, sys/meta, sys/health, sys/ota/result, sys/diag/#}`; subscribe `{actuator/+/set, dose/request, desired, sys/ota/url, sys/diag/+/get}` | `deny all #` |
| `vertumnus-pomona-0001` | v2 Vertumnus (#295): subscribe `ceres/pomona-0001/#`, `ceres/sys/mode`; publish `ceres/pomona-0001/{actuator/+/set, dose/request, sys/role, sys/decision, sys/ledger, sys/ota/url}`, `ceres/sys/status/vertumnus-pomona-0001` (the v1 transition grants went with step 5) | `deny all #` |
| `telegraf-ceres` | the v2 archive (#295): `subscribe ceres/#` only | `deny all #` |
| `annona`, `robigus` | ceres services (#292/#293), see acl.conf | `deny all #` |
| `janus`         | the ceres operator console (ADR-0015): `subscribe ceres/#`, publish **only** `ceres/sys/status/janus` — a hand dose goes to the unit's Vertumnus over HTTP, never on the wire, so the console has no publish on any unit's tree | `deny all #` |
| `mqtt-admin`    | superuser (bypasses authz — no ACL rules)                    | — |

`homeassistant` is scoped to **its own tree plus the ceres relay grants**
(card #188 — least-privilege hardening; it reads `ceres/#` and writes the pump
plug's watts, a human actuator override and the notifier acks — the v1
`pomona/#` grants of #277 / #278 went with ceres #295 step 5). It previously also held `all zeus/#`, which was
over-provisioning: HA never needs the `zeus/` tree because `zeus-mqtt` publishes
HA discovery + state under `homeassistant/#` (that is how HA consumes zeus data).
After the change, **publish under the `zeus/` tree — including the commander
interlock topic — belongs to `zeus-mqtt` alone** (`cell-tervuren` is
subscribe-only on that topic; `reporting` has no zeus grant). The larger 8883/TLS
listener + bcrypt-hashed bootstrap passwords remain a separate follow-up (not
addressed here). **The runtime step is owner-gated** — the live rule lives in
mnesia; update the `homeassistant` user's live rules via the admin REST API to
match this DR mirror so the two do not drift (see "ACL disaster recovery" and the
per-client runbook above).

`cell-tervuren`'s **`subscribe zeus/tervuren/commander`** grant is load-bearing:
the single-controller interlock reads zeus's commander heartbeat from that topic
(added live in #139, the missing rule that blocked the #153 go-live). `bridge-vesta`
was removed after the migration.

`reporting` (gitops card #161-F) is the central fleet-reporting/savings service.
It is **subscribe-only across all sites** — it consumes every lar's retained
`jupiter/<site>/plan` + `jupiter/<site>/heartbeat` to re-expose `jupiter_reporting_*`
gauges, and PUBLISHES nothing (a pure consumer, never on any actuation path). The
`+` wildcard covers all present + future sites without an ACL change. Rules for the
REST-API call: `[{"topic":"jupiter/+/plan","permission":"allow","action":"subscribe"},{"topic":"jupiter/+/heartbeat","permission":"allow","action":"subscribe"},{"topic":"#","permission":"deny","action":"all"}]`.
Seal the creds for ns `jupiter-central` / secret `jupiter-reporting-secrets`.

Users and their ACLs live in EMQX's **replicated mnesia built-in DB** (survive
restarts / single-node loss) — the bootstrap `users.csv` only seeds authn on
first authenticator creation, and ACLs (authz) have **no** bootstrap-file
mechanism in EMQX 5.8, so runtime users/ACLs are added via the **admin REST
API**, not gitops. A full 3-node rebuild (fresh mnesia) would lose them; the ACL
half of that gap is now closed declaratively (see "ACL disaster recovery"). The
authn (password) half is documented-deferred there too.

**`emqx ctl` does NOT manage authn users** (only `admins` = dashboard logins).
Use the REST API on the dashboard listener (18083), authenticating as the
dashboard admin (`admin` / `dashboard-password` from the `mqtt-auth` secret).
All of this runs in-cluster (18083 is CNP-internal): `kubectl exec -n mqtt
mqtt-0 -- curl ...` (the emqx image ships `curl`).

1. **Login** → bearer token: `POST /api/v5/login {"username":"admin","password":"<dashboard-password>"}`.
2. **Create user**: `POST /api/v5/authentication/password_based:built_in_database/users {"user_id":"<name>","password":"<pw>","is_superuser":false}` (200/201). Reset a password with `PUT .../users/<name> {"password":"<pw>"}`.
3. **Scoped ACL**: `POST /api/v5/authorization/sources/built_in_database/rules/users [{"username":"<name>","rules":[{"topic":"<prefix>/#","permission":"allow","action":"all"},{"topic":"#","permission":"deny","action":"all"}]}]` (204). (Default `no_match=allow`, so the explicit `deny #` is what makes the ACL meaningful; deny is a silent drop, not a disconnect.) **Then mirror the same rule into [`files/acl.conf`](files/acl.conf)** so the DR fallback stays faithful (see "ACL disaster recovery"). Inspect a user's live rules with `GET /api/v5/authorization/sources/built_in_database/rules/users/<name>`.
4. **Seal the creds** for the consumer's namespace/secret and paste into that
   landing zone's `.config/<env>/<app>.yaml` (blobs are namespace-scoped):
   `printf '%s' "$PW" | kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd --namespace <ns> --name <secret>`.
5. **Delete** (cleanup): `DELETE .../users/<name>` + `DELETE .../rules/users/<name>` (204 each). A lingering disconnected session is harmless (can't re-auth) and expires.

**Two gotchas that cost real debugging (2026-07-05):** (a) the hyphenated
`dashboard-password` secret key needs `go-template '{{index .data "dashboard-password" | base64decode}}'`, not `jsonpath .data.dashboard-password` (which silently returns garbage). (b) Do NOT pipe the admin password *and* a new
password on one stdin to two `read`s — the admin password carries a newline and
misframes the second read (a wrong password gets set). Pass the admin password
via stdin (single `read`) and the new password via a `kubectl cp`'d file.

## Republish bridge `pomona/# <-> ceres/pomona-0001/#` (ceres card #295, ADR-0008)

The tower's firmware speaks the v1 tree; everything Ceres (Vertumnus on
`contract: v2`, Robigus, the Telegraf archive) and Home Assistant 2.0 read is
the v2 tree `ceres/pomona-0001/…`. `values.yaml` `rules.list` declares one
rule-engine **republish** rule per topic mapping, both directions, rendered
onto the StatefulSet as `EMQX_RULE_ENGINE__RULES__<id>__…` env vars — config,
not REST: git is the source of truth and a fresh cluster gets the bridge back
with the ACL. Env-declared rules are read-only in the dashboard.

| v1 (firmware) | v2 | retained |
|---|---|---|
| `pomona/<water\|air>/<metric>`, `unit/rssi_dbm`, `unit/uptime_s` | `tele/<zone>/<metric>`, `tele/node/<metric>` | no |
| `unit/status`, `unit/sensors`, `unit/fw_version` | `sys/status`, `sys/health`, `sys/meta` (synthesised JSON, `contract: 1`) | yes |
| `pump/request`, `pump/reason`, `pump/power` (HA), `light/request` | `actuator/pump/state`, `actuator/pump/reason`, `actuator/pump/power_w`, `actuator/light/state` | yes |
| `dose/result` (v1 event line), `unit/i2c_scan`, `unit/ota_result` | `dose/result`, `sys/diag/i2c_scan`, `sys/ota/result` | yes |
| `pump/override` ← | ← `actuator/pump/set` | no |
| `unit/ota_url`, `unit/i2c_scan/get` ← | ← `sys/ota/url`, `sys/diag/i2c_scan/get` | no |
| `control/mode` ← | ← `desired` (`payload.stage`, the registry's document) | yes |

No loop is possible: no v1→v2 rule reads a topic a v2→v1 rule writes. The
Vertumnus's own documents are not bridged — a v2 Vertumnus publishes `sys/*` itself.
`dose/request` (ml, JSON) is NOT bridged either: while the node is v1 the
Vertumnus converts ml to the bench command on `pomona/dose/test` with its own
calibration (`legacy_base_topic`, ceres Vertumnus ≥ 0.9.0).

A JSON payload template must be HOCON-quoted (outer `"`, inner `\"`) — the
env parser otherwise reads it as an object and the node refuses to boot.
Validated 2026-09-12 on a local `emqx/emqx:5.8.9` (all 16 rules load; every
mapping and retain flag checked by a script). Changing `rules` rolls the
StatefulSet (one pod at a time; clients reconnect to the VIP).

**Step 5 of the transition** — due since firmware 2.3.0 went onto the tower
(2026-09-15): set `rules.enabled: false` (chart 0.4.0; rolls the StatefulSet once —
mind ceres #314), clear the old retained `pomona/#` topics (admin API
`DELETE /mqtt/retainer/message/<topic>`, or an empty retained publish), PUT the
trimmed ACLs of `files/acl.conf` for `vertumnus-pomona-0001`, `robigus` and
`homeassistant`, and delete the users `pomona`, `pomona-demeter`, `pomona-ingest`.
The mapping table above then is history; `values.yaml` keeps the rule list as
the record `tests/bridge_test.py` checks.

## ACL disaster recovery (card #156)

The per-user ACLs live only in replicated mnesia (created via the admin REST
API). They survive pod restart and single-node loss, but a **full 3-node
cluster rebuild** (empty mnesia) would lose them. To close that gap, the ACLs
are also kept as a **git-managed EMQX `file` authz source**:

- **Source of truth in git**: [`files/acl.conf`](files/acl.conf) — Erlang-tuple
  ACL rules mirroring the mnesia rules above, plus EMQX's stock system rules
  and a `{deny, all}.` least-privilege fallback.
- **Delivery**: rendered into the `mqtt-acl` ConfigMap
  ([`templates/acl-configmap.yaml`](templates/acl-configmap.yaml)) and
  `subPath`-mounted **read-only over `${EMQX_ETC_DIR}/acl.conf`** in the
  StatefulSet — exactly where the live `file` authz source already points. A
  `checksum/acl` pod annotation rolls the StatefulSet when the file changes
  (subPath ConfigMap mounts do not hot-reload). Toggle with `acl.enabled` in
  `values.yaml`.

**Why this is non-disruptive on the running broker** (verified against the live
cluster, 2026-07-06): the authorization chain is, in order, `built_in_database`
(mnesia) **then** `file` (`${EMQX_ETC_DIR}/acl.conf`), with
`authorization.no_match = allow`. EMQX walks sources top-to-bottom and stops at
the first source that yields a match. Every live user's mnesia ruleset ends in
an explicit `deny all #` catch-all, so the `built_in_database` source is
**always terminal** for every connected client — the `file` source is never
consulted for them. Replacing the stock `acl.conf` content therefore cannot
change any live client's authorization outcome. On a **fresh** cluster mnesia is
empty, `built_in_database` matches nothing, and the file rules take effect,
restoring the same least-privilege grants. `mqtt-admin` is a built-in-DB
superuser and bypasses authz entirely.

This does **not** add or reorder authz sources (which is fragile via env vars in
EMQX 5.8.x — `EMQX_AUTHORIZATION__SOURCES__*` fails with `missing_type_field`,
[emqx#14587](https://github.com/emqx/emqx/issues/14587)); it only rewrites the
file the existing `file` source already reads.

**Keeping it faithful**: whenever you add/change/remove a runtime ACL via the
REST API (runbook step 3), mirror the same rule in `files/acl.conf`. Verify
parity by dumping each user's live rules
(`GET /api/v5/authorization/sources/built_in_database/rules/users/<name>`) and
comparing to the file.

**Authn (passwords) DR — DEFERRED.** This card covers the **authz (ACL)** half
only. Restoring the *users and passwords* on a fresh cluster is handled by the
existing `users.csv` authn bootstrap in the `mqtt-auth` SealedSecret (seeded on
first authenticator creation) — that file must contain every user for DR to be
complete. Reconciling `users.csv` with the four live users (and their bcrypt
hashes / plaintext) requires re-sealing the whole file and is **not** done here
(no plaintext passwords are materialized in this change). Track that as a
follow-up. DR restore order on a fresh cluster: (1) unseal `mqtt-auth` →
`users.csv` seeds the users, (2) this `acl.conf` file source applies their
ACLs; the two halves are independent.

## Monitoring (card #125)

- **Scrape**: EMQX 5.8 serves Prometheus text at
  `GET /api/v5/prometheus/stats` on the dashboard listener (18083). That one
  endpoint is unauthenticated (`EMQX_PROMETHEUS__ENABLE_BASIC_AUTH=false`,
  pinning the EMQX default; the rest of the dashboard API still requires
  login) — acceptable because 18083 is cluster-internal only: the CNP admits
  it from the `cluster` entity (which includes the Prometheus pods in ns
  `observability`) and the LB exposes 1883 only.
- **Targets**: the `mqtt-headless` Service carries a `metrics` port (18083);
  the ServiceMonitor (label `release: kube-prometheus-stack`) selects it via
  `app.kubernetes.io/component: headless` and scrapes **each pod
  individually** every 30s (job label `mqtt-headless`). Per-node stats matter:
  quorum, VM load, and each node's view of the cluster.
- **Alerts** (PrometheusRule `mqtt`, USE method): `EMQXNodeDown` /
  `EMQXQuorumLost` (critical), `EMQXQueueSaturation`, `EMQXAuthFailureSpike`
  (credential canary) and `EMQXClusterPartition` (warning). Thresholds are
  conservative for a quiet broker — revisit with real traffic.
- Gauges are point-in-time per node (no `node` label in the text output; the
  scrape target's `pod` label identifies the node). `emqx_vm_total_memory` is
  the **k3s node's** RAM, not the container limit.

## Post-deploy smoke tests (human-gated, after the release merges)

1. `kubectl -n mqtt get pods` — 3/3 Running on distinct nodes; `kubectl -n
   mqtt exec mqtt-0 -- emqx ctl cluster status` shows 3 running nodes.
2. `dig mqtt.lab.local @192.168.50.180` returns the LB VIP; service has the
   pinned external IP.
3. From a LAN host: `mosquitto_pub -h mqtt.lab.local -u <user> -P <pw> -t
   smoke/test -m hello -q 1` + matching `mosquitto_sub` — and verify an
   anonymous connect is REFUSED (auth works).
4. Retained-message persistence: publish retained, delete pod `mqtt-0`, when
   it rejoins subscribe and confirm the retained message survives.
5. HA: `kubectl -n mqtt delete pod mqtt-1` while a subscriber is connected —
   client reconnects to the VIP and traffic continues.
