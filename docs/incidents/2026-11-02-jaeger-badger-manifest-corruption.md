# Post-incident review — Jaeger crash-looped for 5 days on a torn Badger MANIFEST (no card; raised by the owner 2026-11-07)

**Date:** 2026-11-02 → 2026-11-07 · **Severity:** low (observability only: the
tracing backend was down 5 d 7 h and the trace history was lost; no control
path involved, no safety exposure) · **Status:** mitigated — the store was wiped
and jaeger has been healthy since 2026-11-07 19:14Z; the permanent
countermeasures (self-healing start, 2Gi memory) are in this PR and reach the
cluster with the next `develop` → `master` release · **Format:** blameless
SRE-style postmortem with an A3-style summary box. All times **UTC**.

---

## A3 summary (one-box view)

| | |
|---|---|
| **Background** | Jaeger v2 (`platform/jaeger`, Argo app `jaeger`) is a single all-in-one pod with embedded **Badger** storage on the Longhorn RWO PVC `jaeger-badger` (5Gi, 7-day span TTL). Every jupiter service, the lar included, and the ceres services export OTLP spans to `jaeger-collector.jaeger:4317`. The container had a **1Gi memory limit** sized at #162 for an empty store; Badger mmaps its SST files, so the working set grows with the store. The Deployment exec'd the bare binary: a store Badger cannot open is a permanent crash loop. |
| **Problem** | From 2026-11-02 11:33Z every start of the jaeger container failed with `failed to initialize storage 'badger_main': manifest has checksum mismatch` (1 491 restarts by 11-07). `KubePodCrashLooping`, `KubePodNotReady`, `KubeDeploymentReplicasMismatch` and `TargetDown{job=jaeger-collector}` fired for five days, and every OTLP emitter — the live lar in `jupiter-tervuren` first — logged `Failed to export traces … StatusCode.UNAVAILABLE` every cycle. |
| **Direct cause** | The container was **OOM-killed at ~11:32Z on 11-02** (1Gi limit, working set 0.95–1.07 GiB) in the middle of a Badger flush/compaction burst that rewrote the MANIFEST (79 new SST files and the MANIFEST all carry the 11:31 mtime). The kill left a manifest change-set whose CRC no longer matched; Badger refuses to open such a store and Jaeger has no repair path. The 11-01 09:03Z unclean cluster reboot was **not** the cause: the store opened fine at 09:07Z on 11-01 and was written for another 26 h. |
| **Root cause** | (1) Memory limit never re-sized once the 7-day retention filled the store (~660 MiB on disk): the container was OOM-killed every 2–3 days for weeks (10 kills on the previous pod between 10-10 and 11-01), each one a coin flip on store integrity, and nothing alerts on an isolated OOM kill. (2) No self-healing for the one failure mode that is both permanent and harmless to wipe: trace data is diagnostic with a 7-day TTL, but the Deployment could only restart into the same unreadable files. (3) The alerts fired into Alertmanager for five days without reaching anyone who acted. |
| **Countermeasures** | (1) *Stopgap, done 11-07 19:13Z:* keys/ and values/ wiped from a helper pod, jaeger restarted, healthy at 19:14Z. (2) *Permanent, this PR:* `entrypoint.sh` wrapper in the `jaeger-config` ConfigMap — runs the binary, forwards SIGTERM, and wipes the store when the binary exits on a storage-open failure, so the next restart starts fresh. (3) *Permanent, this PR:* memory limit 1Gi → **2Gi**, request 256Mi → 512Mi. (4) README: storage sizing, the wrapper, a manual recovery runbook. |
| **Verification** | Pod `jaeger-854dd87b4d-hc69t` Running 1/1, 0 restarts, `All 0 tables opened` / `Everything is ready` at 19:14:10Z; all four alerts gone from `ALERTS{namespace="jaeger"}` by 19:25Z; lar log: 0 OTLP export errors after 19:14Z (4 in the 30 min before). Wrapper tested on a throwaway pod with a garbage MANIFEST (`manifest has bad magic` → wipe → clean restart, `wipes.log` written) and with SIGTERM (`Shutdown complete.`, exit 0, reason Completed). |
| **Follow-up** | The permanent fixes deploy only with the next release — until then the live pod runs the bare binary at 1Gi and will start OOM-killing again once the store refills (≈ a week). Review the 2Gi ceiling after two weeks of `container_memory_working_set_bytes{namespace="jaeger"}`. Consider an alert on repeated OOM kills (none fires today) and check why no watchdog card was opened for five days of `KubePodCrashLooping`. Trace history before 11-02 is gone (not recoverable, by design). |

