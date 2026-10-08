# Runbook: mirror ARC into Harbor

Card #338, step 2/5 of the ARC + Harbor airgap POC. The goal is that the cluster
never pulls actions-runner-controller (ARC) from ghcr.io or Docker Hub. Every
chart and image ARC needs is copied into the Harbor project `actions`
(`harbor.lab.local/actions/…`), pinned by digest.

| File | What it is |
|---|---|
| [`.scripts/arc-mirror/artifacts.lock`](../.scripts/arc-mirror/artifacts.lock) | **The pins.** One line per artifact: source, tag, digest, Harbor path. #339 (the ARC install) must use exactly these refs. |
| [`.scripts/arc-mirror/mirror.sh`](../.scripts/arc-mirror/mirror.sh) | The mirror: `check`, `copy`, `export`, `import`, `verify`. |

Harbor itself: [`platform/harbor-config/README.md`](../platform/harbor-config/README.md).

## What is mirrored (pinned 2026-10-08)

ARC **0.15.0** (released 2026-10-01) and runner **2.338.0** (released 2026-10-06).

| Name | Upstream | Harbor | Digest |
|---|---|---|---|
| controller chart | `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set-controller` 0.15.0 | `oci://harbor.lab.local/actions/actions-runner-controller-charts/gha-runner-scale-set-controller` 0.15.0 | `sha256:20a36921…253a` |
| runner-set chart | `oci://ghcr.io/actions/actions-runner-controller-charts/gha-runner-scale-set` 0.15.0 | `oci://harbor.lab.local/actions/actions-runner-controller-charts/gha-runner-scale-set` 0.15.0 | `sha256:bdfdad17…87de` |
| controller image (also runs the listener pods) | `ghcr.io/actions/gha-runner-scale-set-controller:0.15.0` | `harbor.lab.local/actions/gha-runner-scale-set-controller:0.15.0` | `sha256:162dfb5b…8d37` |
| runner image | `ghcr.io/actions/actions-runner:2.338.0` | `harbor.lab.local/actions/actions-runner:2.338.0` | `sha256:4ffadc00…e807` |
| dind image (**optional**) | `docker.io/library/docker:29.8.2-dind` | `harbor.lab.local/actions/docker:29.8.2-dind` | `sha256:1e08cdb6…1ced` |

Full digests are in the lock file. All three images are multi-arch indexes that
contain `linux/arm64` (checked by `mirror.sh check`). The controller and runner
images have `linux/amd64` + `linux/arm64` plus build attestations. dind also has
`arm/v6` and `arm/v7`. A full mirror is about 1.0 GiB without dind and 1.5 GiB
with it (compressed, all platforms).

The charts live one level deeper (`actions-runner-controller-charts/…`) than the
images. That mirrors the upstream layout, and it is needed: the controller chart
and the controller image share a name and a tag (`gha-runner-scale-set-controller:0.15.0`),
so they cannot share a repository.

### The dind image is optional

ARC's runner set runs in one of three container modes: none, `dind`, or
`kubernetes`. Only `dind` needs `docker:dind`. Which mode we use is still an open
owner question on #339, so dind is marked `optional` in the lock. `mirror.sh`
skips it unless you pass `--include-optional`.

