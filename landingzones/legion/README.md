# legion

Landing zone for **Legion** ([amarok-consulting/legion](https://github.com/amarok-consulting/legion)):
the praetor's view, the pages in which a praetor sees how the building of their
products stands.

**State: enabled.** The Argo CD Application `legion` is gated by
`legion.enabled` in `.config/lab/apps.yaml`, which is on, together with the
`legion-https` listener and the `legion` DNS record. It reaches the cluster with
the release that carries that change. The pods wait in ImagePullBackOff until
the image is in Harbor ([Image](#image)).

## What it deploys

Only the interface exists so far. Legate (the API), the webhook receiver, NATS
and PostgreSQL are designed in Legion's HLD-LEG-002 and HLD-LEG-003 and are not
built; they get their own templates here when they are.

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

It holds no state, and one secret: the pull credential.

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

**What you see once it runs:** the frame of each page and the line "This page
may be out of date". Nothing answers `/api` until legate is deployed, so no page
has data. That is the state of Legion's first increment, not a fault here. What
this deployment does prove is the image, the probes, the gateway route, the
certificate and Harbor, end to end.

## Legate, and its two interims

`legate.enabled` adds legate, the API the view reads from (legion TSK-14): a
Deployment `legion-legate` (2 replicas on separate worker nodes, probes on
8081), a ConfigMap with its configuration, a Service, a PodDisruptionBudget, a
CiliumNetworkPolicy, and the rule `/api` on the HTTPRoute, above the catch-all
that goes to the interface. With it the pages show Legion's own documents and
backlog.

Two things about it are interim, both the owner's decisions of 2026-11-23:

- **No sign-in.** Anyone on the LAN who opens `legion.lab.local` reads Legion's
  documents and backlog. Legion's own requirement is a credential on every call
  (PRD-LEG-005/REQ-01); authentication is not designed yet. Legate has no call
  that writes. It goes when Legion has its sign-in.
- **A snapshot, not GitHub.** Legate reads a folder until it can read the main
  branch on GitHub (legion TSK-15, which waits for Legion's GitHub App). The
  image `legate-snapshot` is legate with Legion's `docs/` at one commit in it
  ([`snapshot/Dockerfile`](snapshot/Dockerfile)). The view is frozen at that
  commit, which every page names, and nothing on it is live: the event stream
  is not built, so a page also says that it may be out of date.

To move the snapshot to a newer commit of legion: build `legate` (if it
changed) and then `legate-snapshot` from the root of the legion repository at
that commit, push both with `robot$legion+push`, and bump `legate.image.tag`
and `legate.snapshot.commit` together.

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
docker build --platform linux/arm64 --provenance=false \
  --build-arg DOCKERHUB_PROXY=harbor.lab.local/dockerhub \
  -f interface/Dockerfile \
  -t harbor.lab.local/legion/interface:0.1.0 .
docker push harbor.lab.local/legion/interface:0.1.0
```

The build fails without `DOCKERHUB_PROXY`; it has no default on purpose. Docker
on the building machine must trust the lab CA
(`/etc/docker/certs.d/harbor.lab.local/ca.crt`, see
[`platform/harbor-config`](../../platform/harbor-config/README.md) "Using it").
The tag is `interface.image.tag` in [`values.yaml`](values.yaml); a mutable tag
such as `latest` is refused by Kyverno.

The builder inside Docker Desktop does not trust the lab CA when it looks up a
base image, though `docker pull` does. Pull the two base images through Harbor
first, and build with Docker's own builder:

```sh
docker pull harbor.lab.local/dockerhub/library/node:24-alpine
docker pull harbor.lab.local/dockerhub/library/golang:1.27.4-alpine
docker buildx build --builder default --load ...   # the build above
```

Built that way on 2026-11-23 for `linux/arm64`. It has not been pushed and has
never run on arm64.

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