---

## Impact

- **Tracing backend down 2026-11-02 11:32Z → 2026-11-07 19:14Z (5 d 7 h 42 min).**
  No spans were accepted in that window; `https://jaeger.lab.local` and the
  Grafana Jaeger datasource returned nothing.
- **Trace history lost:** the store (132 SST files, 663 MiB, spans 10-26 →
  11-02) was wiped to recover. Nothing else lives on that PVC.
- **Alert noise, 5 days:** `KubePodCrashLooping`, `KubePodNotReady`,
  `KubeDeploymentReplicasMismatch` (all `namespace=jaeger`) and
  `TargetDown{job=jaeger-collector}` firing continuously; 1 491 container
  restarts.
- **Export errors in every instrumented service:** the OTel SDK's batch
  exporter in the lar, price/forecast/reporting and the ceres services logged
  `Failed to export traces to jaeger-collector.jaeger.svc.cluster.local:4317`
  (`StatusCode.UNAVAILABLE`) each cycle. The exporter is asynchronous and
  bounded by its own timeout; the lar's 15-min cycles kept running throughout
  and no control-loop effect was observed.
- **Safety exposure:** none — tracing is not on any control path (the lar never
  waits on it).

## Timeline (UTC)

| Time | Event |
|---|---|
| 2026-10-10 → 11-01 | Previous pod `jaeger-854dd87b4d-2rjbp` (node05): restarts 2 → 10, every termination `OOMKilled`; per-container working-set peaks 0.95–1.07 GiB against the 1Gi limit. Nothing alerts on this. |
| 11-01 09:03:45 | Unclean reboot of all six nodes (`node_boot_time_seconds` 1793523825–31 on every node). New pod `jaeger-854dd87b4d-nq5l9` on node03. |
| 11-01 09:07–09:08 | Badger opens the store cleanly, replays the WAL and flushes/compacts (SST `005088`–`005163` written). Jaeger healthy. |
| 11-02 11:30 | Working set 607 MiB and climbing (5-min samples). |
| 11-02 11:31 | Flush + compaction burst: memtable `00049.mem` (128 MiB), SST `005171`–`005249` (79 files) and the `MANIFEST` (92 485 B) all written in this minute. |
| 11-02 ~11:32 | Container **OOMKilled** (`kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` on `nq5l9`). Restart counter 1 → 4 by 11:33 (the kill plus two immediate failed starts). |
| 11-02 11:33 → | Every start: `failed to initialize storage 'badger_main': manifest has checksum mismatch`, exit 1, CrashLoopBackOff (5-min backoff). The four alerts fire; OTLP export errors begin in every emitter. |
| 11-07 ~19:05 | Detected and handed to this session by the owner's session (pod at 1 491 restarts, still on node03). |
| 11-07 19:12 | Helper pod `jaeger-badger-wipe` on node03 with the PVC: Longhorn volume `attached`/`healthy`, 663 MiB store, `MANIFEST` 92 485 B (copy kept at WSL `/tmp/jaeger-MANIFEST.corrupt`), file mtimes as above. |
| 11-07 19:13:10 | `/badger/keys/*` and `/badger/values/*` deleted (store 663 MiB → 40 KiB). |
| 11-07 19:13:40 | Helper pod removed; jaeger pod deleted to skip the backoff. New pod `jaeger-854dd87b4d-hc69t` scheduled on node05 (Longhorn re-attached). |
| 11-07 19:14:10 | `badger: All 0 tables opened`, `Everything is ready` — jaeger Running 1/1. |
| 11-07 19:18–19:20 | Self-healing wrapper verified on a throwaway pod (`jaeger-wrapper-test`): garbage MANIFEST → `manifest has bad magic` → wipe → clean restart; `kill -TERM 1` → `Shutdown complete.`, exit 0. Test pod and ConfigMap removed. |
| 11-07 19:25 | `ALERTS{namespace="jaeger"}` empty (all four resolved); lar log shows 0 export errors since 19:14. |

