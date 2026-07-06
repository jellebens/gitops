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
| `homeassistant` | `all homeassistant/#`, `all zeus/#`                          | `deny all #` |
| `zeus-mqtt`     | `all homeassistant/#`, `all zeus/#`                          | `deny all #` |
| `cell-tervuren` | `all jupiter/tervuren/#`, **`subscribe zeus/tervuren/commander`** | `deny all #` |
| `reporting`     | **`subscribe jupiter/+/plan`, `subscribe jupiter/+/heartbeat`** (no publish) | `deny all #` |
| `mqtt-admin`    | superuser (bypasses authz — no ACL rules)                    | — |

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
