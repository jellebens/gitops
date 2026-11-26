# legion

Landing zone for **Legion** ([amarok-consulting/legion](https://github.com/amarok-consulting/legion)):
the praetor's view, the pages in which a praetor sees how the building of their
products stands.

**State: enabled.** The Argo CD Application `legion` is gated by
`legion.enabled` in `.config/lab/apps.yaml`, which is on, together with the
`legion-https` listener and the `legion` DNS record.

## What it deploys

The interface, legate (the API) and legate's PostgreSQL, at one version of
Legion (`interface.image.tag` and `legate.image.tag`, the tag `v<version>` in
the legion repository). The webhook receiver and NATS are designed in Legion's
HLD-LEG-002 and are not built; they get their own templates here when they are.

| Resource | Name | What |
|---|---|---|
| Namespace | `legion` | |
| Deployment | `legion-interface` | 2 replicas on separate worker nodes (required anti-affinity, and never the control-plane node), rolled one at a time. Static files and the interface's own Go file server on an empty base image. Runs as uid 65532, read-only root filesystem, no capabilities, no service-account token |
| PodDisruptionBudget | `legion-interface` | at least one instance during a drain |
| Service | `legion-interface` | ClusterIP, port 80 to the pages' port 8080. The probe port is not in it |
| HTTPRoute | `legion`, `legion-http-to-https` | `legion.lab.local` on the shared Cilium gateway; plain http redirects |
| Certificate | `legion-server-tls` | lab CA, for the `legion-https` listener |
| CiliumNetworkPolicy | `legion-interface` | ingress only: the gateway (`ingress` identity) to port 8080 |
| SealedSecret | `legion-harbor-pull` | the pods' pull credential: `robot$legion+pull` of Harbor, pull only, as a dockerconfigjson |

With `legate.enabled` and `postgres.enabled`, also:

| Resource | Name | What |
|---|---|---|
| Deployment, Service, PodDisruptionBudget, ConfigMap | `legion-legate` | 2 replicas on separate worker nodes, probes on 8081. The ConfigMap names the products and holds no credential |
| CiliumNetworkPolicy | `legion-legate` | ingress only: the gateway to port 8080. Egress is open, for GitHub and the database |
| Cluster (CloudNativePG) | `legion-pg` | PostgreSQL 18, 2 instances on Longhorn, database and role `legate`. The operator makes the secrets `legion-pg-app` and `legion-pg-ca` |
| SealedSecret | `legion-admin-token`, `legion-github-app`, `legion-github-app-key` | see [Secrets](#secrets) |

The rule `/api` on the HTTPRoute goes to legate, above the catch-all that goes
to the interface.

## Harbor accounts

Two robots of the Harbor project `legion`, declared in
[`platform/harbor-config`](../../platform/harbor-config/README.md), each with a
random secret that was sealed when it was generated:

| Robot | May | Used by |
|---|---|---|
| `robot$legion+push` | push and pull | whoever pushes Legion's images: by hand today |
| `robot$legion+pull` | pull | this landing zone, through `imagePullSecrets` |

They are two so that what the cluster pulls with cannot push. To push by hand:

```sh
kubectl -n harbor get secret harbor-legion-push-robot -o jsonpath='{.data.secret}' | base64 -d \
  | docker login harbor.lab.local -u 'robot$legion+push' --password-stdin
```

The pull robot's secret is sealed twice: for Harbor's bootstrap
(`.config/lab/harbor-config.yaml`, `legionPullRobot`) and, as a dockerconfigjson,
for this namespace (`.config/lab/legion.yaml`, `imagePullSecret`). Rotate the
two together.

**What you see once it runs:** the panel "Sign in", and after a sign-in with
GitHub the pages of every product you are an admin of, with the version of
Legion in the footer.

## Legate

Legate is the API the view reads from. Every call passes its gate, as the
operator (the admin token) or as a person signed in through Legion's GitHub
App. It names no product in its configuration: **a product is enlisted**, by
the person who is to be its praetor, and legate then reads its main branch on
GitHub as the app, live. What a deployment has to set is legion's
`legate/README.md`, "What a deployment has to set"; this chart sets all of it
but the admission of other people's fabrica images (`HARBOR_URL` and a
read-only Harbor account), which nothing needs yet.

**To enlist a product** (once for each, by its praetor): Legion's GitHub App
is installed on the product repository, the repository has a `legion.yaml`,
every image that names is on the list of admitted images, and the person is an
admin of the repository on GitHub. Then, with the `legion` tool from
`https://legion.lab.local/download/`:

```sh
export LEGION_URL=https://legion.lab.local
legion enlist <owner>/<repository>     # signs in by a code first, where needed
```

A refusal lists every fault of the manifest. Legion's own images get on the
list through `legate.images` (values, with their digests); the chart writes
them into legate's configuration and legate admits them at its start.

**`legate.caBundle`, off:** legate 0.2.0 and 0.3.0 had no certificate
authorities in their image and could not check GitHub's certificate; an init
container gave them a stock image's. Since 0.3.2 legate's image brings its own
and the switch is off. Turn it on only with a rollback to one of those two.

The chart refuses to render legate without its database or with one of its
three secrets unsealed. That is on purpose: Argo then reports a comparison
error and leaves the running view as it is, where a half-given legate would
replace it with a page on which nobody can sign in.

## Secrets

Three, all the owner's to make and seal. None of them is ever in git, in a
terminal's history or in an agent's session in the clear.

**1. Legion's GitHub App** (legion ADR-LEG-014). Register it once, on the
account that owns it, under Settings, Developer settings, GitHub Apps:

- Homepage URL `https://legion.lab.local`, callback URL
  `https://legion.lab.local/api/sign-in/callback`, exactly.
- "Expire user authorization tokens" off: legate ends each token itself and
  uses no refresh token.
- "Enable Device Flow" on (the `legion` tool signs in by a code).
- Webhook off for now: the receiver is not built.
- Repository permissions: Contents read and write, Pull requests read and
  write, Metadata read. No organisation permission.
- Then generate a client secret and a private key, and **install the app on
  amarok-consulting/legion**. A repository without the app is not read.

**2. The admin token.** On your own machine, `legion admin-token new`. The tool
is offered at `https://legion.lab.local/download/` once the interface runs;
before that, take it out of the interface's image:

```sh
id=$(docker create harbor.lab.local/legion/interface:<version>)
docker cp "$id":/site/download/legion-linux-amd64 ~/legion && docker rm "$id" && chmod +x ~/legion
```

Keep the token; only the digest it prints is sealed.

**3. Seal them**, in WSL at the repository's root, on a branch off `develop`:

```sh
.scripts/seal-legion-secrets.sh <path-to-app>.private-key.pem
```

It asks for the digest, the App's Client ID and its client secret (not shown
as you type), seals each for namespace `legion`, and writes
`legate.secrets.*.encryptedData` in `.config/lab/legion.yaml`. The Client ID
also serves as `app-id`. Delete the `.pem` afterwards. To replace a secret
later, run it again and release; legate reads the files as it needs them and
is not restarted.

The database has no secret of the owner's: CloudNativePG makes the role's
password and writes it to `legion-pg-app`.

## Releasing a version of Legion

1. In the legion repository, on its main branch: tag the commit `v<version>`
   and push the tag. The workflow `release` builds both images on the
   `arc-legion` runners and pushes them under the tag `<version>`; its
   summary names the digests. ([Image](#image) is the build by hand, for when
   the runners are away.)
2. Here, on a branch off `develop`: set `interface.image.tag` and
   `legate.image.tag` to `<version>`, and take over what the release notes of
   legion's `legate/README.md` ask of a deployment.
3. Release `develop` to `master`. Argo rolls both Deployments, one pod at a
   time.

The footer of every page shows the interface's version and, signed in,
legate's; they are the build argument, not the tag, so keep the two equal.

`avoidNodes` (in `.config/lab/legion.yaml`) keeps the pods off `k3s-node03`,
which cannot pull from Harbor at the moment. The chart keeps them off the
control-plane node already.

## Rules from Legion's own documents

- **Every image comes from Harbor** (ADR-LEG-016). Legion's own are in the
  project `legion`; base images of its builds come through `dockerhub`.
- **Cilium gateway with HTTPRoutes** (ADR-LEG-009/DEC-05). No Ingress object and
  no nginx.
- **On the trusted network only, encrypted** (ADR-LEG-009/DEC-04,
  PRD-LEG-002/REQ-12). The gateway VIP is LAN-only; do not publish this host
  name to the internet. Legion's webhook receiver, when it exists, gets a
  listener of its own (ADR-LEG-014/DEC-11) and is the only part that may be
  reached from outside.
- **Two or more instances on separate nodes** (PRD-LEG-002/REQ-16).

## Probes and stopping

The file server answers on two ports (legion `interface/README.md`):

| Port | Serves | Reached by |
|---|---|---|
| 8080 `http` | the pages; any address it does not know gets the entry page | the Service and the route |
| 8081 `probes` | `/livez` and `/readyz` | the kubelet only |

- **Live:** the process serves.
- **Ready:** it can read the entry page, and it has not been told to stop.
- **On SIGTERM:** `/readyz` is 503 at once, the pages are served for 5 s more
  (the drain), then calls under way get 10 s. `terminationGracePeriodSeconds`
  is 30; keep it above 15.

## Image

Built from the root of the legion repository, for arm64, with base images
through Harbor's `dockerhub` proxy cache:

```sh
V=0.4.0
docker build --platform linux/arm64 --provenance=false \
  --build-arg DOCKERHUB_PROXY=harbor.lab.local/dockerhub --build-arg VERSION=$V \
  -f interface/Dockerfile -t harbor.lab.local/legion/interface:$V .
docker build --platform linux/arm64 --provenance=false \
  --build-arg DOCKERHUB_PROXY=harbor.lab.local/dockerhub --build-arg VERSION=$V \
  -f legate/Dockerfile -t harbor.lab.local/legion/legate:$V legate
docker push harbor.lab.local/legion/interface:$V
docker push harbor.lab.local/legion/legate:$V
```

Without `VERSION` an image is built as `dev`, and its footer says so.

The build fails without `DOCKERHUB_PROXY`; it has no default on purpose. Docker
on the building machine must trust the lab CA
(`/etc/docker/certs.d/harbor.lab.local/ca.crt`, see
[`platform/harbor-config`](../../platform/harbor-config/README.md) "Using it").
The tags are `interface.image.tag` and `legate.image.tag` in
[`values.yaml`](values.yaml); a mutable tag such as `latest` is refused by
Kyverno.

The builder inside Docker Desktop does not trust the lab CA when it looks up a
base image, though `docker pull` does. Pull the two base images through Harbor
first, and build with Docker's own builder:

```sh
docker pull harbor.lab.local/dockerhub/library/node:24-alpine
docker pull harbor.lab.local/dockerhub/library/golang:1.27.4-alpine
docker --context=default buildx build --load ...   # the builds above
```

## Enable

In this order. Steps 3 to 5 are one PR.

1. **The Harbor project exists.** The project `legion` is declared in
   `platform/harbor-config/values.yaml` and created by the `harbor-bootstrap`
   CronJob once that change is released.
2. **The image is pushed** (see [Image](#image)), under the tag in `values.yaml`.
3. **Add the HTTPS listener** to `gateway.additionalHttpsListeners` in
   `.config/lab/gateway.yaml`:

   ```yaml
       # Legion: the praetor's view (landingzones/legion). The certificate is
       # emitted by the landing zone (lab-ca-issuer); this chart emits the
       # cross-namespace ReferenceGrant for it.
       - name: legion-https
         port: 443
         hostname: legion.lab.local
         tls:
           mode: Terminate
           certificateRefs:
             - group: ""
               kind: Secret
               name: legion-server-tls
               namespace: legion
   ```

   Not before the Application is enabled: the gateway chart writes a
   ReferenceGrant into the namespace `legion`, which does not exist until then.
4. **Add the DNS record** to the zone in `.config/lab/coredns-lab.yaml`, among
   the cluster services, **and bump the zone serial**:

   ```
       legion       IN A   192.168.50.200   ; Legion, the praetor's view - https via the legion-https listener
   ```

5. **Flip `legion.enabled` to `true`** in `.config/lab/apps.yaml`.
6. Release, then check:

   ```sh
   argocd app wait legion --core --sync --health --timeout 300
   kubectl -n legion get pods -o wide        # two pods, two nodes
   kubectl -n legion get httproute,certificate
   curl -sI https://legion.lab.local/        # 200, text/html
   ```

## Render

```sh
helm template legion ./landingzones/legion \
  -f .config/shared/values.yaml -f .config/lab/values.yaml -f .config/lab/legion.yaml
```

## Rollback

Set `legion.enabled` to `false`; Argo prunes the Application and, through its
finalizer, everything in the namespace. Remove the `legion-https` listener in
the same PR, or the gateway keeps a listener whose certificate is gone.
