# ARC: GitHub Actions runners from Harbor

Card #339, step 3/5 of the ARC + Harbor airgap POC; card #340 (step 4/5) added
the job-pod side: hook template, lab CA, kaniko image builds, the `ci-build`
job image and scan on push ("Job pods (#340)" below). Step 2 (#338) mirrored the
charts and images into Harbor ([docs/arc-mirror.md](../../docs/arc-mirror.md)).
This step installs actions-runner-controller (ARC, gha-runner-scale-set mode)
through Argo CD. **Charts and images come only from `harbor.lab.local/actions/`;
nothing is pulled from ghcr.io.**

| Piece | Argo app | Project | Namespace | Source | Values |
|---|---|---|---|---|---|
| Work-volume StorageClass | `arc-config` (wave 19) | platform-services | (cluster) | [`platform/arc-config`](../../platform/arc-config) | `.config/lab/arc-config.yaml` (optional) |
| Controller (CRDs, RBAC, Deployment; it also starts the listener pods) | `arc` (wave 20) | platform-services | `arc-systems` | Harbor chart `gha-runner-scale-set-controller` 0.15.0 | [`.config/lab/arc.yaml`](../../.config/lab/arc.yaml) |
| Runner scale set `arc-ceres` | `arc-runners` (wave 30), **gated** | landing-zones | `arc-runners` | Harbor chart `gha-runner-scale-set` 0.15.0 + this chart (SealedSecrets) | [`.config/lab/arc-runners.yaml`](../../.config/lab/arc-runners.yaml), [`.config/lab/arc-runners-config.yaml`](../../.config/lab/arc-runners-config.yaml) |

The Harbor chart repo is `repos.arc` in `.config/shared/values.yaml`
(`harbor.lab.local/actions/actions-runner-controller-charts`, `0.15.0`). The
Application templates are in [`applications/templates/arc/`](../../applications/templates/arc).

## Owner decisions (2026-10-09)

- **Scope:** one private repo, `https://github.com/jellebens/ceres`. Never attach
  these runners to a public repo: fork PRs would run code on the LAN.
- **Container mode: kubernetes.** No privileged pods. Each job's containers run
  as separate pods, created by the runner container hooks (shipped inside the
  runner image). The `_work` volume is shared by the runner pod and its job pods,
  so it is **ReadWriteMany**.
- **Auth: a GitHub App**, created by the owner (see below). Until then the scale
  set is not deployed at all.

## Images (pinned from `.scripts/arc-mirror/artifacts.lock`)

| Pod | Image |
|---|---|
| controller (`arc-systems`) | `harbor.lab.local/actions/gha-runner-scale-set-controller:0.15.0@sha256:162dfb5b…8d37` |
| listener (`arc-systems`, one per scale set) | same image: the chart passes `image.repository:image.tag` to the controller as `CONTROLLER_MANAGER_CONTAINER_IMAGE`, which it uses for listeners |
| runner (`arc-runners`) | `harbor.lab.local/actions/actions-runner:2.338.0@sha256:4ffadc00…e807` (stock, see "Why no custom runner image") |
| job pods (`arc-runners`) | whatever the workflow's `container:` says. **Must be a Harbor ref too** (a project of its own or the docker.io/ghcr.io proxy-cache projects from #337) to keep the airgap. Default: `harbor.lab.local/actions/ci-build:<ver>` (#340, "Job image") |
| image-build step pods (`arc-runners`) | `harbor.lab.local/actions/kaniko:v1.28.5@sha256:738807f0…8675` (#340, mirrored from the lock) |

The digest rides in the controller's `image.tag` field (`0.15.0@sha256:…`)
because the chart has no separate digest value. `actions` is a public Harbor
project, so there are no imagePullSecrets. The nodes trust the lab CA and pin
`harbor.lab.local` in `/etc/hosts` (homelab `roles/k3s`).

Bumping ARC or the runner: change `artifacts.lock` and re-mirror
([docs/arc-mirror.md](../../docs/arc-mirror.md) "Bumping"), then update the
digests in `.config/lab/arc.yaml` / `.config/lab/arc-runners.yaml` and
`repos.arc.targetRevision`. GitHub stops accepting old runner versions, so the
runner needs regular bumps.

## Sizing (CI must not starve jupiter or ceres)

- `minRunners: 0`, `maxRunners: 2`: no pods while idle, at most two jobs.
- controller: 25m/96Mi request, 500m/384Mi limit. listener: 10m/48Mi, 250m/128Mi.
- runner: 100m/256Mi request, 1 CPU/1Gi limit.
- job container and kaniko step pod (#340, hook template): 100m/256Mi/1Gi
  ephemeral-storage request, 2 CPU/2Gi/10Gi limit each. A job's job pod and its
  build step pod run at the same time (the job pod idles while kaniko builds),
  so the worst case is 2 jobs x (runner + job pod + step pod).

## Security context

Kyverno is audit-only, but the pods are set up sanely anyway: controller and
listener run as the image's distroless uid 65532, non-root, no privilege
escalation, all capabilities dropped, RuntimeDefault seccomp (the controller also
has a read-only root fs; `/tmp` is an emptyDir). The runner image's USER is the
name `runner`, which the kubelet cannot check against `runAsNonRoot`, so the
pod pins `runAsUser: 1001`. Nothing is privileged.

## Work volume (RWX)

Verdict from the #339 investigation: **Longhorn RWX works here without node
changes.**

- Longhorn reports `NFSClientInstalled=True` on all 6 nodes (nfs-common is
  installed by homelab, see [platform/longhorn/README.md](../../platform/longhorn/README.md)).
  `RequiredPackages=False` only lists `cryptsetup`, which is needed for
  encrypted volumes, not RWX.
- An RWX Longhorn volume is served by a `share-manager-<pvc>` pod in
  `longhorn-system` (NFSv4). The longhorn-system CiliumNetworkPolicy admits the
  `cluster` entity, which includes the nodes that mount it.
- The default `longhorn` class is **reclaimPolicy Retain**: every job would leave
  a Released PV and a Longhorn volume behind. Hence a dedicated class,
  `longhorn-arc-work` ([platform/arc-config](../../platform/arc-config)):
  reclaim **Delete**, **1 replica** (scratch data; no rebuild traffic on the
  1 GbE LAN), `dataLocality: best-effort`.
- Each runner gets a 4Gi generic ephemeral volume (`containerMode.kubernetesModeWorkVolumeClaim`),
  created with the pod and deleted with it. Expect a share-manager pod per
  running job, and a few seconds of extra start-up for the attach.
- **Permissions (#340).** Longhorn's CSI driver has
  `fsGroupPolicy: ReadWriteOnceWithFSType`, so `fsGroup` is NOT applied to RWX
  volumes, and a fresh volume's root is `root:root 0755`: the runner (uid 1001)
  could not write `/home/runner/_work`. The runner pod therefore has an init
  container `work-perms` (`.config/lab/arc-runners.yaml`): the runner image as
  uid 0 with only `CHOWN` + `FOWNER`, no privilege escalation, which runs
  `chown 1001:123` + `chmod 0775` on the volume root. Everything after that runs
  as 1001: the runner, the job container (ci-build is `USER 1001:123`), and the
  hook's copy of `externals` (`/__e`). The kaniko step pod runs as root and only
  reads the workspace, plus writes the digest file (root has `DAC_OVERRIDE`).
  This relies on the share-manager's NFS export **not squashing root**
  (Longhorn's Ganesha export is `no_root_squash`, unverified live: no Longhorn
  RWX volume existed before the first job). If it does squash, the init
  container logs `WARN: cannot chown the work volume` (non-fatal by design) and
  the runner fails on `_work`; the fallback is `containerMode.type: kubernetes-novolume`.
- The hook schedules job pods and step pods **on the runner's node**
  (`nodeName`, unless `ACTIONS_RUNNER_USE_KUBE_SCHEDULER=true`), so in practice
  all of a job's pods mount the volume from the same node.

## Name resolution

Controller, listener and runner talk to GitHub, not to Harbor. In kubernetes
mode, the **job pods** (and #340's image builds) pull from and push to
`harbor.lab.local`. Pods resolve it through cluster CoreDNS, which forwards
`lab.local`. As cheap insurance against the Go `*.local` resolver pitfall
(AGENTS.md), the runner pod template carries
`hostAliases: 192.168.50.200 harbor.lab.local` (the gateway VIP). **If the VIP
moves, update it here too.**

## Job pods (#340)

Card #340, step 4/5. In kubernetes mode the runner pod only orchestrates. For
every job the container hook (`/home/runner/k8s/index.js` in the runner image,
[actions/runner-container-hooks](https://github.com/actions/runner-container-hooks))
creates:

- a **job pod** `<runner>-workflow` from the job's `container:` image (command
  `tail -f /dev/null`); every `run:` step and every JavaScript action is `exec`'d
  into it;
- a **Kubernetes Job per container step** (`uses: docker://…`), a separate pod
  with the step's image, its own entrypoint/args and the workspace mounted at
  `/github/workspace`.

Both mount the runner's `work` volume (`/__w`; the job pod also `/__e` =
externals, `/github/home`, `/github/workflow`). `ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER=true`
(chart default in kubernetes mode): every job must declare a `container:`.

### The hook template

The runner pod template does not reach those pods. The hook's own extension
point does: `ACTIONS_RUNNER_CONTAINER_HOOK_TEMPLATE` (runner env, set in
`.config/lab/arc-runners.yaml`) points at `/home/runner/hook-template/template.yaml`,
mounted from ConfigMap `arc-ceres-hook-template`, rendered by this chart from
`values.yaml` `hookTemplate.template`. Read from the hook source (v0.7.x, in the
runner image): it is read at every job start, `spec.*` is merged into the job
pod **and** every step pod (lists append, other keys replace), and the container
`$job` is merged into the job container **and** the step container (both are
named `job`; env/volumeMounts append, the rest replaces). A container without
the `$` prefix would be added as a sidecar, so there is none.

What it gives every job pod and step pod:

| Field | Value | Why |
|---|---|---|
| `hostAliases` | `192.168.50.200 harbor.lab.local` | Go tools (kaniko) and the `*.local` resolver pitfall; same pin as the runner pod. **If the gateway VIP moves, update it here too.** |
| `securityContext` (pod) | `seccompProfile: RuntimeDefault` | No `runAsNonRoot` at pod level: the kaniko step must be uid 0 (below). |
| volume `harbor-ci-push` → `/kaniko/.docker/config.json` | the sealed `robot$ci+push` docker config | kaniko pushes with it (its default `DOCKER_CONFIG`); the job container can read it for Harbor API calls. `DOCKER_CONFIG=/kaniko/.docker` is set for both. |
| volume `lab-root-ca` → `/etc/lab-ca/ca.crt` | the lab root CA (ConfigMap from `.config/lab/arc-runners-config.yaml` `labCA`) | kaniko `--registry-certificate`, `curl --cacert`; images need not bake it in. `LAB_CA_FILE=/etc/lab-ca/ca.crt`. |
| `resources` | 100m/256Mi/1Gi eph. → 2 CPU/2Gi/10Gi eph. | kaniko unpacks and snapshots inside its own root fs. |
| `securityContext` (container) | no privilege escalation; drop ALL, add `CHOWN DAC_OVERRIDE FOWNER FSETID KILL SETGID SETUID SETFCAP SYS_CHROOT` | the minimum kaniko needs as root to unpack layers and run `RUN` steps (verified locally: `apk add`, `adduser`, `chown -R`, `su`). Nothing privileged, no `SYS_ADMIN`, no unconfined seccomp/AppArmor. A non-root job container gets none of these caps. |

Kyverno (audit-only) has `disallow-privileged-containers`, `disallow-host-namespaces`
and `disallow-latest-tag`; none of these pods trips them.

### Building images: kaniko in a step pod

Options evaluated for "build an image in an unprivileged pod on arm64":

| Builder | Unprivileged pod? | Verdict |
|---|---|---|
| **kaniko** ([osscontainertools/kaniko](https://github.com/osscontainertools/kaniko), maintained fork; GoogleContainerTools/kaniko is archived since 2025-06) | **Yes.** Runs as uid 0 *inside its own container* with ordinary capabilities, default seccomp, no user namespaces, no mounts: it unpacks the base image over its own root fs and runs `RUN` steps there. | **Picked.** arm64 image in the fork's index (v1.28.5). Pinned in `.scripts/arc-mirror/artifacts.lock`, mirrored to `harbor.lab.local/actions/kaniko`. |
| buildah (`--isolation chroot`, vfs) | Only partly: `RUN` steps need bind mounts (`CAP_SYS_ADMIN`) or a user namespace, and RuntimeDefault seccomp blocks `unshare(CLONE_NEWUSER)` without `SYS_ADMIN`. | Rejected: needs `SYS_ADMIN` or unconfined seccomp. |
| BuildKit rootless | Needs `seccomp=Unconfined` + `apparmor=unconfined` (rootlesskit user namespaces, mount/proc). Not privileged, but the two strongest pod guards off. | Rejected; not worth it for a POC; the owner decision was "no privileged pods". |
| docker / dind | Privileged pod. | Excluded by the owner decision. |

kaniko must run in **its own image** (it rewrites the root fs it runs in), so it
is not installed into the job image. It runs as a container step:

```yaml
- uses: docker://harbor.lab.local/actions/kaniko:v1.28.5@sha256:738807f0e31daf07743f89260a95956dcc6ee4f62553f4f6344c990cabab8675
  with:
    args: >-
      --context=dir:///github/workspace/<dir>
      --dockerfile=/github/workspace/<dir>/Dockerfile
      --destination=harbor.lab.local/ci/<repo>:${{ github.sha }}
      --registry-certificate=harbor.lab.local=/etc/lab-ca/ca.crt
      --digest-file=/github/workspace/.<repo>.digest
```

The build runs natively on the arm64 node (no QEMU), so the image is arm64;
`--custom-platform` is not needed. `FROM` lines use the Harbor proxy caches
(`harbor.lab.local/dockerhub/...`, `harbor.lab.local/ghcr/...`), pulled with
the same credential (both projects are public). kaniko ignores mounted paths
when it snapshots, so the workspace, the CA and the credential never end up in
the image. Only `robot$ci+push` is mounted, so builds can push to the `ci`
project and nowhere else.

### JavaScript actions (actions/checkout): no node in the job image

The hook copies the runner's `externals` (node20, node24 and their `_alpine`
variants) onto the work volume before the job pod starts and mounts them at
`/__e`. The runner then runs JS actions as `/__e/node24/bin/node …` inside the
job container. The hook checks `/etc/*release*` for `ID=alpine` and the runner
then picks the `_alpine` (musl) build; otherwise the glibc build. So the job
image needs **glibc + libstdc++ and `/bin/sh`, not node**. Verified locally:
the runner image's own `node20`/`node24` run in ci-build as uid 1001
(`build.sh smoke` with `EXTERNALS_DIR`). Container actions defined by a
Dockerfile (`runs.using: docker` + `image: Dockerfile`) are **not supported** by
the hook (`Building container actions is not currently supported`); prebuilt
`docker://` images are.

### Job image (`ci-build`)

[`.scripts/arc-images/ci-build/Dockerfile`](../../.scripts/arc-images/ci-build/Dockerfile),
version in `ci-build/VERSION`, pushed to `harbor.lab.local/actions/ci-build:<version>`
(project `actions`, public, so nodes pull it without a secret). Debian
trixie-slim from the dockerhub proxy cache, pinned by digest, plus git, curl,
jq, ca-certificates, libstdc++6, tar/gzip/xz; user `runner` 1001:123 (the
runner's ids, so both can write the work volume); `safe.directory '*'`. No CA,
no credentials, no node baked in (mounted at run time, see above).

```sh
# WSL, repo root. Build + quick checks (no push):
.scripts/arc-images/build.sh smoke ci-build
#   with the runner's node: EXTERNALS_DIR=<externals copied from the runner image>
# Build + push (robot$actions+push, secret read from harbor/harbor-actions-robot):
.scripts/arc-images/build.sh push ci-build      # prints <ref>@sha256:… to pin
```

Always `linux/arm64` + `--provenance=false`. On the amd64 workstation that needs
QEMU binfmt for the `RUN` steps; register it once per WSL boot with
`docker run --privileged --rm tonistiigi/binfmt --install arm64` (local, not the
cluster). `PLATFORM=linux/amd64 build.sh smoke ci-build` tests the Dockerfile
without emulation (`push` refuses non-arm64). The script pre-pulls the base
through the docker daemon, because BuildKit's own resolver may not trust the
lab CA.

### Adding a toolchain to the job image

Toolchains go into a job image, not the runner image (the runner never runs
steps in kubernetes mode).

1. Add it to `.scripts/arc-images/ci-build/Dockerfile` in the "toolchains"
   block, from the base distro (`apt-get install …`) or copied from a pinned
   image through the Harbor proxy cache:
   `COPY --from=harbor.lab.local/dockerhub/library/golang:1.25-trixie@sha256:… /usr/local/go /usr/local/go`
   plus `ENV PATH=/usr/local/go/bin:$PATH`. Always pin by digest; `FROM`/`COPY --from`
   must be `harbor.lab.local/...`.
2. Prefer a **separate image** (a new directory next to `ci-build`, e.g.
   `ci-python/`) when the toolchain is big or only one repo needs it; jobs
   pick it with `container:`. `build.sh` builds any directory with a Dockerfile
   and a `VERSION`.
3. Bump `VERSION` (minor for a new toolchain), `build.sh smoke`, then
   `build.sh push`, and point the workflows' `container: image:` at the printed
   `@sha256:` ref.
4. `setup-*` actions (`actions/setup-python`, …) download from the internet and
   do not work in an airgap; with the toolchain in the image, drop them.
   Package managers (pip, npm, go modules) still need a proxy/mirror inside the
   airgap (Harbor does not proxy those; out of scope for #340).

Bumping the base: pull the new tag through the proxy, take the index digest
(`docker buildx imagetools inspect docker.io/library/debian:trixie-slim`, it is
the same in Harbor), put it in `ARG BASE=`, bump `VERSION`, push.

### Why no custom runner image

The card was written for a runner that executes steps itself (container mode
none/dind), where `RUNNER_TOOL_CACHE` and the CA live in the runner image. In
kubernetes mode the runner image only runs the runner agent and the hook:

- toolchains in it would never be used (steps run in the job pod);
- the lab CA is not needed by the runner (it talks to GitHub, not Harbor);
- the stock image is what `artifacts.lock` pins by its upstream digest, so it
  keeps upstream's provenance and the mirror stays a byte-for-byte copy;
- one image less to rebuild on every runner release (GitHub retires old
  runner versions, so the runner gets bumped often).

So the runner stays stock; job images carry the tools.

### Image scanning

Harbor scans every push to project `ci` with Trivy (scan on push, `autoScan:
true` in [platform/harbor-config](../../platform/harbor-config/README.md)); the
CI robot can read the result (`artifact` read). The ceres smoke workflow polls
`GET /api/v2.0/projects/ci/repositories/<repo>/artifacts/<digest>?with_scan_overview=true`
and prints the summary. Not done: cosign signing (optional on the card).

### Smoke test (ceres `.github/workflows/arc-smoke.yml`)

Runs only on `workflow_dispatch` or a push to the branch `ci/arc-smoke` in
jellebens/ceres (never PRs, `develop`, `master` or tags). Job container ci-build;
checks the hook template landed (arch `aarch64`, `getent hosts harbor.lab.local`,
CA and docker config readable, workspace writable by 1001); `actions/checkout`;
kaniko builds `ci/arc-smoke/Dockerfile` (`FROM harbor.lab.local/dockerhub/library/alpine:3.22@sha256:…`,
a `RUN` that records `uname -m`) and pushes `harbor.lab.local/ci/arc-smoke:<sha>`;
then it reads the artifact back (architecture `arm64`) and waits for the Trivy
result (fails if there is none after 10 minutes).

Network: the job pod clones from github.com and the kaniko pod talks only to
Harbor. There is no NetworkPolicy yet (#341).

## Credentials

### GitHub App (owner, once): create, seal, enable the scale set

1. **Create the App** on github.com (Settings → Developer settings → GitHub
   Apps → New GitHub App), owned by `jellebens`:
   - Name: e.g. `jellebens-arc-lab`. Homepage URL: anything (e.g. the repo URL).
   - Webhook: **untick "Active"** (ARC polls; no webhook needed).
   - Repository permissions: **Administration: Read and write** (runner
     registration), **Metadata: Read-only** (mandatory). Nothing else.
   - "Where can this GitHub App be installed?": **Only on this account**.
   - Create it, note the **App ID** (top of the App's settings page).
2. **Generate a private key** (App settings → Private keys → Generate). A
   `.pem` downloads. Keep it out of the repo.
3. **Install the App** (App settings → Install App → `jellebens`) with
   **"Only select repositories" → `ceres`**. The URL afterwards is
   `https://github.com/settings/installations/<installation-id>`: that number
   is the **Installation ID**.
4. **Seal it** (WSL, repo root, on a card branch off `develop`; needs a kubectl
   context for the cluster):

   ```sh
   .scripts/seal-arc-github-app.sh ~/Downloads/<app>.private-key.pem
   # prompts for the App ID and the Installation ID
   ```

   It runs, per field, the equivalent of

   ```sh
   kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd \
     --namespace arc-runners --name arc-github-app --from-file=/dev/stdin
   ```

   and writes `githubApp.encryptedData` (`github_app_id`,
   `github_app_installation_id`, `github_app_private_key`) into
   `.config/lab/arc-runners-config.yaml`. Then delete the `.pem` (a new key can
   always be generated).
5. **Flip the gate**: in `.config/lab/apps.yaml` set

   ```yaml
   arc:
     runners:
       enabled: true
   ```

6. Commit both files, PR into `develop`, release. Once `master` has it, Argo
   creates the `arc-runners` Application: the SealedSecret
   (wave -1) becomes Secret `arc-runners/arc-github-app`, then the
   AutoscalingRunnerSet `arc-ceres` registers with GitHub and the controller
   starts the listener `arc-ceres-*-listener` in `arc-systems`.
7. **Check**: `kubectl -n arc-systems get pods` (controller + listener Running),
   `kubectl -n arc-runners get autoscalingrunnerset`, and the runner set
   `arc-ceres` under ceres → Settings → Actions → Runners. A workflow then uses
   `runs-on: arc-ceres` (with a `container:` from Harbor).

To rotate the key: generate a new one, re-run step 4, PR, release; delete the
old key on GitHub afterwards.

### Harbor push credential (for #340)

`harbor-ci-push` (type `kubernetes.io/dockerconfigjson`, key `.dockerconfigjson`)
is already sealed in `.config/lab/arc-runners-config.yaml`: `robot$ci+push`
(push + pull on the Harbor project `ci`) for `harbor.lab.local`. It is a copy of
`harbor/harbor-ci-robot` (key `secret`), sealed on 2026-10-09 straight from the
cluster secret (never printed). It deploys with the scale set; the #340 hook
template mounts it into every job pod and step pod as `/kaniko/.docker/config.json`.
**If the robot secret in `harbor-config` is rotated, re-seal
this copy too**: read `harbor/harbor-ci-robot` into a variable, build the
`{"auths":{"harbor.lab.local":{username,password,auth}}}` JSON with `jq`, and pipe
it to `kubeseal --raw … --namespace arc-runners --name harbor-ci-push`.

## Argo CD notes / what to watch on the first sync

- **`arc` is the first Argo CD chart pull from Harbor** (repo-creds
  `harbor-repo`, OCI, lab CA in `argocd-tls-certs-cm`). If the repo-server cannot
  resolve `harbor.lab.local`, the app shows a `ComparisonError`; the fix is a
  `hostAliases` pin on the repo-server (docs/arc-mirror.md "Still open").
- The ARC CRDs are 0.6–1.3 MB each: `ServerSideApply=true` is mandatory (a
  client-side apply fails on the 256 KiB annotation limit; verified in #339).
  Never untick it in the UI sync dialog (AGENTS.md pitfall).
- The controller does not copy `argocd.argoproj.io/instance` onto the objects it
  generates (`excludeLabelPropagationPrefixes`), so listeners, ephemeral runners
  and pods do not show up as stray members of the apps.
- The scale-set chart puts the finalizer `actions.github.com/cleanup-protection`
  on its Roles, RoleBindings and ServiceAccount. The controller removes them when
  the AutoscalingRunnerSet goes away; deleting the `arc-runners` app while the
  controller is down leaves them stuck.
- No NetworkPolicy yet: that is #341.

## Rollout (#340)

1. Merge the gitops and ceres PRs into `develop`, release gitops (`develop` →
   `master`). Argo then syncs `arc-runners` (ConfigMaps `arc-ceres-hook-template`
   and `lab-root-ca` at wave -1, then the AutoscalingRunnerSet with the init
   container, the hook-template mount and env; idle runners: none, min 0) and
   `harbor-config` (bootstrap: `ci` gets `auto_scan`, `robot$ci+push` gets
   `artifact` read; check with
   `kubectl -n harbor create job --from=cronjob/harbor-bootstrap harbor-bootstrap-now`).
2. Mirror kaniko: `HARBOR_CA_FILE=~/lab-root-ca.crt .scripts/arc-mirror/mirror.sh copy`
   then `verify` (only kaniko is new; the others are re-verified).
3. Push the job image: `docker run --privileged --rm tonistiigi/binfmt --install arm64`
   (once per WSL boot), then `.scripts/arc-images/build.sh push ci-build`.
4. Trigger the ceres smoke workflow (Actions → arc-smoke → Run workflow on
   `develop`, or push the branch `ci/arc-smoke`).

## Verification (2026-10-09, #340)

All offline or `--dry-run=server`; nothing was applied, pushed or triggered.

- `helm template` of this chart with the lab values: ConfigMaps
  `arc-ceres-hook-template` (template parses; pod keys `hostAliases`,
  `securityContext`, `volumes`, one `$job` container) and `lab-root-ca`
  (byte-identical to homelab `lab-root-ca.crt`), plus the two SealedSecrets.
- `helm template` of the Harbor `gha-runner-scale-set` 0.15.0 chart with
  `.config/lab/arc-runners.yaml`: init container `work-perms`, runner env
  `ACTIONS_RUNNER_CONTAINER_HOOK_TEMPLATE` next to the chart's three kube-mode
  vars, mounts `hook-template` + `work`, volumes `work` (ephemeral) +
  `hook-template`. Against the live object only `initContainers`, `containers`
  and `volumes` of the runner template change; `listenerTemplate` is identical.
- `kubectl apply --dry-run=server --server-side`: both ConfigMaps, both
  SealedSecrets, the AutoscalingRunnerSet, the harbor-bootstrap ConfigMap and
  CronJob. Also server dry-runs of a runner Pod from the rendered template, a
  job Pod and a kaniko step Job built the way the hook builds them (hook
  template merged): all accepted.
- Bootstrap `auto_scan`: offline test with a fake Harbor (adds it once,
  idempotent, leaves undeclared projects alone, create body, dry-run sends no
  mutation).
- ci-build: `PLATFORM=linux/amd64 build.sh smoke ci-build` with the runner
  image's own externals: uid 1001/gid 123, git 2.47.3, curl 8.14.1, jq 1.7,
  glibc 2.41, `/__e/node20/bin/node` v20.20.2 and `/__e/node24/bin/node`
  v24.21.0 run. The arm64 build needs QEMU binfmt, which this workstation had
  not registered at the time (`exec format error`); not registered by the agent.
- kaniko v1.28.5 locally (`--no-push`), as uid 0 with exactly the hook
  template's capability set, `no-new-privileges`, default seccomp, read-only
  workspace: built the ceres smoke Dockerfile from the Harbor proxy cache, and a
  Dockerfile with `apk add`, `adduser`, `chown -R`, `su`.
- `mirror.sh check`: kaniko tag matches the pin, index has linux/arm64.
- `shellcheck` (build.sh): clean.

## Verification (2026-10-09, #339)

`helm template` of both Harbor charts with the lab values, `kubectl apply
--dry-run=server --server-side` against the live API (CRDs, controller objects,
StorageClass, runner-set RBAC, SealedSecret, the three Applications): all
accepted. The AutoscalingRunnerSet could not be server-dry-run because its CRD
is not installed yet; it validates clean against the CRD's openAPIV3Schema.
`grep ghcr.io` over every rendered manifest: none.
