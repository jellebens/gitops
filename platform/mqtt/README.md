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
- **Auth**: anonymous is denied. Username/password auth against EMQX's
  built-in database, seeded once from the `users.csv` bootstrap file in the
  `mqtt-auth` SealedSecret. The dashboard (`admin` user, password from the
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
Provisioned so far: `homeassistant` (allow `homeassistant/#`+`zeus/#`), `zeus-mqtt`
(same), `cell-tervuren` (allow `jupiter/tervuren/#`) — `bridge-vesta` was removed
after the migration. Users live in EMQX's **replicated mnesia built-in DB**
(survive restarts/node loss) — the bootstrap `users.csv` only seeds on first
authenticator creation, so runtime users are added via the **admin REST API**,
not gitops. For disaster-recovery reproducibility they *should* also be added to
the sealed `users.csv`, but that requires re-sealing the whole file.

**`emqx ctl` does NOT manage authn users** (only `admins` = dashboard logins).
Use the REST API on the dashboard listener (18083), authenticating as the
dashboard admin (`admin` / `dashboard-password` from the `mqtt-auth` secret).
All of this runs in-cluster (18083 is CNP-internal): `kubectl exec -n mqtt
mqtt-0 -- curl ...` (the emqx image ships `curl`).

1. **Login** → bearer token: `POST /api/v5/login {"username":"admin","password":"<dashboard-password>"}`.
2. **Create user**: `POST /api/v5/authentication/password_based:built_in_database/users {"user_id":"<name>","password":"<pw>","is_superuser":false}` (200/201). Reset a password with `PUT .../users/<name> {"password":"<pw>"}`.
3. **Scoped ACL**: `POST /api/v5/authorization/sources/built_in_database/rules/users [{"username":"<name>","rules":[{"topic":"<prefix>/#","permission":"allow","action":"all"},{"topic":"#","permission":"deny","action":"all"}]}]` (204). (Default `no_match=allow`, so the explicit `deny #` is what makes the ACL meaningful; deny is a silent drop, not a disconnect.)
4. **Seal the creds** for the consumer's namespace/secret and paste into that
   landing zone's `.config/<env>/<app>.yaml` (blobs are namespace-scoped):
   `printf '%s' "$PW" | kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd --namespace <ns> --name <secret>`.
5. **Delete** (cleanup): `DELETE .../users/<name>` + `DELETE .../rules/users/<name>` (204 each). A lingering disconnected session is harmless (can't re-auth) and expires.

**Two gotchas that cost real debugging (2026-07-05):** (a) the hyphenated
`dashboard-password` secret key needs `go-template '{{index .data "dashboard-password" | base64decode}}'`, not `jsonpath .data.dashboard-password` (which silently returns garbage). (b) Do NOT pipe the admin password *and* a new
password on one stdin to two `read`s — the admin password carries a newline and
misframes the second read (a wrong password gets set). Pass the admin password
via stdin (single `read`) and the new password via a `kubectl cp`'d file.

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
