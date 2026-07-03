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