## Causal chain (5-whys)

1. **Why was jaeger crash-looping?** Badger refused to open the store
   (`manifest has checksum mismatch`); Jaeger exits on a storage-init failure
   and the kubelet restarted it into the same files, 1 491 times.
2. **Why was the MANIFEST unreadable?** The process was SIGKILLed by the OOM
   killer at ~11:32Z on 11-02 while Badger was in a flush/compaction burst that
   rewrote the manifest. The exact write-path mechanism (Badger fsyncs manifest
   appends; the kill plus Longhorn/ext4 interaction still left a change-set
   whose CRC does not match) is not pinned down — and does not need to be: a
   SIGKILL mid-compaction is the documented way to get there. The 11-01
   unclean reboot is ruled out as the cause: the store opened at 09:07Z on
   11-01 and was written for 26 h afterwards.
3. **Why was it OOM-killed?** 1Gi limit vs a 0.95–1.07 GiB working set. Badger
   mmaps every SST file, so the working set tracks the on-disk store
   (~660 MiB for 7 days of spans) plus compaction buffers. This was chronic:
   10 OOM kills on the previous pod between 10-10 and 11-01 — every one of
   them a chance to tear the store.
4. **Why did the limit stay at 1Gi?** It was sized at #162 for an empty store
   and never revisited once the 7-day retention filled it; the OOM kills were
   invisible — a restart every 2–3 days trips neither `KubePodCrashLooping`
   nor any OOM-specific alert in this stack.
5. **Why did it stay broken for five days?** Nothing could self-heal (Badger
   has no manifest repair; the Deployment exec'd the bare binary into the same
   PVC), and the alerts that did fire reached no one who acted: no watchdog
   card appeared on the board for `KubePodCrashLooping{namespace="jaeger"}`.

**Aggravating factor:** the failure is loud in the wrong places — every
instrumented service, the live lar included, logged an export error each cycle
for five days, while the one place that was wrong (the jaeger namespace) only
showed up in Alertmanager.

## Resolution — what was deployed

