# Harbor (container registry)

Harbor runs at **https://harbor.lab.local**. It serves the UI, the API and the OCI
registry (`/v2`) on that one host. It is installed by two Argo CD apps:

| App | Wave | Source | What it holds |
|---|---|---|---|
| `harbor-config` | 17 | this chart | the lab-CA cert `harbor-server-tls`, SealedSecrets `harbor-secrets`, `harbor-core-token` and `harbor-ci-robot`, the CNPG Cluster `harbor-pg`, the `harbor-bootstrap` CronJob (projects, robots, retention, GC) |
| `harbor` | 18 | `goharbor/harbor` chart 1.19.2 (`.config/shared/values.yaml` `repos.harbor`) | core, portal, jobservice, registry, trivy, valkey, exporter, nginx |

Lab values: [`.config/lab/harbor.yaml`](../../.config/lab/harbor.yaml) (the chart) and
[`.config/lab/harbor-config.yaml`](../../.config/lab/harbor-config.yaml) (the sealed data).

## Nightly arm64 images (read this before upgrading)

Harbor's **release** images (v2.14.x, v2.15.x) are **amd64-only**. This cluster is
all arm64. The only official arm64 builds are the nightly `goharbor/*:dev-arm64`
tags, built from Harbor's `main` branch. We run those because the owner decided
to on 2026-10-08. What that means:

- **Every image is pinned by digest** (`dev-arm64@sha256:…`). The tag moves every
  night. The digest does not, so Argo never pulls a new build behind our back.
- **All digests must come from the same nightly.** Harbor's components talk to
  each other over internal APIs and DB migrations, so mixing builds from different
  nights can break things. The current set was pushed on 2026-10-08 at about 09:34Z.
- It is **unreleased `main` code**. Expect the occasional regression. Upgrading is
  a deliberate digest bump, and you roll back by reverting that commit. **But a
  database migration cannot be reverted**: back up `harbor-pg` before a bump that
  could carry one. Any bump might.
- The chart version (1.19.2) controls templates and values only. The app code is
  whatever the digests point at.
- **Redis is not a Harbor image.** `goharbor/redis-photon` has no arm64 build.
  `goharbor/valkey-photon` has one, but its jemalloc aborts on the Pi 5 kernel's
  16K pages (`Unsupported system page size`, first deploy 2026-10-08). We run the
  Docker official `valkey/valkey:8.1-alpine` instead, also pinned by digest. It
  writes to `/data` rather than the chart's PVC mount, so the cache and job queue
  are lost on a pod restart, which is harmless for Harbor. The upgrade loop below
  covers only the 8 goharbor images.

When goharbor ships multi-arch release images, switch every `tag:` to the
`vX.Y.Z` release that matches the chart's `appVersion`, and drop this section.

### Upgrading (digest bump)

```sh
for i in nginx-photon harbor-portal harbor-core harbor-jobservice registry-photon \
         harbor-registryctl trivy-adapter-photon harbor-exporter; do
  curl -s "https://hub.docker.com/v2/repositories/goharbor/$i/tags/dev-arm64" \
    | jq -r --arg i "$i" '$i + " " + .digest + " " + .last_updated'
done
```

Check that every `last_updated` is from the same night. Then replace all eight
digests in `.config/lab/harbor.yaml` in a single commit and release it.

## Secrets

Argo CD renders charts with `helm template`, which has no `lookup`. The Harbor
chart would therefore generate a new `secretKey`, core/jobservice/registry
secret, XSRF key, registry htpasswd and token-signing cert **on every sync**.
Sessions, tokens and the registry↔core handshake would break each time. So all of
them were generated once (random), sealed with kubeseal for namespace `harbor`,
and wired in through the chart's `existingSecret*` values. The key list is in
[`values.yaml`](values.yaml).

The DB password never passes through git. CNPG generates it and writes it to
`harbor-pg-app`, and Harbor reads it via `database.external.existingSecret`.

The **admin** login is user `admin`. Get the password from the cluster:

```sh
kubectl -n harbor get secret harbor-secrets -o jsonpath='{.data.HARBOR_ADMIN_PASSWORD}' | base64 -d
```

`HARBOR_ADMIN_PASSWORD` only seeds the first boot. After that, change the password
in the UI. Re-sealing the key does not change an existing admin password.
**Do not rotate `secretKey`**: Harbor encrypts stored credentials with it, such as
replication endpoints and robot secrets. Rotating `harbor-core-token` invalidates
outstanding tokens and is otherwise safe.

