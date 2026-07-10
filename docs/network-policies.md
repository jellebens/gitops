# Network Policies — flow map, plan, staging & rollback (card #145)

Status: living document. Started 2026-07-10 (card #145, PR 1 of N).
Owner directive (2026-07-05): put CiliumNetworkPolicies (CNPs) in place across
all namespaces — baseline ingress first, egress lockdown later, **one namespace
per PR/release**, zeus + coredns-lab **last**.

This cluster carries a **live battery controller** (jupiter-tervuren LAR, with
zeus as running cross-check), the **authoritative `lab.local` DNS**
(coredns-lab), and a wireless-backhaul LAN. A wrong policy here is a
stop-the-line event, so every step below is deliberately small and reversible.

---

## 1. Hard rules (read before writing any policy)

1. **Ingress-only first.** In Cilium, a policy with only `ingress` rules puts
   the selected endpoints into default-deny for INGRESS ONLY — egress stays
   fully open. That is the repo convention (zeus, jupiter-central,
   jupiter-tervuren, mqtt) and the pattern for every baseline PR.
2. **Egress lockdown is a separate, human-reviewed, opt-in step** per
   namespace (`networkPolicy.egress.enabled`-style flag, default `false`,
   never flipped on by an agent). A missed egress allow severs a live feed.
3. **⚠ DNS egress allows (MANDATORY in every future egress policy).** Any
   egress-locking policy MUST allow, before anything else:
   - **kube-dns** (`kube-system`, `k8s-app: kube-dns`) on 53/UDP + 53/TCP —
     all in-cluster resolution, including `*.lab.local` names which cluster
     CoreDNS forwards to coredns-lab;
   - **coredns-lab** (`kube-system`, `app.kubernetes.io/name: coredns-lab`)
     on 53/UDP + 53/TCP — for any pod configured to query the lab DNS VIP
     (192.168.50.180) directly, and to keep the forward path working.
   Without these a pod loses ALL name resolution — historically this is
   exactly the failure mode that took down HA→InfluxDB, price sensors and
   zeus together.
4. **⚠ Cilium 1.16 gotcha — never combine `fromEntities` and `fromEndpoints`
   in the SAME ingress rule.** The apiserver accepts it but the Cilium agent
   rejects the whole policy: `combining FromEntities and FromEndpoints is not
   supported yet` → the CNP shows `VALID=False` and is **NOT enforced at
   all** (no allow-list, no default-deny). Found live on 2026-07-10:
   - `jupiter-central/reporting-service` — VALID=False since 2026-07-06;
   - `jupiter-tervuren/jupiter-cell` — VALID=False since 2026-07-05.
   Both namespaces are effectively unpoliced until the rule is split into two
   separate ingress rules (one `fromEntities`, one `fromEndpoints`). Fixing
   these is step 2 of the staging plan. Always check `kubectl get cnp -A`
   (VALID column) after any CNP change.
5. **Gateway traffic has the reserved `ingress` identity.** Requests arriving
   through the Cilium Gateway (`cilium-gateway`, VIP 192.168.50.200, all the
   `*.lab.local` HTTPRoutes) reach the backend pod from the Cilium Envoy
   proxy, which Hubble shows as `(ingress)`. Allow it with
   `fromEntities: [ingress]` — NOT via a namespace/pod selector on the
   `gateway` namespace (there are no pods there; Envoy runs node-local in
   kube-system with its own reserved identity). Verified live via Hubble at
   `influxdb-influxdb2-0:8086`.
6. **Kubelet probes come from the node host** and are allowed by Cilium by
   default when ingress policy is enforced (`(host)` identity flows; the live
   zeus pod has relied on this for weeks). No explicit rule needed for
   probes.
7. **Reply traffic is stateful.** Egress-initiated connections (e.g. hermes'
   Discord websocket) get their replies through an ingress default-deny;
   conntrack handles it. Do not add "allow world" ingress rules for replies.
8. **One namespace per PR, one PR per release.** Never batch. Live applies
   happen only at a user-commanded release (Argo deploys from `master`).

## 2. Flow map (inventoried 2026-07-10)

Evidence: repo manifests (Services, HTTPRoutes, ServiceMonitors, existing
CNPs), `kubectl get cnp/svc/servicemonitor/httproute -A` (read-only), and
Hubble observe samples taken from cilium-agent pods (read-only). Hubble
samples are point-in-time (~500 flows/node); flows marked **[repo]** are
derived from manifests and not (yet) Hubble-confirmed; **[hubble]** flows
were observed live.

LAN facts: gateway VIP 192.168.50.200 (cilium-gateway), cilium-ingress .201
(unused legacy), mqtt VIP .181, coredns-lab VIP .180, HA/vesta .18,
router/upstream DNS .1, DS918 NAS .144 (lab.local slave + SMB), nodes
.151–.156.

| Namespace | Inbound (who → what:port) | Outbound (to where) | CNP today |
|---|---|---|---|
| **zeus** | observability→9000 (Prom scrape) [repo, allowed by CNP]; host→9000 probes [hubble] | HA/vesta 192.168.50.18:8123 [hubble]; EMQX VIP .181:1883 [repo, #112]; InfluxDB influxdb:80→8086 [repo]; jupiter-central price 8080 [repo]; SMB NAS .144:445 [repo]; ENTSO-E/Open-Meteo 443 (world; 94.130.142.35 observed) [hubble]; DNS | **zeus** (ingress-only, VALID=True) |
| **jupiter-tervuren** | observability→8080 (scrape) [repo]; host→8080 probes [hubble] | HA .18:8123 (HEM poke) [hubble]; EMQX .181:1883 [repo]; jupiter-central 8080 [repo]; InfluxDB 8086 [repo]; DNS | **jupiter-cell — VALID=FALSE (not enforced!)** — fix = split entities/endpoints rules |
| **jupiter-central** (price, forecast, reporting) | zeus→price:8080, cells→8080, observability→8080 scrapes [repo]; host probes [hubble] | reporting→InfluxDB 8086 [hubble]; price→ENTSO-E 443 (world) [repo]; forecast-train jobs→forecast 8080 + InfluxDB [repo]; DNS | price + forecast VALID=True; **reporting — VALID=FALSE (not enforced!)** |
| **influxdb** | zeus, jupiter-central (reporting [hubble], others [repo]), jupiter-tervuren [repo] → 8086; observability Prom scrape → 8086 [hubble]; Grafana → 8086 [repo]; Gateway `ingress` identity → 8086 (influxdb.lab.local, incl. HA on the LAN) [hubble]; backup CronJobs (same ns) → 8086 [hubble]; host probes [hubble] | backup jobs → SMB NAS .144:445 [repo]; DNS | none |
| **hermes** | Gateway `ingress` → 9119 (hermes.lab.local dashboard); **no in-cluster inbound observed** [hubble: zero inbound to 9119 in sample; only egress replies + DNS] | Discord/Cloudflare 443, OpenAI 443, MS login 443 [hubble]; GitHub SSH 22 [repo]; Prometheus 9090 + zeus-metrics 9000 (Aetos, via terminal) [repo]; backup job → SMB .144:445 [repo]; DNS [hubble] | none — **this card's first policy** |
| **observability** (Prom, Grafana, Alertmanager, KSM, node-exporter, operator) | Gateway `ingress` → Grafana 3000 (grafana.lab.local); Grafana→Prom 9090 (same ns); **hermes (Aetos) → Prom 9090** [repo — cross-ns, must be in Prom's allow-list]; Prom→Alertmanager 9093 (same ns); host probes | Prometheus SCRAPES OUT to every ns (9000/8080/8086/9153/9962/…); Grafana→InfluxDB 8086; Alertmanager→notification targets; DNS | none |
| **argocd** (+ sealed-secrets) | Gateway `ingress` → argocd-server 8080 (argocd.lab.local); observability → metrics 8082/8083/8084/9001/8080(appset)/8081(sealed-secrets) [repo]; intra-ns: server/appset/controller → repo-server 8081, → redis 6379; kubeseal CLI → sealed-secrets 8080 (via API-server proxy / port-forward = host) [repo]; host probes [hubble] | GitHub 443/22 (repo pulls); K8s API (apiserver entity); DNS | none |
| **mqtt** | world+cluster → 1883 (LAN VIP .181: HA, LAN clients; in-cluster: zeus, cells); intra-ns EMQX clustering 4370/5370; cluster → dashboard 18083; host probes [hubble] | DNS; (EMQX otherwise self-contained) | **mqtt** (ingress-only, VALID=True) |
| **cert-manager** | kube-apiserver → webhook 10250/443 [repo — MUST use `fromEntities: [kube-apiserver]`]; observability → 9402 metrics [repo]; host probes | K8s API; ACME/issuers (lab CA only — no public egress needed); DNS | none |
| **kube-system — coredns (cluster DNS)** | ALL pods → 53 UDP/TCP; observability → 9153 metrics; host/node | upstream forwards: router .1:53 + coredns-lab (lab.local) | none — **LAST (with coredns-lab)** |
| **kube-system — coredns-lab (authoritative lab.local)** | LAN via VIP .180 → 53 UDP/TCP — arrives as `world` (and hairpin `remote-node`) [hubble]; DS918 .144 zone transfer AXFR 53/TCP (arrives as `world`) [repo/memory]; cluster pods + cluster CoreDNS forwards → 53; observability metrics | upstream router .1:53 [hubble] | none — **LAST, stop-the-line risk** |
| **kube-system — other** (cilium, hubble, csi-smb, metrics-server, local-path) | observability scrapes 9962/9963/9965; hubble-relay 4245/80 from hubble-ui + CLI; API-server → metrics-server 443 | host-level / cluster-internal | none — policing kube-system is out of scope until everything else is done |
| **chaos-mesh** | Gateway `ingress` → dashboard 2333 (chaos-mesh.lab.local); controller webhook ← kube-apiserver; intra-ns daemon 31767/31766 | K8s API; DNS | none — low priority, consider pausing/removing instead |
| **gateway** | (no pods — Gateway VIP is implemented by node-local Cilium Envoy) | n/a | nothing to police |
| **cilium-secrets / amarok-system / default / kube-public / kube-node-lease** | no workload pods | n/a | nothing to police |
| **longhorn / jaeger (incoming)** | being added by concurrent cards | — | **born policed in their own charts** — their CNPs ship with their PRs; do NOT add policies for them here |

Unverified/partially verified flows (marked [repo]) to Hubble-confirm before
each namespace's PR: zeus→EMQX/Influx/price (sample window showed only
HA+world flows), Prom scrapes of mqtt/jupiter-central (sample was
probe-dominated), DS918 AXFR (needs a longer observe window or a capture
during a zone change), kubeseal→sealed-secrets path.

## 3. Per-namespace policy plan & rationale

Pattern for every baseline PR (mirrors `landingzones/zeus`):

- `templates/ciliumnetworkpolicy.yaml` in the namespace's own chart,
  values-gated with `networkPolicy.enabled` so it can be disabled in ONE
  commit (flip the flag, no template surgery);
- ingress-only; one rule per peer class (never mix `fromEntities` +
  `fromEndpoints` — rule 4 above);
- namespace peers selected with
  `k8s:io.kubernetes.pod.namespace: <ns>` matchLabels;
- Gateway-exposed ports allowed with `fromEntities: [ingress]`.

Planned allow-lists (to be re-verified with Hubble at each PR):

1. **hermes** (THIS PR — see §4): `ingress` entity → 9119. Nothing else.
2. **jupiter-central + jupiter-tervuren FIX** (already-merged policies,
   VALID=False): split the combined `fromEntities`/`fromEndpoints` rule into
   two rules. No new scope — this makes the *intended* policy actually
   enforce. Verify VALID=True after.
3. **influxdb** (chart: `platform/influxdb-config`): 8086 from zeus,
   jupiter-central, jupiter-tervuren, observability (Prom scrape + Grafana),
   `ingress` entity (influxdb.lab.local — HA writes/reads from the LAN), and
   same-ns backup CronJob pods. High value (central telemetry), moderate
   risk — every writer is known and enumerable.
4. **observability**: Grafana 3000 from `ingress` entity; Prometheus 9090
   from Grafana (same ns) AND from hermes (Aetos PromQL); Alertmanager 9093
   from Prometheus; KSM/node-exporter/operator from Prometheus. NOTE:
   node-exporter is hostNetwork — scrapes appear host-to-host; keep its rule
   as `fromEntities: [host, remote-node]` or leave node-exporter unselected.
5. **argocd**: argocd-server 8080 from `ingress` entity; metrics ports from
   observability; repo-server 8081 + redis 6379 from argocd peers (same-ns
   `fromEndpoints`); sealed-secrets 8080 from cluster (kubeseal arrives via
   apiserver proxy/port-forward = host) + 8081 metrics from observability.
6. **cert-manager**: webhook from `fromEntities: [kube-apiserver]`; 9402
   from observability. A wrong webhook rule blocks ALL cert issuance —
   verify with a test Certificate after (dry-run first).
7. **mqtt**: already policed (#109). Revisit only in the egress phase.
8. **chaos-mesh**: dashboard 2333 from `ingress` entity; webhook from
   kube-apiserver; daemon ports intra-ns. (Or decide to retire chaos-mesh —
   cheaper than policing it.)
9. **zeus** (LAST-1, stop-the-line): ingress already done. The **egress
   lockdown** is the deferred item: DNS (rule 3), HA .18:8123, EMQX
   .181:1883 (toCIDR — LB VIP is off-cluster), InfluxDB 8086
   (toEndpoints), jupiter-central 8080 (toEndpoints), SMB .144:445 (toCIDR),
   ENTSO-E + Open-Meteo 443 (toFQDNs — requires DNS-proxy visibility, or
   pinned toCIDR as fallback). Ship OFF by default
   (`networkPolicy.egress.enabled=false`, exactly like jupiter-tervuren's
   prepared block), Hubble-audit ≥1 week, flip only with the owner watching
   the battery dashboard. **Rollback:** set
   `networkPolicy.egress.enabled=false` (one-line revert) → release; battery
   control restores on Argo sync; verify `zeus_control_available=1` and MQTT
   telemetry within minutes. Emergency (human): `kubectl delete cnp -n zeus zeus`.
10. **coredns-lab + cluster coredns** (LAST, stop-the-line): allow 53
    UDP+TCP from `world` (LAN via VIP .180 — includes DS918 AXFR; LB traffic
    arrives as world), `cluster`, `host`/`remote-node` (hairpin), 9153 from
    observability. **Never restrict 53 by source CIDR in the first pass**
    — the identity of LB-forwarded traffic varies with externalTrafficPolicy.
    Verify BEFORE merge with `helm template`; verify AFTER apply with `dig
    @192.168.50.180 <name>.lab.local` from the LAN, `dig` from a pod, an
    AXFR test from DS918, and HA→InfluxDB + price sensors still updating.
    **Rollback:** revert the release PR (Argo prunes the CNP on selfHeal) or
    human `kubectl delete cnp -n kube-system coredns-lab`; DS918 (.144,
    DNS2) keeps serving lab.local as slave while the primary is impaired —
    that is the designed fallback.
11. **kube-system others**: only after everything above has soaked.

## 4. First namespace: hermes (this PR) — why

- **Lowest blast radius.** No battery, no DNS, no telemetry pipeline
  touches hermes' INGRESS: Hubble shows zero in-cluster inbound to the pod;
  the only consumer is the human-facing hermes.lab.local dashboard through
  the gateway. Worst credible failure = dashboard 502 / Discord bot
  restart-loop — annoying, not dangerous, and invisible to zeus/HA/DNS.
- **Ingress surface is trivial**: one pod, one port (9119), one peer class
  (the gateway's `ingress` identity). Compare influxdb: 6+ distinct writers
  including LAN HA — a missed peer there silently drops telemetry writes.
- **Egress untouched**: hermes' heavy outbound (Discord, OpenAI, MS 365,
  GitHub, Prometheus queries, SMB backups) is unaffected by an ingress-only
  policy; replies flow through conntrack.
- Policy: `landingzones/hermes/templates/ciliumnetworkpolicy.yaml`, gated by
  `networkPolicy.enabled` (default `true`, disable = one-line values
  change). Allows `fromEntities: [ingress]` → `service.targetPort` (9119).
  Kubelet/host access is default-allowed (rule 6); the hermes deployment
  defines no probes today anyway.
- **Rollback:** set `networkPolicy.enabled: false` in
  `landingzones/hermes/values.yaml` (or revert the release PR) → Argo prunes
  the CNP. Verify: hermes.lab.local loads, Discord bot responds.

## 5. How to verify an allow-list with Hubble BEFORE a deny lands

The hubble CLI is not installed on the workstation; use a read-only exec
into the cilium-agent pod **on the node running the target pod** (each agent
only sees its node's flows):

```sh
# where is the pod?
kubectl get pod -n <ns> -o wide
# which agent is on that node?
kubectl get pod -n kube-system -l k8s-app=cilium -o wide
# observe real flows (read-only):
kubectl exec -n kube-system <cilium-agent-pod> -c cilium-agent -- \
  hubble observe --namespace <ns> --last 500
# after a policy is live, hunt for drops (must be empty):
kubectl exec -n kube-system <cilium-agent-pod> -c cilium-agent -- \
  hubble observe --namespace <ns> --verdict DROPPED --last 200
```

Procedure per namespace PR:

1. Sample flows across a representative window (include a backup-CronJob
   run, a scrape interval, and — for zeus/coredns — a price-fetch and a
   zone transfer). Repeat over several days for weekly jobs.
2. Write the allow-list from OBSERVED peers + repo-derived peers; mark
   anything unobserved as [repo] and say so in the PR.
3. `helm template` the chart and `kubectl apply --dry-run=client` the
   rendered CNP (schema check; server-side dry-run at release time).
4. After the release merges and Argo syncs: `kubectl get cnp -n <ns>`
   (**VALID must be True** — see rule 4), then the DROPPED hunt above, then
   the namespace's functional check (dashboard loads / telemetry rows fresh
   / dig answers).
5. Watch for 24h before starting the next namespace's PR.

## 6. Rollback (generic, per namespace)

Every policy in this program is a single values-gated template in the
namespace's own chart:

- **Soft disable (preferred):** `networkPolicy.enabled: false` in that
  chart's values → PR → release. Argo (prune+selfHeal) deletes the CNP.
  One-line, no template changes, easily reverted back.
- **Git revert:** revert the release merge on `master` (or the card PR on
  `develop` before release) — Argo prunes the CNP on the next sync.
- **Emergency (human-gated, live):** `kubectl delete cnp -n <ns> <name>`.
  Argo selfHeal will re-create it on the next sync unless the app is paused
  or the values flag is flipped — so always follow with the values change.
- Deleting a CNP restores the namespace to unpoliced (allow-all) — Cilium
  default-deny only exists while a policy selects the endpoint.

## 7. Staging order (one namespace per PR/release)

| # | PR | Namespace | Risk | Gate |
|---|----|-----------|------|------|
| 1 | this | hermes (ingress) | minimal | dashboard loads, bot responds |
| 2 | next | jupiter-central + jupiter-tervuren VALID=False fix (split rules; no new scope) | low — restores *intended* enforcement | `kubectl get cnp -A` all VALID=True; no DROPPED |
| 3 | | influxdb (ingress) | moderate | zeus/jupiter/HA writes land; Grafana reads OK |
| 4 | | observability (ingress) | moderate | dashboards load; Aetos PromQL works; alerts flow |
| 5 | | argocd (ingress) | moderate | argocd.lab.local loads; app syncs still work |
| 6 | | cert-manager (ingress) | moderate | test Certificate issues |
| 7 | | chaos-mesh (ingress) — or retire it | low | dashboard loads |
| 8 | | longhorn, jaeger | — | born policed in their own charts (concurrent cards — not this program's scope) |
| 9 | | zeus egress lockdown (opt-in flag flip) | **stop-the-line** | owner-attended; battery + savings metrics live; rollback note §3.9 |
| 10 | | coredns-lab (+ cluster coredns) ingress | **stop-the-line** | dig from LAN/pod/DS918 AXFR; HA→Influx alive; rollback note §3.10 |
| 11 | | kube-system remainder, egress phase for the rest | high | one ns at a time, same audit loop |

Never advance two steps in one release. If any gate fails: rollback per §6,
post-mortem in this doc, then retry.