1. **Store wiped and jaeger restarted** (stopgap, done live 11-07 19:13Z): a
   root helper pod on the volume's node mounted the PVC and deleted
   `/badger/keys/*` and `/badger/values/*`; the jaeger pod was deleted to skip
   the 5-min backoff. No PVC recreation was needed — the PVC is Argo-managed
   and untouched. Runbook now in `platform/jaeger/README.md` ("Manual
   recovery").
2. **Self-healing start** (permanent, this PR): `entrypoint.sh` (new key of
   the `jaeger-config` ConfigMap, run via `command: ["/bin/sh",
   "/etc/jaeger/entrypoint.sh"]`) runs `/cmd/jaeger/jaeger-linux`, forwards
   SIGTERM so pod stops still close Badger cleanly, and — only when the binary
   exits non-zero with `failed to initialize storage 'badger_main'` plus a
   storage-shaped reason (manifest/checksum/corrupt/truncated/bad magic) in its
   startup log — wipes `keys/` and `values/`, appends to `/badger/wipes.log`
   and exits, so the kubelet's next restart initialises a fresh store. Any
   other failure passes through untouched. Both ConfigMap keys are under the
   Deployment's `checksum/config` annotation.
3. **Memory limit 1Gi → 2Gi, request 256Mi → 512Mi** (permanent, this PR,
   `platform/jaeger/values.yaml`): removes the trigger. Nodes have 8 GiB each;
   the working set should settle around 1 GiB.
4. **Docs**: `platform/jaeger/README.md` (sizing, the wrapper, recovery
   runbook; the stale `local-path` wording fixed to Longhorn), chart `0.1.3`,
   this review.

Considered and rejected: Badger `ephemeral: true` ("in-memory" mode). It is a
temp directory on the container's ephemeral disk, not RAM; it would lose all
traces on every pod restart (every release, since the strategy is `Recreate`)
and would do nothing about the OOM kills that caused the corruption.

Reverted: nothing. The helper pod, the wrapper test pod and its ConfigMap were
deleted after use; no ad-hoc change remains on the cluster.

## What went well / what went poorly (blameless)

**Well:** the design limited the damage — tracing is off every control path,
so a 5-day outage cost diagnostics and nothing else; the Longhorn volume was
healthy throughout, so the fix was a directory wipe, not a volume rebuild;
Prometheus retention still held the OOM history from a week before the
corruption, which turned "corrupted by the reboot" into the real story in one
query; the wrapper could be tested end-to-end on a throwaway pod before any
commit.

**Poorly — lessons:**
- **L1:** The first explanation that fits the timeline ("the unclean reboot
  corrupted it") was wrong by 26 hours; the file mtimes and the
  `last_terminated_reason` history disproved it in minutes. *Before fixing a
  "corrupted on reboot" story, check when the files were last written and how
  the process actually died.*
- **L2:** Isolated OOM kills of a stateful pod are silent here and each one is
  a corruption roll of the dice. *A memory limit on an embedded store is a
  retention-dependent number: re-size it when retention or data volume
  changes, and treat any `OOMKilled` on a pod with a PVC as an incident, not a
  restart.*
- **L3:** A store that cannot be repaired must be wipeable automatically when
  its data is disposable. *For diagnostic data, build the wipe into the start
  path; a human doing it five days later is the wrong recovery mechanism.*
- **L4:** Alerts that only reach Alertmanager do not count as detection.
  *Verify the watchdog path for platform namespaces, not just the battery
  ones.*

## Action items

- [x] Wipe the store and restart jaeger (live, 11-07 19:13Z).
- [x] Self-healing `entrypoint.sh` wrapper + SIGTERM forwarding (this PR).
- [x] Memory 512Mi / 2Gi (this PR).
- [x] README: sizing, wrapper, manual recovery runbook (this PR).
- [ ] **Release** `develop` → `master` so the wrapper and the 2Gi limit reach
  the cluster before the store refills (≈ one week at the current span rate)
  — owner command.
- [ ] After two weeks on 2Gi: check `max_over_time(container_memory_working_set_bytes{namespace="jaeger",container="jaeger"}[14d])` and adjust (owner / next platform-upgrade card).
- [ ] Alert on repeated `OOMKilled` terminations of pods with a PVC (atlas; no
  such rule in the stack today).
- [ ] Why did no watchdog (cerberus) card appear for five days of
  `KubePodCrashLooping{namespace="jaeger"}`? (cerberus / owner.)

## References

gitops PR (this branch `fix/jaeger-badger-recovery` → `develop`) · platform
chart `platform/jaeger` 0.1.3 · cards #162 (jaeger stood up), #238 (PVC moved
to Longhorn), #350 (jaeger 2.20.0) · `platform/jaeger/README.md` "Storage,
retention & sizing" · corrupt manifest copy: WSL `/tmp/jaeger-MANIFEST.corrupt`
(not in git).