The token key **must be PKCS#1** (`-----BEGIN RSA PRIVATE KEY-----`). OpenSSL 3
writes PKCS#8 (`BEGIN PRIVATE KEY`) by default, and Harbor core rejects that at
token time with `unable to get PrivateKey from PEM type: PRIVATE KEY`. Every
`docker login`, push and pull then fails with a 500, although the UI, health and
API logins look fine. That happened on the first deploy. Convert with
`openssl rsa -in key.pem -traditional`. After re-sealing `harbor-core-token`, bump
`core.podAnnotations` `harbor.lab.local/core-token-rev` in `.config/lab/harbor.yaml`,
because core only reads the key at start.

To re-seal one value:

```sh
printf '%s' "<value>" | kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd \
  --namespace harbor --name harbor-secrets --from-file=/dev/stdin
```

## Exposure

- The shared Cilium gateway has a dedicated `harbor-https` listener with a lab-CA
  cert from this chart. Plain `http://harbor.lab.local` gets a 302 to https
  (`httpRedirects` in `.config/lab/gateway.yaml`). DNS is the `harbor` A record in
  `.config/lab/coredns-lab.yaml`, pointing at the VIP `.200`.
- The route has `timeouts.request: 0s`. A layer upload is one long request, and
  Envoy's default route timeout would cut big pushes.
- TLS ends at the gateway. Harbor's own nginx (`svc/harbor:80`) serves plain HTTP
  inside the cluster. `externalURL` is `https://harbor.lab.local`, so the token
  realm that clients get back is the https one.

## Using it

The cert comes from the **lab CA** ([`lab-root-ca.crt`](../../lab-root-ca.crt)), so
clients must trust that CA:

- **Docker on a workstation:** put the CA at
  `/etc/docker/certs.d/harbor.lab.local/ca.crt`, then run `docker login harbor.lab.local`.
  Images for this cluster are still built with `--platform linux/arm64 --provenance=false`.
