# Harbor (container registry)

Harbor runs at **https://harbor.lab.local**. It serves the UI, the API and the OCI
registry (`/v2`) on that one host. It is installed by two Argo CD apps:

| App | Wave | Source | What it holds |
|---|---|---|---|
| `harbor-config` | 17 | this chart | the lab-CA cert `harbor-server-tls`, SealedSecrets `harbor-secrets` and `harbor-core-token`, the CNPG Cluster `harbor-pg` |
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
- **k3s nodes (pulling from Harbor):** this is **not done yet**, and it is a homelab
  (Ansible) concern, not gitops. containerd needs `/etc/rancher/k3s/registries.yaml`
  with a `configs."harbor.lab.local".tls.ca_file` that points at the lab CA, on every
  node, followed by a k3s restart. The nodes resolve `lab.local` names (AGENTS.md
  CNI/DNS pitfall). Until then, pods cannot pull from Harbor.
- **Pull secrets:** create a robot account per project in the UI and seal its
  `dockerconfigjson` into the namespace that pulls.

## Storage

All volumes are on Longhorn, which keeps 3 replicas: registry 50Gi, trivy 5Gi,
jobservice logs 1Gi, valkey 1Gi, and `harbor-pg` 5Gi. Raise the registry size in
place (Longhorn allows expansion). `updateStrategy: Recreate` is set because the
RWO volumes cannot attach to two pods during a rolling update. Longhorn gives
redundancy, not backup. There is no NAS backup of the registry or `harbor-pg` yet.

## Monitoring

`metrics.enabled` and a ServiceMonitor (`release: kube-prometheus-stack`) for core,
registry, jobservice and the exporter. `harbor-pg` has a CNPG PodMonitor.
