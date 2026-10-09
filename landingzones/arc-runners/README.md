# ARC: GitHub Actions runners from Harbor

Card #339, step 3/5 of the ARC + Harbor airgap POC. Step 2 (#338) mirrored the
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
| runner (`arc-runners`) | `harbor.lab.local/actions/actions-runner:2.338.0@sha256:4ffadc00…e807` |
| job pods (`arc-runners`) | whatever the workflow's `container:` says. **Must be a Harbor ref too** (a project of its own or the docker.io/ghcr.io proxy-cache projects from #337) to keep the airgap. |

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
- runner: 100m/256Mi request, 1 CPU/1Gi limit. **Job pods are not covered** by
  these; they get whatever the hook creates (no limits) unless #340 adds a hook
  template (see "Job pods" below) or the namespace gets a LimitRange.

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
- **Check on the first job:** Longhorn's CSI driver has
  `fsGroupPolicy: ReadWriteOnceWithFSType`, so `fsGroup` is NOT applied to RWX
  volumes. The runner (uid 1001) must still be able to write `/home/runner/_work`;
  whether the share-manager's export root allows that is **unverified** (no
  Longhorn RWX volume has been created on this cluster yet; #339 does no live
  mutations). If the job fails with a permission
  error on `_work`, add an init container that `chown`s the mount (or switch to
  `containerMode.type: kubernetes-novolume`).

## Name resolution

Controller, listener and runner talk to GitHub, not to Harbor. In kubernetes
mode, the **job pods** (and #340's image builds) pull from and push to
`harbor.lab.local`. Pods resolve it through cluster CoreDNS, which forwards
`lab.local`. As cheap insurance against the Go `*.local` resolver pitfall
(AGENTS.md), the runner pod template carries
`hostAliases: 192.168.50.200 harbor.lab.local` (the gateway VIP). **If the VIP
moves, update it here too.**

## Job pods (for #340)

The runner pod template does not reach the job pods: the container hook builds
those pod specs itself. To give job pods the same `hostAliases`, resources,
securityContext or the Harbor CA, #340 needs a hook template extension: a
ConfigMap with a pod-spec fragment, mounted into the runner, with
`ACTIONS_RUNNER_CONTAINER_HOOK_TEMPLATE=/path/to/template.yaml` in the runner env
(set it under `template.spec.containers[runner].env` in `.config/lab/arc-runners.yaml`).

Also note `ACTIONS_RUNNER_REQUIRE_JOB_CONTAINER=true` (chart default in
kubernetes mode): every job must declare a `container:`. A job without one fails.

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
cluster secret (never printed). It deploys with the scale set; #340 mounts it in
its build steps. **If the robot secret in `harbor-config` is rotated, re-seal
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

## Verification (2026-10-09, #339)

`helm template` of both Harbor charts with the lab values, `kubectl apply
--dry-run=server --server-side` against the live API (CRDs, controller objects,
StorageClass, runner-set RBAC, SealedSecret, the three Applications): all
accepted. The AutoscalingRunnerSet could not be server-dry-run because its CRD
is not installed yet; it validates clean against the CRD's openAPIV3Schema.
`grep ghcr.io` over every rendered manifest: none.
