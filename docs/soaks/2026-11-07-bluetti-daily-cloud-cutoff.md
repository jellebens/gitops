# Bluetti cloud feed — the daily 15:00Z push cutoff (card #355)

- **Date:** 2026-11-07 (data through 2026-11-07T19:15Z; today's run still open)
- **Author:** Clio role (pattern analysis, read-only), with the HA-side reads hestia
  would otherwise do (vesta over SSH, read-only, no secrets printed).
- **Trigger:** card [#355](https://trello.com/c/WgjhgbR3) — "a placeholder run EVERY
  afternoon ~15:20–17:45Z and a growing evening run since 10-26 that became the 10-31
  blackout — find the cause". Opened by atlas while baselining #333.
- **Sources (all READ-ONLY):** Prometheus (`jupiter_lar_battery_placeholder_rejected_total`,
  `jupiter_lar_battery_report_ages_push_seconds`, `jupiter_lar_soc_pct`,
  `jupiter_savings_today_eur`, `ALERTS_FOR_STATE`); the HA archive in InfluxDB bucket
  `homeassistant` through Grafana's datasource proxy (`input_datetime.bluetti_selfheal_last_reload`,
  `sensor.bluetti_last_push_update`, `sensor.office_buzzbrick_*`); the lar container log;
  the Bluetti integration source on vesta (`/config/custom_components/bluetti/`:
  `models.py`, `oauth.py`, `api/websocket.py`, `api/product_client.py`, `sensor.py`,
  `__init__.py`) and the Bluetti config entry's token *timing* fields; LAN reachability
  of the Apex 300 module (`192.168.50.81`) from WSL and the Windows host; the
  home-assitant repo (`packages/bluetti_selfheal.yaml` 1.2.0). Every number is
  reproducible from Appendix A.

## 1. Verdict

> **The Bluetti cloud stops pushing the unit's data at 15:00–15:06Z every day — 13 of
> 13 days measured (10-23 → 11-07), to the minute, in UTC, unchanged across the
> 10-25 DST change. A second cutoff follows at 18:07–19:30Z. Each cutoff ends on its
> own 2–3 h later, or both merge into one 6–8 h run that ends 21:45–23:15Z. During a
> run the cloud's own status endpoint, read at every self-heal reload, returns only the
> placeholder triple (51 % / 2008 W / 607 W) — the cloud has nothing fresh from the
> unit — while the unit's Wi-Fi module stays on the LAN (pinged during today's run).
> Nothing on the HA side starts it, and nothing on the HA side ends it.**
>
> | Card question | Verdict | Evidence |
> |---|---|---|
> | (1) What happens at ~15:20Z daily? | **The cloud push stops at 15:00–15:06Z.** The lar only *notices* at 15:29Z: the frozen last-real values pass until the first self-heal reload (+13 min) replaces them with the placeholder triple, and the next planning cycle (15:30Z) is the first to reject. | §2 table, `last push` column; §3 reload instants |
> | (2) Why did the evening run grow from 10-26? | **A second daily cutoff at 18:07–19:30Z.** On "short" days the 15:0xZ run recovers at ~17:00–17:35Z and the evening cutoff is a separate 1–3 h run; on "long" days (10-29, 10-30, 11-02, 11-03, 11-04) the first run never recovers and the two merge into one 6.8–8.2 h run ending 21:45–23:15Z. The growth 10-26 → 10-30 is the evening run lengthening, then merging. | §2 |
> | (3) Does the hand patch hold? | **Yes.** `models.py` sha256 `d107921a…55b3` on 2026-11-07, manifest 1.0.5 — the documented patched checksum. Not a HACS wipe. | §4 |
> | Most likely cause | **Device↔cloud session drop on the Bluetti side, on a fixed Beijing-night schedule** (15:00Z = 23:00 CST; 18:30–19:30Z = 02:30–03:30 CST; recoveries 01:00–01:35 CST and 05:45–07:15 CST). Not Wi-Fi/LAN (module answers ping during the run), not the HA token (valid to 2026-12-08), not a local-time schedule (UTC-anchored across DST), not the self-heal (its first reload is a consequence, 13 min after the cutoff). | §4 hypothesis table |
>
> **Gate for the fix card:** the HA integration cannot be made to recover a feed the
> cloud itself has lost. The fix is a telemetry path that does not go through the
> Bluetti cloud (#217 BLE / local, #309 Modbus) and, until then, a lar policy for what
> to do with the evening peak during a placeholder hold (§6).

## 2. The daily timeline

`last push` = the last instant a Bluetti value changed without a reload around it
(HA `sensor.bluetti_last_push_update`, scraped into the lar's
`jupiter_lar_battery_report_ages_push_seconds`); `first push back` = the first change
after the silence; `cycles` = planning cycles the lar rejected as placeholder
(`…placeholder_rejected_total{consumer="soc"}`, one per 15-min cycle); `SoC` = the
last-good SoC the lar held. All times UTC.

| Day | Last push (cutoff) | First push back | Silent | Cycles rejected | SoC held | Note |
|---|---|---|---|---|---|---|
| 10-23 | 15:01:43 | 17:25:43 | 2.4 h | 9 | 52 | evening: 18:44→19:53 (1.1 h, 5 cycles), 20:04→20:24 (0.3 h) |
| 10-24 | 15:02:55 | 16:49:43 | 1.8 h | 7 | 63 | evening blip 20:07→20:27 (0.3 h, no reload reached, 0 cycles) |
| 10-25 | 15:01:32 | 17:06:43 | 2.1 h | 8 | 94 | evening 18:33→19:58 (1.4 h, 4 cycles); **DST ended 01:00Z this day — cutoff unchanged in UTC** |
| 10-26 | 15:04:57 | 17:07:43 | 2.0 h | 7 | 66 | evening hold 19:44→21:44Z, 9 cycles (push gauge did not register it — see §5) |
| 10-27 | 15:02:40 | 17:33:43 | 2.5 h | 10 | 91 | evening 19:01→21:44 (2.7 h, 10 cycles, SoC 85) |
| 10-28 | 15:01:18 | 16:57:43 | 1.9 h | 7 | 97 | evening hold 18:44→21:59Z, 13 cycles (push gauge did not register it) |
| 10-29 | 14:59:21 | 22:19:43 | **7.3 h** | 29 | 86 | one merged run; a single rejected cycle at 13:29Z too |
| 10-30 | 15:01:32 | 22:22:43 | **7.4 h** | 29 | 81 | one merged run |
| 10-31 | 08:23:18 | 11-01 17:41:43 | **33.3 h** | 137 | 70 → 10 | the blackout ([incident review](../incidents/2026-10-31-bluetti-feed-blackout-33h-and-uncontrolled-drain.md)); off-schedule start |
| 11-01 | 18:31:11 | 21:48:43 | 3.3 h | 13 | 24 | evening cutoff only (the blackout had just ended); blip 18:04→18:29 |
| 11-02 | 15:06:14 | 21:53:43 | **6.8 h** | 27 | 53 | merged |
| 11-03 | 15:02:35 | 23:14:43 | **8.2 h** | 33 | 51 | merged |
| 11-04 | 15:00:42 | 21:48:43 | **6.8 h** | 28 | 76 | merged; blip 06:06→06:27 |
| 11-05 | 15:03:38 | 17:34:43 | 2.5 h | 9 | 93 | evening 18:47→21:56 (3.2 h, 12 cycles, SoC 90); blip 08:11→08:28 |
| 11-06 | 15:00:33 | 17:00:43 | 2.0 h | 7 | 92 | evening 19:30→21:42 (2.2 h, 8 cycles, SoC 74) after a blip 19:06→19:29 |
| 11-07 | 15:02:10 | **still silent at 19:15Z** | ≥ 4.2 h | 17 so far | 64 | `JupiterLarPlaceholderHold` since 15:45Z, `…HoldLong` critical since 17:15Z |

Thirteen daily cutoffs between 14:59:21Z and 15:06:14Z — a 7-minute spread over 16
days, with one off-schedule start (10-31 08:23Z, the blackout). Before 10-23 the push
gauge did not exist; the rejected-cycle counter alone (retention from 10-17) shows the
same 15:29Z first-reject every day 10-17 → 10-22 (card description).

## 3. What the HA side did during a run

- **Self-heal reloads** (`input_datetime.bluetti_selfheal_last_reload`, HA archive):
  the first reload lands 12–13 min after the cutoff (today 15:15:06Z after a 15:02:10Z
  cutoff), then one every 15 min for the whole run — 16 reloads today by 19:15Z,
  27 on 11-02, 33 on 11-03. **Every one of them produced the placeholder triple**
  (`sensor.office_buzzbrick_battery_level` = 51 and `…grid_input_power` = 2008 written
  at 15:15, 15:30, 15:45 … 19:15Z today). The reload is a consequence of the cutoff,
  not its cause: the cutoff precedes it by 13 minutes every day.
- **What a reload reads:** `BluettiDevice._async_update()` calls the cloud's
  `GET /ha/v1/deviceStates?sns=<sn>` and copies `stateList` into the entities, and
  sets `on_line` from the response. The entities stay *available* (the placeholder is
  written, not `unavailable`), so the cloud reports the unit online — but with the
  default state list. The cloud has no fresh data from the unit for the whole run.
- **Recovery is not reload-driven.** Reloads run every 15 min throughout and most do
  nothing. The push comes back either within a minute of a reload (11-02 21:50Z
  reload → 21:53:43Z; 11-04 21:45Z → 21:48:43Z; 11-06 17:00Z → 17:00:43Z) or 11–12
  min after one (11-05 21:45Z → 21:56:43Z; 11-06 21:30Z → 21:42:43Z) — i.e. whenever
  the unit's data is back in the cloud, the next subscription (or the live one) gets it.
- **HA core itself restarted today at ~18:50Z** (empty `home-assistant.log.fault`
  created 19:50 local, config entry `modified_at` 19:04:53Z, entity re-writes at
  19:04:14Z and 19:04:58Z). The run continued through it.
- **The lar** held PASSTHROUGH from the first rejected cycle on, on the last-good SoC
  (64 % today), and suppressed every planned discharge ("plan intent 'discharging'
  suppressed", every 10 s; plans of 0.44–0.61 kW through the evening peak). That is
  the #320 contract working as designed.

## 4. Hypotheses, tested

| Hypothesis | Verdict | Why |
|---|---|---|
| HA automation / self-heal timer | **No** | First reload is 12–13 min *after* the cutoff; automations run on HA local time and would have moved an hour at the 10-25 DST change — the cutoff did not. |
| Bluetti OAuth token expiry / refresh | **No** | Config entry: token refreshed 2026-10-31T04:10Z, `expires_in` 31 d, `expires_at` 2026-12-08. The integration's daily token check only refreshes inside the last 7 days. (A latent defect noted in §5 — the websocket's ERROR-frame path *disconnects and never reconnects* — but it needs a server ERROR frame to trigger, and recovery would then require a reload, which the self-heal supplies every 15 min and which does not help.) |
| Hand patch wiped by a HACS update (#319) | **No** | sha256 `d107921a307a01cf28392a42d1767ed64da6beda10694d0c14ebfc49238655b3` on 2026-11-07, the documented patched value; files dated Sep 20 / Oct 4, nothing newer. |
| Wi-Fi / LAN drop of the Apex 300 module (as on 10-05 and 10-07) | **No, not this pattern** | During today's run (19:20Z) `192.168.50.81` answered 4/4 pings from WSL (47–118 ms) and 3/3 from the Windows host; ARP entry `00-4b-12-31-65-6c` present. (Ports 80/443/8080 refused — the module runs no local service.) On 10-05/10-07 the MAC was absent from the LAN; those were different failures. |
| Local-time schedule anywhere in the house (router, mesh, HA, unit set to local time) | **No** | Cutoffs 10-24 15:02:55Z and 10-25 15:01:32Z straddle the DST change without moving. A local-clock schedule shifts by one hour in UTC. |
| Solar / thermal / load | **No** | Fixed clock time across days with very different SoC (24 → 97 %) and modes (holding at 52 % and at 97 %); sunset moved 40 min over the window. |
| **Cloud-side or unit-side session schedule in Bluetti's time zone** | **Most likely** | Every cutoff and recovery maps to a round Beijing-night time: 23:00 CST cutoff; 02:30–03:30 CST second cutoff; recoveries 01:00–01:35 CST and 05:45–07:15 CST. A unit that re-registers with the cloud nightly (or a cloud that recycles device sessions nightly) and takes 2–8 h to re-establish fits every row of §2, including the device staying on the LAN and the REST status endpoint going blank. The 10-31 off-schedule 33 h blackout is the same failure with a failed re-registration. |

What this report **cannot** decide from the lab side: whether the unit stops
*sending* (uplink MQTT session dropped by the module's firmware on its own schedule) or
the cloud stops *forwarding* (session recycled server-side). Both are Bluetti's; the
owner-only checks that would tell them apart are in §6.

## 5. Observations on the integration and the lar (read-only, for the fix cards)

- `api/websocket.py` `StompListener.on_message`: a STOMP `ERROR` frame with msgCode
  400/403/600/805 calls `client.disconnect()` and fires `EVENT_TOKEN_EXPIRED`; the only
  listener (`AuthTokenRefresh.on_token_expired_event`) posts a persistent notification.
  **No reconnect, no reload** — after such a frame the websocket stays dead until a
  config-entry reload. The self-heal's 15-min reload is the only thing that would
  revive it. Worth an upstream issue regardless of #355.
- `oauth.py` `start_token_check()` registers a new `async_track_time_interval` on
  **every** `async_setup_entry` and discards the unsubscribe handle: each self-heal
  reload leaks one daily timer. Harmless at the moment (the check is idempotent and
  rate-limited to one refresh per hour), but after a 33-cycle run there are 33 of them.
- `on_close` in the websocket listener uses `print()` for the disconnect reason, so the
  close code never reaches the HA log.
- The lar's `jupiter_lar_battery_report_ages_push_seconds` gauge **froze at 710 s** for
  all of today's run (15:14Z → 19:15Z) while HA's own `sensor.bluetti_last_push_update`
  correctly stayed at 15:02:10Z. The same gauge missed the 10-26 and 10-28 evening
  holds. The rejected-cycle counter is the reliable hold signal (the #333 alerts are
  built on it — correct choice); the push gauge needs the same look as the stale
  gauge in #332.
- HA core logs are not readable from WSL: `ha core logs` returns nothing through the
  SSH add-on and Docker is behind protection mode. `/config/home-assistant.log` does not
  exist on this install (journal only). The owner can read them from the HA terminal.

## 6. What to do

1. **Owner checks (minutes each) that would settle unit-side vs cloud-side:**
   - At 15:05Z (16:05 local) open the Bluetti app: does the unit show *offline*, or
     online with stale data? Offline = the unit's uplink; online-but-stale = the cloud.
   - From the HA terminal (not the SSH add-on): `ha core logs | grep -i -e stomp -e
     websocket` around 16:00–16:10 local — is there a "WebSocket disconnected" /
     "Websocket reconnect" / "Connect the BLUETTI WebSocket Server successfully" at the
     cutoff, or does the socket stay silently connected? A silent, connected socket
     with no messages = the cloud has nothing to forward.
   - A support ticket to Bluetti with the §2 table: "device SN … stops reporting at
     23:00 CST every day, recovers 01:00–07:00 CST".
2. **The fix is a non-cloud telemetry path** — this is what #217 (BLE / local MQTT)
   and #309 (Modbus TCP, blocked on firmware) exist for. The installed integration
   already has a BLE `control_mode` (`models.py` `read_data_from_ble`,
   `update_from_bluetooth`); the open question is Bluetooth reach from vesta to the
   office. That is #217's first experiment.
3. **Until then, a lar policy for the evening peak during a placeholder hold**
   (hephaestus, owner decision): the hold currently suppresses the planned discharge
   on a last-good SoC that was fresh 13 minutes before the cutoff. A bounded discharge
   on last-good SoC (e.g. allowed while last-good SoC minus the planned energy stays
   above a floor, for at most N hours after the cutoff) would recover most of the
   evening without the 10-31 drain risk — the drain happened because the hold was
   *not* writing PASSTHROUGH at a floor, which #333's hephaestus item already covers.
4. **Savings context** (`jupiter_savings_today_eur`, end-of-day max; prices differ by
   day, so this is indicative): 10-26 €0.67 and 10-27 €0.72 with the evening free;
   10-28 → 11-05 between €0.03 and €0.31 with the evening held; 11-06 €0.36 with the
   evening recovering at 21:42Z; 11-07 €0.03 at 19:15Z with the hold still on.

## Appendix A — queries and scripts

PromQL (Grafana datasource `prometheus`):

```promql
# rejected planning cycles per 15-min slot (the hold)
sum(increase(jupiter_lar_battery_placeholder_rejected_total{consumer="soc"}[15m]))
# push age (cutoff instant = t - value at the last point before recovery)
max(jupiter_lar_battery_report_ages_push_seconds)
# alert start instants
ALERTS_FOR_STATE{alertname=~"JupiterLarPlaceholderHold.*"}
# end-of-day savings
max_over_time(jupiter_savings_today_eur[1d])
```

Flux (Grafana datasource `influxdb`, bucket `homeassistant`, `POST /api/ds/query`):

```flux
from(bucket:"homeassistant") |> range(start:-7d)
  |> filter(fn: (r) => r.entity_id == "bluetti_selfheal_last_reload" and r._field == "state")
from(bucket:"homeassistant") |> range(start:2026-11-07T14:30:00Z)
  |> filter(fn: (r) => r.entity_id == "bluetti_last_push_update" and r._field == "state")
from(bucket:"homeassistant") |> range(start:2026-11-07T14:30:00Z)
  |> filter(fn: (r) => (r.entity_id == "office_buzzbrick_battery_level" or
       r.entity_id == "office_buzzbrick_ap3002532000565690_grid_input_power") and r._field == "value")
```

The two Python scripts that produced the §2 table (episodes per day from the
rejected-cycle counter; cutoff/recovery instants from the push gauge) ran against a
`kubectl port-forward` of `svc/kube-prometheus-stack-prometheus`; their logic is the
PromQL above plus "an outage starts when push age exceeds 900 s and ends at the first
point where it drops below 600 s".

vesta reads (SSH add-on, `admin@vesta.local`, read-only):

```sh
sudo sha256sum /config/custom_components/bluetti/models.py
sudo jq '.data.entries[] | select(.domain=="bluetti") | {modified_at, last_token_refresh: .data.last_token_refresh, expires_at: .data.token.expires_at, expires_in: .data.token.expires_in}' /config/.storage/core.config_entries
```

LAN: `ping -c 4 192.168.50.81` (WSL) and `ping -n 3 192.168.50.81; arp -a` (Windows) at
2026-11-07T19:20Z, inside the run.
