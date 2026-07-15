# cerberus — watchdog routing table & poll spec

**Docs-only directory.** There is **no Helm chart and no Argo `Application`
here** — cerberus is a *subagent* (`.claude/agents/cerberus.md`) driven by a
scheduled read-only Prometheus poll, not a deployed workload. This README is the
watchdog's operating manual: the exact PromQL it runs, the signal → severity →
triage → card routing table, the dedup/state design, the daily owner-digest
spec, and the future Alertmanager-webhook upgrade path. Nothing in this folder is
reconciled to the cluster.

> **Home (card #187).** Cerberus now runs **inside the hermes agent** as a native
> `delegate_task` subagent of Cortana (persona in
> `landingzones/hermes/values.yaml` `cerberus.soul` → `hermes-cerberus-soul`
> ConfigMap → `/opt/cerberus/SOUL.md`), on two independent schedules Cortana
> enforces: the **30-min watchdog poll** and the **daily 18:00 owner digest**.
> This README stays the authoritative routing table the SOUL points at. In the
> cluster cerberus reaches Trello via the REST API with the `CERBERUS_TRELLO_*`
> env creds (sealed into `hermes-cerberus-trello`) rather than the Trello MCP.

## What cerberus does (and the hard boundary)
Cerberus polls the in-cluster Prometheus on a schedule, and on a **new** firing
problem it triages **read-only** and opens a Trello card in TODO so the issue
enters the pipeline. **Trust boundary is HARD: READ-ONLY diagnosis + Trello card
creation ONLY** — never `kubectl apply|delete|scale|edit|patch|rollout|exec`,
never `argocd sync`, never a battery / zeus / jupiter-lar / MQTT / HA change,
never an Alertmanager or PrometheusRule edit, never git. Proposed fixes go **in
the card body** for a human/specialist to action. This watches a LIVE battery
controller (jupiter-lar drives the tervuren battery; zeus is the live
cross-check) — a wrong mutation is a real incident.

## Trigger — cron-poll; webhook is the documented upgrade
- **v1.1 (built, #187): hermes-hosted schedule.** Cortana runs cerberus as a
  `delegate_task` subagent on a recurring schedule — the **30-min watchdog poll**
  (this routing table) plus a **daily 18:00 owner digest** (separate schedule,
  below). The two are independent delegations so the digest never delays the
  poll. **Cutover:** this SUPERSEDES the earlier owner-machine Claude Code
  scheduled task ("Scheduled-task poll prompt" below is retained for reference);
  **retire that standalone runner at deploy** so the two don't double-file (dedup
  would catch duplicates, but the standalone runner is superseded).
- **v1 (superseded): owner-machine scheduled task.** A Claude Code scheduled task
  ran every N minutes on the owner's Windows host. Kept as the fallback/reference
  prompt; turned off at the #187 cutover.
- **v2 (future upgrade — Alertmanager webhook, push):** wire
  `kube-prometheus-stack` Alertmanager → a `webhook_config` receiver (an HTTP
  endpoint) that invokes a cerberus run per firing alert, replacing the poll.
  The routing table below is transport-agnostic: the same `alertname` →
  severity/triage/card mapping applies whether the alert arrives by poll of the
  `ALERTS` metric or by webhook payload. When the receiver exists, point
  Alertmanager's `route` for `severity=~"warning|critical"` at it, keep the
  dedup state file (Alertmanager's own `group_by`/`repeat_interval` is a second
  dedup layer), and retire the cron schedule. Everything else — triage steps,
  card templates, topic labels, dedup key — is unchanged.

## Prometheus endpoint (verified)
`kube-prometheus-stack-prometheus.observability:9090` — HTTP API at
`/api/v1/query` (instant) and `/api/v1/query_range` (range). Confirmed against
`landingzones/hermes/README.md` and the live soak scheduled-tasks, which query
the same service. Reach it with a throwaway curl pod (read-only, self-deleting):

```sh
wsl -d ubuntu -- bash -c 'kubectl run -n observability cerbNNN --rm -i \
  --restart=Never --image=curlimages/curl:8.10.1 --quiet -- \
  curl -s "http://kube-prometheus-stack-prometheus.observability:9090/api/v1/query?query=<URL-ENCODED-PROMQL>"'
```
Fresh `cerbNNN` per call. `--rm` removes the pod; it never touches a real
workload.

## Primary signal — `ALERTS`, not re-invented thresholds
The one query that surfaces **every shipped PrometheusRule** (zeus, jupiter,
EMQX, Longhorn, hermes, and the kube-prometheus-stack built-ins) already gated by
their tuned `for:`/expectation logic:

```promql
ALERTS{alertstate="firing", severity=~"warning|critical"}
```

Poll this first. Each returned series carries `alertname`, `severity`, and the
identifying labels (`namespace`, `pod`, `site_id`, `zone`, `deployment`, …) —
that IS the dedup key and the card content. **Do not clone the thresholds** those
rules already encode. The raw queries in the next section exist only for
invariants with **no shipped rule** or to catch a condition **before** its `for:`
elapses.

### Alert catalogue (what `ALERTS` can surface, by source)
Reused shipped rules — cerberus routes these straight from `ALERTS`:

| Source (PrometheusRule) | Alertnames | Topic |
| --- | --- | --- |
| `landingzones/zeus` (`zeus`) | `ZeusDown`, `ZeusCycleStalled`, `ZeusCycleFailing`, `ZeusPriceSourceDegraded`, `ZeusPricePartialCoverage`, `ZeusNoPriceData`, `ZeusSocCriticallyLow`, `ZeusControlUnavailable`, `ZeusOptimizerNotOptimal`, `ZeusBatteryStateMismatch` | `zeus` |
| `landingzones/jupiter-central` price (`price-service`) | `JupiterPriceServiceDown`, `JupiterPriceServiceNoReplica`, `JupiterPriceServiceCrashLooping`, `JupiterPriceFeedDegraded`, `JupiterPricePartialCoverage`, `JupiterPriceTomorrowMissing`, `JupiterPriceTomorrowMissingCritical`, `JupiterPriceNoUsableCurve` | `infra` |
| `landingzones/jupiter-central` forecast (`forecast-service`) | `JupiterForecastServiceDown`, `JupiterForecastArtifactStale`, `JupiterForecastTrainingFailing` | `infra` |
| `landingzones/jupiter-central` reporting (`reporting-savings-parity`) | `JupiterReportingSavingsParityNoData`, `JupiterReportingSavingsParityDiverged`, `JupiterSavingsNotIndependent` (#181 — savings-source not independent / source-flag) | `infra` |
| `landingzones/jupiter-shadow` (`jupiter-shadow`) | `JupiterShadowHarnessNoData`, `JupiterShadowLogicDivergence`, `JupiterShadowSetpointDelta`, `JupiterShadowGuardConflict` | `infra` |
| `platform/mqtt` (`emqx`) | `EMQXNodeDown`, `EMQXQuorumLost`, `EMQXQueueSaturation`, `EMQXAuthFailureSpike`, `EMQXClusterPartition` | `infra` |
| `platform/longhorn` (`longhorn`) | `LonghornVolumeFaulted`, `LonghornVolumeDegraded`, `LonghornRebuildStorm`, `LonghornNodeNotReady`, `LonghornNodeStorageAboveThreshold` | `infra` |
| `landingzones/hermes` backup | `HermesBackupNotRun` | `hermes` |
| kube-prometheus-stack built-ins | `TargetDown`, `KubePodCrashLooping`, `KubePodNotReady`, `KubeContainerWaiting`, `KubeDeploymentReplicasMismatch`, `KubeJobFailed`, `KubeNodeNotReady`, `Watchdog` (ignore — always-firing heartbeat) | `infra` |

> Severity comes from the alert's own `severity` label. `critical` → card first &
> flag urgency in the body; `warning` → normal TODO card. Ignore `Watchdog`
> (kube-prometheus-stack's always-on heartbeat) and `severity="none"/"info"`.

## Raw safety-net queries (only where no shipped rule covers it)
Run these in addition to `ALERTS`. Each is here for a specific gap.

| # | PromQL | Why (not covered by a firing rule) | Sev | Topic |
| --- | --- | --- | --- | --- |
| R1 | `max(jupiter_controllers_live) > 1` | **Double-live invariant.** The load-bearing "exactly ONE controller per battery" safety property (jupiter-tervuren README). No shipped PrometheusRule found in-repo — cerberus is the watcher. `>1` = two controllers commanding one battery. | **critical** | `infra` |
| R2 | `absent(jupiter_controllers_live) or max(jupiter_controllers_live) == 0` | **Zero-live** — no controller commanding the battery (interlock stuck refusing / lar down). `absent()` also catches the lar not scraping at all. | **critical** | `infra` |
| R3 | `up{namespace="zeus"} == 0` | Catches zeus scrape-down *before* `ZeusDown`'s 10m `for:` (early warning; still card only once). | warning | `zeus` |
| R4 | `up{namespace=~"jupiter.*"} == 0` | Any jupiter target (lar/price/forecast/reporting) down, before the per-service 10m rules. | warning | `infra` |
| R5 | `kube_pod_container_status_waiting_reason{reason=~"ImagePullBackOff|ErrImagePull",namespace=~"zeus|jupiter-.*|observability|argocd|influxdb|mqtt|longhorn-system"} == 1` | Explicit ImagePull failure (common arm64 `--platform` miss) — surfaces the pod/image directly; `KubeContainerWaiting` is slower and coarser. | warning | `infra` |
| R6 | `max by (namespace,pod) (increase(kube_pod_container_status_restarts_total{namespace=~"zeus|jupiter-.*"}[15m])) > 3` | Restart churn in the LIVE control namespaces, before `KubePodCrashLooping`'s window. | warning | `zeus`/`infra` |
| R7 | `time() - max(zeus_last_cycle_timestamp_seconds) > 5400` | Stale zeus cross-check cycle (>1.5h; hourly cycles) — earlier nudge than `ZeusCycleStalled`'s 2h. Warning; zeus is the check, not the commander. | warning | `zeus` |
| R8 | `time() - max by (site_id)(jupiter_lar_last_cycle_timestamp_seconds) > 2400` | **Stale LIVE-controller cycle** (>40m; lar plans every 15m). No shipped lar-staleness rule found — this is the LIVE path, so cerberus watches it. | **critical** | `infra` |
| R9 | `jupiter_lar_control_available == 0` | LIVE lar's working-mode select unreachable → commands are no-ops on the real battery. No shipped rule found; mirror of `ZeusControlUnavailable` for the live side. | **critical** | `infra` |
| R10 | `max by (site_id)(increase(jupiter_lar_ha_read_errors_total[15m])) > 0` and/or `jupiter_lar_ha_read_ok == 0` | LIVE lar failing HA reads (SoC/grid/peak) → degrades to fail-safe. Watch, don't page hard (fail-safe by design). | warning | `infra` |

Route each of R1–R10 through the same triage → card flow, using a synthetic
`alertname` for the dedup key (e.g. `CerberusControllersDoubleLive`,
`CerberusLarCycleStale`) so raw-query cards dedup like rule cards.

## Signal → triage → card (routing detail)
For every firing signal (rule or raw):

1. **Classify severity** from the `severity` label (rules) or the table above
   (raw). `critical` LIVE-battery signals (R1, R2, R8, R9; `ZeusSocCriticallyLow`,
   `ZeusNoPriceData`, `JupiterPriceTomorrowMissingCritical`,
   `JupiterPriceNoUsableCurve`, `EMQXQuorumLost`, `LonghornVolumeFaulted`) get an
   explicit **`⚠ critical / LIVE`** line at the top of the card body.
2. **Triage READ-ONLY** — pull the alert's supporting values so the card is
   actionable, e.g.:
   - `Zeus*`: query `zeus_price_source`, `zeus_solver_optimal`,
     `zeus_control_available`, `zeus_soc_percent`, `zeus_last_cycle_timestamp_seconds`.
   - `Jupiter* / R1-R2 / R8-R10`: query `jupiter_controllers_live`,
     `jupiter_lar_live_actuating`, `jupiter_zeus_commander_value`,
     `jupiter_lar_control_available`, `jupiter_lar_ha_read_ok`,
     `jupiter_lar_last_cycle_timestamp_seconds`; `kubectl get pods -n
     jupiter-tervuren` (read-only).
   - Pod/target down / crashloop / ImagePull: `kubectl -n <ns> get pod <pod>`,
     `kubectl -n <ns> describe pod <pod>` (read-only), last `kubectl logs` lines.
   - Price/forecast: which zone, `source_label`, `jupiter_price_cache_age_seconds`,
     `jupiter_forecast_artifact_age_seconds`.
   Never run a mutating command as "triage".
3. **Open the card** (template below), **dedup first** (next section).

### Card template
- **List:** TODO — `698cff247e95e06b91beec1c`.
- **Title:** `#NN <short symptom>` — create the card, read `idShort` from the
  response, then rename to prefix `#NN` (standing convention).
  e.g. `#212 ZeusNoPriceData firing — zeus on safe idle (no price feed 15m)`.
- **Topic label at creation** (see IDs below) — never just an agent-slot colour.
- **Body:**
  ```
  ⚠ critical / LIVE        <- only for LIVE-battery critical signals
  Detected by cerberus (watchdog) at <UTC timestamp>, source: <poll|webhook>.

  Alert: <alertname>  severity=<sev>
  Firing series / PromQL:
    <the exact expr>  ->  <value>   {labels...}
  Triage (read-only):
    <supporting query values / kubectl get|describe|logs excerpts>
  Likely cause: <one line>
  Proposed next step (for a human/specialist — cerberus did NOT action this):
    <e.g. "restart deploy/jupiter-cell to force interlock re-read (jupiter-tervuren
     README go-live runbook)" — described, not performed>
  Links:
    Prometheus: http://kube-prometheus-stack-prometheus.observability:9090/graph?g0.expr=<expr>
    Grafana:    http://grafana.lab.local (relevant dashboard)
  cerberus-key: <alertname>{<sorted critical labels>}
  ```
- The `cerberus-key:` line is the machine dedup marker (below). Paste metric
  names/labels/values only — **never a secret/token**.

## Dedup / state design
Goal: **one card per distinct firing alert**, no duplicates across poll runs, and
resilient to state-file loss.

- **Dedup key** = `alertname` + the critical identifying labels, sorted:
  `site_id`, `namespace`, `pod`, `deployment`, `zone` (whichever the series
  carries). e.g. `ZeusNoPriceData{}`, `KubePodCrashLooping{namespace=jupiter-central,pod=price-service-xxx}`,
  `CerberusControllersDoubleLive{site_id=tervuren}`.
- **Two-layer dedup, Trello is authoritative:**
  1. **State file (fast path):** a small JSON keyed by dedup-key →
     `{cardShortId, firstSeen, lastSeen}`. Default location (task-local, owner may
     relocate): `C:\Users\jelle\.claude\scheduled-tasks\cerberus-watchdog\state.json`.
     If the key is present, skip. Update `lastSeen` each run.
  2. **Trello search (authoritative, survives state loss):** before creating,
     read the open pipeline lists (TODO, Investigate, Plan, Doing, Awaiting
     Validation, Waiting User Input — IDs below) and skip if any card body already
     contains `cerberus-key: <key>`. This is what guarantees no duplicate even if
     the state file is lost/rebuilt. On a match, refresh the state file from the
     found card and skip.
- **Create only when both layers miss.** After creating, write the key + new
  `idShort` to the state file.
- **Lifecycle = open-only (v1).** No auto-comment/move/close on resolve. **v2
  idea:** on a key that was firing and is now absent from `ALERTS`, post a
  "resolved" comment (and optionally move the card) — deferred; do not build.

## Topic labels & list IDs (board `698cfe8456c9783aaf669140` — "My Trello board")
Apply the correct **topic** label at creation (not an agent-slot colour):

| Topic | Label ID | Use for |
| --- | --- | --- |
| `zeus` (yellow) | `6a44ec913650b63c8c4af89f` | `zeus_*` / ns-`zeus` signals |
| `infra` (green) | `698cfe8656c9783aaf6696a9` | cluster / platform / **jupiter** signals |
| `HA` (blue) | `698d008ac4766798550b5aba` | (v2 only — HA-side signals, out of v1 scope) |
| `hermes` (pink) | `6a44ec955a0f8d046227e504` | hermes backup signals |

Pipeline lists (for the Trello-search dedup layer):

| List | ID |
| --- | --- |
| TODO (create here) | `698cff247e95e06b91beec1c` |
| Investigate | `6a44d2703a0f3c487659ef55` |
| Plan | `6a44d34451048b039825ac16` |
| Doing | `698d00cafe6e29f3ff72fdf0` |
| Awaiting Validation | `6a44f4de25c6ccc80364e600` |
| Waiting User Input | `6a44d2832dc9eb8158cb056e` |
| Done | `698d00d004e1650d4907f897` |

## Daily owner digest (18:00 Europe/Brussels) — card #187
A **once-a-day** overview, on a schedule **separate** from the 30-min watchdog
poll (so it can never delay it). It is **READ-ONLY reporting only — it files no
cards and mutates nothing**. Cerberus compiles it and hands it to Cortana, who
posts it to her **Discord** home channel (the chosen delivery channel; a pinned-
card Trello comment was the fallback). Keep it to ~15 scannable lines, lead with
the bottom line, and never invent a number — if a metric is missing, say so. If
nothing is wrong, a one-line "all green" is a complete digest.

Content (all read-only queries against the same Prometheus endpoint):

| Line | Source (read-only) |
| --- | --- |
| Fleet-health one-liner | `up{namespace=~"zeus|jupiter.*|observability|mqtt|longhorn-system"}` + `count(ALERTS{alertstate="firing",severity=~"warning|critical"})` |
| Savings today + parity | `zeus_savings_today_eur`; the jupiter reporting savings + parity state (`JupiterReportingSavingsParity*`, the #181 `JupiterSavingsNotIndependent` independence check) |
| Soak clean-day count | the current #164 soak clean-day counter (or "n/a" if not exported) |
| Spike-responder observe stats | the #177 observe counters (spike signals seen / responded — `jupiter_lar` spike metrics) |
| Last 24h | alerts fired (from `ALERTS`/`increase`) and cards you filed (count open cards whose body carries a `cerberus-key:` created in the window) |
| Awaiting owner | open cards in **Waiting User Input** (`6a44d2832dc9eb8158cb056e`) + any LIVE-battery critical still firing |

## Signals with NO clean PromQL mapping (flagged gaps)
- **InfluxDB write failures** (a card-listed signal): **no clean cluster-side
  metric exists.** zeus does not export a per-write InfluxDB failure counter, and
  the jupiter-lar does **not** write to InfluxDB at all (its `degraded.influx`
  flag is a placeholder — see the zeus→jupiter migration plan doc). The closest
  proxies already covered elsewhere: `ZeusCycleFailing`
  (`increase(zeus_cycle_failures_total[1h])`) folds in write-path failures on the
  zeus side, and `JupiterForecastTrainingFailing` covers the trainer's InfluxDB
  reachability. **Follow-up:** if a dedicated InfluxDB write-failure signal is
  wanted, the app (zeus/reporting) must first export a
  `*_influx_write_errors_total` counter and ship a PrometheusRule; cerberus then
  routes it from `ALERTS` for free. Recorded here so it isn't silently dropped.
- **HA-side alerts** (e.g. HA price-sensor unavailable): **out of v1 scope** by
  decision. Not watched. Follow-up card to extend cerberus (topic `HA`) when the
  HA Alertmanager/entity signals are exposed to the in-cluster Prometheus.
