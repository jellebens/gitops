# Transitional vesta ↔ cluster MQTT bridge (jupiter P1, card #110)

**TRANSITIONAL** — this bridge exists only for the broker migration
(architecture.md "Migration path: vesta Mosquitto → cluster broker", steps
2–5). It is removed again by card #113 when vesta's Mosquitto is
decommissioned. It replicates retained HA discovery/state onto the cluster
broker **before** any client migrates, so #111 (HA repoint) and #112 (zeus
flip) find identical state on `mqtt.lab.local`.

Vesta's filesystem is **not** gitops-managed; this doc is the source of truth
for what is placed there and how to remove it. Applying it **restarts vesta's
Mosquitto broker** (Home Assistant MQTT devices and zeus reporting ride on
it), so the apply is **owner-executed and human-gated** — nothing in this doc
happens automatically on merge.

## How Mosquitto runs on vesta (investigated 2026-07-04)

- vesta (`vesta.lab.local` = 192.168.50.18, A record in the lab.local zone) runs **Home Assistant OS** — the
  Supervisor observer answers on `http://vesta.lab.local:4357` (verified). SSH
  key auth is not set up for automation (probe: publickey/password denied),
  so everything below is owner-run.
- Mosquitto is therefore the official **Mosquitto broker add-on**
  (`core_mosquitto`) managed by the Supervisor. Anonymous is rejected;
  HA and zeus authenticate with per-client users (zeus's `MQTT_USER`/
  `MQTT_PASS` are sealed in `landingzones/zeus`).
- The add-on supports drop-in config via its `customize` option: with
  `customize: {active: true, folder: mosquitto}` it includes every `*.conf`
  under **`/share/mosquitto/`**. That is where the bridge config goes — no
  add-on rebuild, no HA config change.

## Remote end: cluster broker