Note for #339: in chart 0.15.0 the dind container's image is **hard-coded** to
`docker:dind` (`_helpers.tpl`, `gha-runner-scale-set.dind-container`). Setting
`containerMode.type: dind` would therefore pull from Docker Hub. To use the
mirror, leave `containerMode` empty and write the dind pod spec out in
`template.spec` (the chart's `values.yaml` shows the full expanded spec), with
`image: harbor.lab.local/actions/docker:29.8.2-dind@sha256:…`. The same applies to
every `ghcr.io/actions/actions-runner:latest` in that example spec. `kubernetes`
mode needs no extra image (the container hooks ship inside the runner image),
but the job containers it starts come from the workflows, so they need Harbor
too (the docker.io/ghcr.io proxy-cache projects from #337).

## How it works, and why oras

The script uses [oras](https://oras.land) for everything. One tool copies both
images and Helm charts (a chart in an OCI registry is an artifact with config
type `application/vnd.cncf.helm.config.v1+json`). It also reads and writes OCI
image layouts, which gives us the airgap export/import for free.

- **Digests are kept.** `oras copy` without `--platform` copies the whole graph:
  the index, every platform manifest, every attestation, every blob, byte for
  byte. The index digest in Harbor is therefore **the same as upstream**, so the
  digest in the lock is valid on both sides and `image: …@sha256:…` works against
  Harbor. Copying only arm64 would have been about half the size, but then the
  copy is a new single-arch manifest with a different digest. Upstream signatures,
  provenance and SBOM attestations would no longer match. A mixed-arch cluster or
  an amd64 dev box could not use the mirror either. Harbor has 50Gi, so the extra
  space is cheap.
- **Pulls go by digest.** The source is always `<repo>@<digest>` from the lock,
  never the tag, so a moved upstream tag cannot slip in. `check` reports a moved
  tag as a WARN.
- **No `helm push`.** `helm push` repackages from a `.tgz` and would only cover
  charts. oras copies the chart's OCI manifest as-is, so the chart digest also
  matches upstream (`helm pull` prints it as `Digest:`).
- **No skopeo.** skopeo also keeps digests (`--all`), but it is images-only for
  practical purposes and is not installed on the workstation either.

## Prerequisites

- `bash`, `jq`, and **either** `oras` ≥ 1.2 on `PATH` **or** `docker`. Without
  oras, the script runs the pinned container
  `ghcr.io/oras-project/oras:v1.3.4@sha256:f7bc056d…` (`--network host`, your
  uid, only the needed paths bind-mounted). The workstation (WSL) has docker,
  not oras, so that is the default path there.
- The lab CA: `lab-root-ca.crt` at the repo root (gitignored, present in the main
  checkout). In a worktree, point `HARBOR_CA_FILE` at it.
- **Name resolution.** Go programs (oras, helm, containerd) may not resolve
  `*.local` names through DNS (AGENTS.md pitfall). The script therefore passes
  `--resolve harbor.lab.local:443:192.168.50.200` (the gateway VIP) by default.
  Override with `HARBOR_RESOLVE_IP`, or set it empty to use DNS. **If the gateway
  VIP moves, update the default in `mirror.sh` as well.**
- **The Harbor project `actions` must exist** (created declaratively by #337),
  plus an account that may push to it. Use a project robot account for `actions`
  with push + pull. Do not use `admin`.
- Credentials come only from the environment, never from a file in git:
  `HARBOR_USERNAME` + `HARBOR_PASSWORD` (written to a 0600 temp auth file that is
  deleted on exit, never on the command line), or `HARBOR_REGISTRY_CONFIG`
  pointing at an existing docker/oras auth file.

## Run it

All commands run from the repo root in WSL.

### 1. Check (read-only, run this first)

```sh
HARBOR_CA_FILE=~/repos/gitops/lab-root-ca.crt .scripts/arc-mirror/mirror.sh check --include-optional
```

It resolves every upstream tag, confirms the pinned digest exists, confirms that
each image index has `linux/arm64`, and prints sizes and the Harbor refs. It
writes nothing. It exits non-zero if an artifact is missing, is not multi-arch,
or lacks arm64.

### 2a. Lab path: copy straight into Harbor (needs internet)

```sh
export HARBOR_CA_FILE=~/repos/gitops/lab-root-ca.crt
export HARBOR_USERNAME='robot$actions+mirror'      # the actions push robot
read -rs HARBOR_PASSWORD && export HARBOR_PASSWORD  # paste, never in history
.scripts/arc-mirror/mirror.sh copy                  # add --include-optional for dind
unset HARBOR_PASSWORD
```

After each artifact, the script reads the tag back from Harbor and fails if the
digest differs from the lock.

### 2b. Airgap path: export, carry, import

On a machine with internet:

```sh
.scripts/arc-mirror/mirror.sh export /path/to/arc-bundle   # add --include-optional for dind
tar -C /path/to -cf arc-bundle.tar arc-bundle
```

The bundle contains `oci/<name>/`, one OCI image layout per artifact (tag =
upstream tag), plus copies of `artifacts.lock` and `mirror.sh`. The export reads
every layout back and fails if a digest differs from the lock. Also carry in
oras for the import side, or the oras image
(`docker save ghcr.io/oras-project/oras:v1.3.4 > oras.tar`), together with
`jq` if the target machine lacks it.

Inside the airgap:

```sh
tar -xf arc-bundle.tar
export HARBOR_CA_FILE=/path/to/lab-root-ca.crt HARBOR_USERNAME='robot$actions+mirror'
read -rs HARBOR_PASSWORD && export HARBOR_PASSWORD
arc-bundle/mirror.sh import arc-bundle --lock arc-bundle/artifacts.lock
unset HARBOR_PASSWORD
```

Before it pushes anything, `import` checks each layout's digest against the lock,
so a wrong or tampered bundle is refused.

### 3. Verify (read-only)

```sh
HARBOR_CA_FILE=~/repos/gitops/lab-root-ca.crt .scripts/arc-mirror/mirror.sh verify
```

This checks that each pinned tag in Harbor resolves to the pinned digest. If
`actions` is private, it needs pull credentials (the same env vars).

## Bumping ARC or the runner

1. Find the new release (ARC: `gha-runner-scale-set-<ver>` on
   github.com/actions/actions-runner-controller; runner: github.com/actions/runner).
   Chart, controller image and app version all share the ARC version number.
2. In `artifacts.lock`, change the tag and put any 64-zero placeholder in the
   digest column. Run `check`. It prints the upstream digest for the new tag
   under `tag` and fails on the placeholder. Paste that digest in and run
   `check` again until it is clean.
3. Commit the lock (Conventional Commit, e.g. `chore(arc): bump runner to 2.339.0`),
   then run `copy` (or `export`/`import`) and `verify`.

The runner image needs regular bumps. GitHub stops accepting runner versions
some time after a newer one is released, and ARC runners do not self-update.

## Can Argo CD pull the charts from Harbor?

**The repository config is in place. The lab CA still has to be trusted.**

- **`harbor-repo`** (`platform/argocd-config/templates/repos/harbor-repo.yaml`)
  is a credential template (`argocd.argoproj.io/secret-type: repo-creds`) for
  `harbor.lab.local` (`repos.harborRegistry.url` in `.config/shared/values.yaml`),
  with `type: helm` and `enableOCI: "true"`. Argo matches it by URL prefix, so it
  covers every chart path under the host. It carries no credentials, because the
  project Argo pulls from (`actions`) is public (#337). If one becomes private,
  add a sealed pull robot to this secret.
- **`harbor-runtime-repo`** is the old `harbor-repo`, renamed on 2026-10-08. It
  is the upstream goharbor chart repo `https://helm.goharbor.io`
  (`repos.harbor.url`), which the `harbor` app installs Harbor itself from. Argo
  matches repositories by URL, not by secret name, so the rename does not affect
  the `harbor` app.

Still open (checked read-only on 2026-10-08 against Argo CD v3.5.3):

1. **The lab CA is not trusted.** `argocd-tls-certs-cm` is empty, although the
   repo-server already mounts it at `tls-certs`. Without the CA, Helm in the
   repo-server rejects `https://harbor.lab.local`. The ConfigMap belongs to the
   out-of-band `argocd` Helm release (chart argo-cd 10.9.1), so add the CA through
   that release's values, not through a chart in this repo, or Helm and Argo will
   fight over the ConfigMap:
   ```yaml
   configs:
     tls:
       certificates:
         harbor.lab.local: |
           -----BEGIN CERTIFICATE-----
           …lab CA (lab-ca-issuer, platform/cert-manager-config)…
   ```
2. **Name resolution, likely fine but unverified.** The repo-server is
   `dnsPolicy: ClusterFirst` with no `hostAliases`. Cluster CoreDNS forwards
   `lab.local` (platform/coredns-config). The `*.local` Go-resolver pitfall bit
   containerd on the nodes, not pods. Confirm it on the first sync in #339. If it
   fails, add a `hostAliases` pin `192.168.50.200 harbor.lab.local` to the
   repo-server tuning patch, the same pin the nodes have.

The Application source is then `repoURL: harbor.lab.local/actions/actions-runner-controller-charts`,
`chart: gha-runner-scale-set-controller` (or `gha-runner-scale-set`),
`targetRevision: 0.15.0`. Images: `image.repository: harbor.lab.local/actions/gha-runner-scale-set-controller`
with the tag and digest from the lock. The nodes already trust the lab CA and pin
`harbor.lab.local` (homelab `roles/k3s`), so pulling images needs only an
`imagePullSecret` if `actions` is private.

## Verification log (2026-10-08, card #338)

- `shellcheck` v0.11.0: clean.
- `check --include-optional`: all 5 artifacts resolved. Every upstream tag
  matches its pinned digest, every image index has `linux/arm64`, and both charts
  are Helm artifacts.
- `export` of the 4 required artifacts to a scratch directory: 1016 MiB, all 4
  layout digests equal the lock. The directory was deleted afterwards.
- `export` → `import` → `verify` against a **throwaway local `registry:2`
  container** (not Harbor): digests preserved end to end. A tampered lock digest
  made `import` refuse before pushing.
- Nothing was pushed to Harbor. The project `actions` does not exist yet (#337).