- **k3s nodes (pulling from Harbor):** done since 2026-10-08 by homelab
  `roles/k3s` (`--tags registries`, jellebens/homelab#4; see that role's README).
  Every node has the lab CA at `/etc/rancher/k3s/lab-root-ca.crt`, a
  `registries.yaml` that trusts it for `harbor.lab.local`, and an `/etc/hosts` pin
  `192.168.50.200 harbor.lab.local`. The pin is required: containerd's Go resolver
  never sends `*.local` names to DNS (AGENTS.md pitfall). **If the gateway VIP ever
  moves, update `k3s_private_registries` in homelab and rerun**, or every node loses
  Harbor. A pod can use `image: harbor.lab.local/<project>/<repo>:<tag>`. Public
  projects such as `library` need no pull secret.
- **Pull secrets:** declare a robot account per project in `bootstrap.robots`
  (below), and seal its `dockerconfigjson` into the namespace that pulls.

## Projects, robots and retention (declarative, card #337)

Projects, registry endpoints, robots, retention policies and the GC schedule live
in Harbor's database. The Harbor API is the only way to write them, and before
#337 they were made by hand in the UI. At an airgapped site that state could not
be rebuilt from git. The **`harbor-bootstrap` CronJob** now reconciles them from
`bootstrap` in [`values.yaml`](values.yaml). The script is
[`files/harbor-bootstrap.py`](files/harbor-bootstrap.py) (stdlib Python, shipped in a
ConfigMap) and the manifest is [`templates/bootstrap.yaml`](templates/bootstrap.yaml).

| Project | Kind | Public | Quota | Retention (runs 23:00) | Purpose |
|---|---|---|---|---|---|
| `dockerhub` | proxy cache of registry `docker-hub` (`https://hub.docker.com`) | yes | 14Gi | keep what was pulled in the last 14 days | `harbor.lab.local/dockerhub/library/alpine:3.20` = `docker.io/library/alpine:3.20` |
| `ghcr` | proxy cache of registry `ghcr` (`https://ghcr.io`) | yes | 10Gi | keep what was pulled in the last 14 days | `harbor.lab.local/ghcr/actions/actions-runner:<tag>` |
| `actions` | normal | yes | 8Gi | keep the 5 most recently pushed per repository | ARC controller/runner images and the ARC Helm charts (OCI) |
| `ci` | normal | no | 12Gi | keep the 10 most recently pushed per repository | images built by the runners |

Robot **`robot$ci+push`** (project robot on `ci`: `repository` push + pull, never
expires). GC runs daily at 00:00 with `delete_untagged`, one worker.

**How it behaves**
- Every 30 minutes (`bootstrap.schedule`), each declared object is read first. It
  is created when missing, and updated when it differs from git. Changes made in
  the UI to declared objects are reverted on the next run. The job **never
  deletes** anything and ignores undeclared objects (the hand-made `library`,
  `jupiter` and `ceres` projects are left alone).
- A **CronJob, not an Argo sync hook**, for the same reason as `influxdb-buckets`:
  this chart syncs at wave 17, before the harbor chart (wave 18) exists on a fresh
  cluster. A hook would fail there and hold the bootstrap. If Harbor does not
  answer `/api/v2.0/ping` after about 5 minutes of retries, the run logs that and
  exits 0, and the next run tries again. Any other error (a 4xx/5xx from the API, a
  wrong admin password) fails the job.
- Apply a change right away instead of waiting for the next run:
  `kubectl -n harbor create job --from=cronjob/harbor-bootstrap harbor-bootstrap-now`,
  then `kubectl -n harbor logs -f job/harbor-bootstrap-now`.
- **Preview first:** set `bootstrap.dryRun: true` (or run the script locally with
  `DRY_RUN=true`). In dry-run the script only issues GETs; a guard in the HTTP
  layer refuses every other method. It logs `DRY-RUN would …` for each change.
- Things Harbor cannot change in place are reported, not forced: a registry
  endpoint's `type`, and the upstream of a proxy-cache project. Fix those by
  deleting the object in the UI; the next run recreates it.

**Admin credential.** Creating projects, registries and robots needs a system
admin, and Harbor has no narrower API credential that can do all of it (a robot
cannot create robots with more rights than it has). So the job logs in as
`admin` with `harbor-secrets` / `HARBOR_ADMIN_PASSWORD`. That key only seeds the
first boot. **If the admin password is changed in the UI, the job fails** with
`admin login failed (401)`. Then either change it back, or re-seal the new
password into `HARBOR_ADMIN_PASSWORD` (see Secrets).

**The robot secret** is generated by us, not by Harbor, so it can live in git. A
random 40-character value (Harbor requires 8-128 chars with an upper, a lower and
a digit) is sealed as SealedSecret `harbor-ci-robot` (key `secret`) in
`.config/lab/harbor-config.yaml`. The job creates the robot with that secret, and
on every run it checks it by logging in at `/v2/` (200 = valid, 401 = wrong). Only
on a 401 does it set the secret again (`PATCH /api/v2.0/robots/{id}`). The API
endpoints and `/service/token` fall back to anonymous on bad credentials, so they
cannot be used for that check. To rotate the secret, re-seal a new value under the
same name; the next run applies it. Read it back with
`kubectl -n harbor get secret harbor-ci-robot -o jsonpath='{.data.secret}' | base64 -d`.
ARC (#339) needs this credential in its runner namespace: seal a **separate copy**
for that namespace (a SealedSecret only decrypts in the namespace it was sealed
for), as `dockerconfigjson` for `harbor.lab.local` with user `robot$ci+push`.

**Storage budget.** The registry PVC is 50Gi on Longhorn. The quotas add up to
44Gi, so a full proxy cache gets push/pull errors on its own project instead of
filling the volume for everyone. Retention runs at 23:00 and GC at 00:00 (Harbor
crons have six fields, seconds first). Both stay clear of the 04:00 DB dump and
the 04:30 Longhorn layer backup, whether Harbor reads the cron as UTC or local
time. GC must never run between those two backups, or the dump would point at
layers that the volume backup no longer has. Retention marks artifacts deleted;
only GC frees their blobs. Raise a quota or shorten a retention when the PVC gets
tight. Usage per project is under Projects > Summary in the UI, or `GET /api/v2.0/quotas`.

**Proxy cache notes**
- **Docker Hub rate limits anonymous pulls** per source IP (the whole LAN shares
  one public IP). The `docker-hub` endpoint has no credential for now. If pulls
  start failing with `429 Too Many Requests`, add a Docker Hub account as the
  endpoint credential. Seal it, and extend the script to send `credential`.
- Docker Hub official images live under `library/`: pull
  `harbor.lab.local/dockerhub/library/<image>`, not `dockerhub/<image>`.
- Harbor runs **nightly `dev-arm64` builds**. If proxy caching or replication
  misbehaves, suspect Harbor first, before ARC.
- Valkey has no persistence (see above). A Harbor restart loses in-flight
  jobservice jobs (replication, retention, GC, scans). Re-run them from the UI, or
  wait for the next schedule.

## Storage

All volumes are on Longhorn, which keeps 3 replicas: registry 50Gi, trivy 5Gi,
jobservice logs 1Gi, valkey 1Gi, and `harbor-pg` 5Gi. Raise the registry size in
place (Longhorn allows expansion). `updateStrategy: Recreate` is set because the
RWO volumes cannot attach to two pods during a rolling update. Longhorn gives
redundancy, not backup. The backups are below.

## Backups

| What | How | When | Kept | Where |
|---|---|---|---|---|
| Database (`harbor-pg`: projects, users, robots, tags, scans, settings) | CronJob `harbor-db-backup`: `pg_dump -Fc` (`templates/postgres-backup.yaml`) | 04:00 daily | 30 days | NAS `smb` StorageClass, PVC `harbor-db-backups`, files `harbor-registry-<ts>.dump` |
| Image layers (PVC `harbor-registry`) | Longhorn backup, group `nas-daily` (platform/longhorn) | 04:30 daily, after the dump | see platform/longhorn | Longhorn backup target on the NAS |

The database is dumped **before** the layers are backed up. A restored database
therefore never points at layers the volume backup lacks. Extra layers are
harmless: Harbor's garbage collection removes them.

Alerts: `BackupNotSucceeded` (platform/observability-config) fires when
`harbor-db-backup` has not succeeded for 26h. `LonghornBackupFailed` and
`LonghornBackupStale` (platform/longhorn) cover the layer backup.

Before a nightly digest bump (a possible DB migration), take a fresh dump by hand:

```sh
kubectl -n harbor create job --from=cronjob/harbor-db-backup harbor-db-backup-manual-$(date +%s)
```

### Restore tests

| Date | Database (`pg_dump`) | Image layers (Longhorn) |
|---|---|---|
| 2026-10-08 | Dump `harbor-registry-20261008-170758.dump` restored into a scratch Postgres (`pg_restore --exit-on-error`, no errors). All 49 tables and 75 rows equal live `harbor-pg`. | Backup `backup-df5e91aaaa5e472b` restored into a 1-replica scratch volume in 23 s, mounted read-only. All 6 blobs hash to their digest, and the digest+size set equals the live registry. |

Harbor was nearly empty at the time (3 projects, 2 users, no images), so this
proves the mechanics, not restore time at scale. Repeat the test after Harbor
holds real images. To repeat it without touching live state:
- **Database:** restore the newest dump into a throwaway pod that runs its own
  `initdb`/`pg_ctl` against an `emptyDir`.
- **Layers:** create a Longhorn `Volume` with `spec.fromBackup: <backup url>` and
  `numberOfReplicas: 1`, then add a static PV/PVC (`longhorn-static`) in a scratch
  namespace. Check every `blobs/sha256/*/*/data` with `sha256sum` against its
  directory name. Delete the volume afterwards.

### Restore the database

1. Scale Harbor down so nothing writes:
   `kubectl -n harbor scale deploy harbor-core harbor-jobservice harbor-exporter --replicas=0`.
   Argo self-heals the replica count back, so pause auto-sync on the `harbor` app
   first: `argocd app set harbor --core --sync-policy none`.
2. Find the dump. Its directory on the NAS share is `harbor-harbor-db-backups-<pv>`,
   or mount the PVC in a debug pod.
3. Restore it into the live cluster from a pod that mounts `harbor-db-backups` and
   has `PG_URI` from `harbor-pg-app`:
   `pg_restore --clean --if-exists --no-owner -d "$PG_URI" /backup/harbor-registry-<ts>.dump`.
4. Turn auto-sync back on (`argocd app set harbor --core --sync-policy automated --auto-prune --self-heal`)
   and let Argo bring the deployments back.

## Monitoring

`metrics.enabled` and a ServiceMonitor (`release: kube-prometheus-stack`) for core,
registry, jobservice and the exporter. `harbor-pg` has a CNPG PodMonitor.