- **EMQX 5.8.9**, 3-node HA cluster, `platform/mqtt` (deployed by #109).
- Address **`mqtt.lab.local:1883`** (Cilium LB VIP `192.168.50.181`, A record
  in `.config/lab/coredns-lab.yaml`). Plain 1883 **by choice**: traffic stays
  on the LAN, matches the broker's only MQTT listener (no TLS configured) and
  every other client's transport; TLS is out of scope for a transitional
  bridge.
- Anonymous is **denied**; the bridge gets a dedicated least-privilege user
  `bridge-vesta` (created in the runbook below via the procedure in
  `platform/mqtt/README.md` — plaintext never in git or on the card).

## Topics bridged (and why)

| topic line | why |
|---|---|
| `topic homeassistant/# both 1` | all HA MQTT-discovery config topics (retained — this is the state #111 depends on) plus HA's birth/LWT `homeassistant/status` |
| `topic zeus/# both 1` | zeus reporter state/attributes: `zeus/<key>/state`, `zeus/schedule/attributes` (`base_topic: zeus`, see `landingzones/zeus/values.yaml`) |
| `topic anker/# both 1` | the Anker BLE→MQTT prototype (`anker/767/state`, home-assitant repo `anker_ble.py`) |

Deliberately **not** bridged: Z-Wave rides `zwave_js` (WebSocket, not MQTT);
ESPHome (`anker.yaml`) uses the native API; there is no zigbee2mqtt add-on in
evidence. `$SYS/#` is never bridged. If the owner knows of another MQTT topic
prefix in live use, add one more `topic <prefix>/# both 1` line — same
pattern, same loop argument.

`both` + QoS 1: replication must be reliable across bridge restarts
(retained discovery messages are the migration payload). Messages published
at QoS 0 (zeus publishes QoS 0) still transfer effectively at-most-once —
fine, they are refreshed every cycle.

## Bridge config — `/share/mosquitto/bridge-jupiter.conf`

```conf
# Transitional vesta<->cluster bridge (jupiter P1 card #110; removed by #113).
# Docs: gitops docs/jupiter-bridge-vesta.md
connection jupiter-bridge
address mqtt.lab.local:1883

# Scope: exactly the topics in live use (see doc). Both directions, QoS 1.
topic homeassistant/# both 1
topic zeus/# both 1
topic anker/# both 1

# Dedicated least-privilege user on the EMQX side (platform/mqtt/README.md).
# Owner substitutes the real password when placing this file on vesta;
# the file lives ONLY on vesta's /share, never in git.
remote_clientid bridge-vesta
remote_username bridge-vesta
remote_password __BRIDGE_PASSWORD__

# Loop safety + reliability (see "Why no loop can form" in the doc).
bridge_protocol_version mqttv311
try_private true
cleansession false
restart_timeout 5 30
keepalive_interval 60
# Bridge up/down state stays a LOCAL $SYS notification; the scoped remote
# user may not (and need not) publish $SYS on the cluster broker.
notifications true
notifications_local_only true
```

If `mqtt.lab.local` does not resolve from the add-on container (HAOS DNS not
pointing at a `lab.local`-aware resolver — pre-checked in runbook step 3),
fall back to `address 192.168.50.181:1883` with a comment; the VIP is pinned
in `.config/lab/mqtt.yaml` so it is stable for the life of the bridge.

## Why no message loop can form

1. **Single link.** This bridge is the only connection between the two
   brokers. EMQX has no bridge/rule/data-integration configured back to
   vesta (`platform/mqtt` deploys a plain broker), so the only possible cycle
   is vesta → EMQX → the same bridge connection → vesta.
2. **Mosquitto never re-forwards a message back out the bridge it arrived
   on.** Bridge-received messages are tracked per connection; a message that
   came in over `jupiter-bridge` is delivered locally but is not sent out
   over `jupiter-bridge` again. A cycle through one bridge therefore cannot
   self-sustain, regardless of what the remote does.
3. **`try_private true`** (explicit; also the Mosquitto default) sets the
   bridge protocol bit on CONNECT, asking the remote not to echo the
   bridge's own publishes back to its subscriptions. EMQX accepts
   bridge-flagged connections.
4. **Bounded worst case.** Even if the remote ignored the bridge bit
   entirely, an echoed message makes exactly one extra hop (EMQX → vesta) and
   then dies at (2): a per-message duplicate, not amplification, and retained
   duplicates are idempotent (same payload re-set). Verify step 10 confirms
   flat message rates.
5. **Retention is not a loop vector.** A retained message is stored, not
   re-published; the bridge forwards it once per (re)subscription, and
   `cleansession false` keeps the remote session so reconnects do not replay
   the full retained set as a storm.

## Owner apply runbook (human-gated — restarts vesta's Mosquitto)

Prereqs: kubectl access to the cluster; SSH or Samba/File-editor access to
vesta's `/share`; a LAN host with `mosquitto_pub`/`mosquitto_sub`; the owner's
own vesta-broker credentials (any existing HA mosquitto user).

### A. Mint the `bridge-vesta` user on EMQX (per platform/mqtt/README.md: post-bootstrap users are managed via the API/dashboard, not the sealed users.csv)

1. Port-forward the dashboard API and fetch the admin password:

   ```sh
   kubectl -n mqtt port-forward svc/mqtt-headless 18083:18083 &
   ADMIN_PW=$(kubectl -n mqtt get secret mqtt-auth -o jsonpath='{.data.dashboard-password}' | base64 -d)
   TOKEN=$(curl -s -X POST http://127.0.0.1:18083/api/v5/login \
     -H 'Content-Type: application/json' \
     -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PW\"}" | jq -r .token)
   ```

2. Generate a password (keep it out of git/the card — it goes only into the
   conf file on vesta and, if you keep a copy, your password manager) and
   create the user in the built-in auth database:

   ```sh
   BRIDGE_PW=$(openssl rand -base64 24)
   curl -s -X POST 'http://127.0.0.1:18083/api/v5/authentication/password_based%3Abuilt_in_database/users' \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d "{\"user_id\":\"bridge-vesta\",\"password\":\"$BRIDGE_PW\",\"is_superuser\":false}"
   echo "bridge password: $BRIDGE_PW"
   ```

   The user lives in the replicated built-in DB (survives node loss). Note:
   if the auth DB is ever wiped and re-bootstrapped from the sealed
   `users.csv`, re-create `bridge-vesta` (or add it to the sealed csv then).

3. **ACL — scope the user to exactly the bridged topics** (recommended).
   The broker currently has no per-user authorization source, so first add
   the built-in-database authorization source, then per-user rules ending in
   a deny-all **for this user only** (other clients are untouched: default
   `no_match` stays `allow`):

   ```sh
   curl -s -X POST 'http://127.0.0.1:18083/api/v5/authorization/sources' \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '{"type":"built_in_database","enable":true}'
   curl -s -X POST 'http://127.0.0.1:18083/api/v5/authorization/sources/built_in_database/rules/users' \
     -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
     -d '[{"username":"bridge-vesta","rules":[
       {"permission":"allow","action":"all","topic":"homeassistant/#"},
       {"permission":"allow","action":"all","topic":"zeus/#"},
       {"permission":"allow","action":"all","topic":"anker/#"},
       {"permission":"deny","action":"all","topic":"#"}]}]'
   ```

   (Gitops-managing the authorization config is broader hardening — flag it
   for the #113-era cleanup, don't block the bridge on it.)

4. Smoke-test the new user from a LAN host, including that the ACL bites:

   ```sh
   mosquitto_pub -h mqtt.lab.local -u bridge-vesta -P "$BRIDGE_PW" -t zeus/bridge_test -m hello -q 1   # must succeed
   mosquitto_pub -h mqtt.lab.local -u bridge-vesta -P "$BRIDGE_PW" -t forbidden/test -m x -q 1          # must be denied (rc/no delivery)
   ```

### B. Baseline (read-only, before touching anything)

5. Count retained discovery state on **vesta** (owner credentials):

   ```sh
   mosquitto_sub -h vesta.lab.local -u <user> -P <pw> -t 'homeassistant/#' -v -W 10 | wc -l
   mosquitto_sub -h vesta.lab.local -u <user> -P <pw> -t 'zeus/#' -v -W 10 | wc -l
   ```

   Note both numbers. (This baseline could not be taken by the agent: no SSH
   key on vesta and the MQTT credentials exist only sealed.)

6. Confirm the cluster broker currently has ~none of it:

   ```sh
   mosquitto_sub -h mqtt.lab.local -u bridge-vesta -P "$BRIDGE_PW" -t 'homeassistant/#' -v -W 10 | wc -l
   ```

### C. Place the bridge config and restart the add-on

7. Copy the conf block above to **`/share/mosquitto/bridge-jupiter.conf`** on
   vesta (Samba share, SSH add-on, or File editor), replacing
   `__BRIDGE_PASSWORD__` with the step-2 password. Pre-check DNS from vesta
   (e.g. SSH add-on: `nslookup mqtt.lab.local`); if it does not resolve, use
   `address 192.168.50.181:1883` instead (see note above).

8. In the Mosquitto add-on configuration (Settings → Add-ons → Mosquitto
   broker → Configuration, YAML view) enable the drop-in folder, then
   **restart the add-on**:

   ```yaml
   customize:
     active: true
     folder: mosquitto
   ```

   Expect a short (~seconds) broker blip: HA's MQTT integration reconnects
   automatically; zeus survives MQTT blips (v0.1.41) and reconnects on the
   next publish.

### D. Verify

9. Add-on log shows the bridge connecting and staying up:
   `Connecting bridge jupiter-bridge` and no repeating
   `Socket error`/reconnect churn.

10. **Retained state replicated:** re-run step 6 on `mqtt.lab.local` —
    `homeassistant/#` and `zeus/#` counts now ≈ the step-5 baseline (the
    `homeassistant/sensor/zeus_*/config` discovery topics must be present).
    Rates are flat, not climbing (no echo storm; loop argument above).

11. **Live flow vesta → cluster:** keep
    `mosquitto_sub -h mqtt.lab.local -u bridge-vesta -P "$BRIDGE_PW" -t 'zeus/#' -v`
    open across a zeus cycle boundary (hourly, HH:00) — state updates appear.

12. **Live flow cluster → vesta:** publish a harmless non-retained test on
    the cluster broker and see it arrive on vesta:

    ```sh
    mosquitto_sub -h vesta.lab.local -u <user> -P <pw> -t zeus/bridge_test &
    mosquitto_pub -h mqtt.lab.local -u bridge-vesta -P "$BRIDGE_PW" -t zeus/bridge_test -m hello-from-cluster -q 1
    ```

13. **Nothing regressed:** `sensor.zeus_battery_savings_today` (and the other
    zeus MQTT sensors) still update in HA on the next cycle; HA MQTT devices
    unaffected.

Only after 9–13 pass is #111 (repoint HA) unblocked.

### Rollback (one-liner)

From the vesta SSH add-on:

```sh
rm /share/mosquitto/bridge-jupiter.conf && ha addons restart core_mosquitto
```

(Equivalently: delete the file via Samba/File editor and restart the add-on
from the UI. Setting `customize.active: false` also works but drops any other
future drop-ins.) Optionally delete the `bridge-vesta` user via the same API
as step 2 (`DELETE .../users/bridge-vesta`). Retained messages already copied
to the cluster broker remain there — harmless, and #113 owns final cleanup.

## Removal

Card #113 removes this bridge as part of decommissioning vesta's Mosquitto:
the rollback above, plus deleting the `bridge-vesta` user and this doc's
"transitional" status.
