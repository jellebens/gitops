# legion

Landing zone for **Legion** ([amarok-consulting/legion](https://github.com/amarok-consulting/legion)):
the praetor's view, the pages in which a praetor sees how the building of their
products stands.

**State: drafted, not enabled.** The Argo CD Application `legion` is gated by
`legion.enabled` in `.config/lab/apps.yaml` and is off. Nothing of this chart is
in the cluster until the steps under [Enable](#enable) are done.

## What it deploys

Only the interface exists so far. Legate (the API), the webhook receiver, NATS
and PostgreSQL are designed in Legion's HLD-LEG-002 and HLD-LEG-003 and are not
built; they get their own templates here when they are.

| Resource | Name | What |
|---|---|---|
| Namespace | `legion` | |
| Deployment | `legion-interface` | 2 replicas on separate nodes (required anti-affinity), rolled one at a time. Static files and the interface's own Go file server on an empty base image. Runs as uid 65532, read-only root filesystem, no capabilities, no service-account token |
| PodDisruptionBudget | `legion-interface` | at least one instance during a drain |
| Service | `legion-interface` | ClusterIP, port 80 to the pages' port 8080. The probe port is not in it |
| HTTPRoute | `legion`, `legion-http-to-https` | `legion.lab.local` on the shared Cilium gateway; plain http redirects |
| Certificate | `legion-server-tls` | lab CA, for the `legion-https` listener |
| CiliumNetworkPolicy | `legion-interface` | ingress only: the gateway (`ingress` identity) to port 8080 |

It holds no secret and no state.

**What you see once it runs:** the frame of each page and the line "This page
may be out of date". Nothing answers `/api` until legate is deployed, so no page
has data. That is the state of Legion's first increment, not a fault here. What
this deployment does prove is the image, the probes, the gateway route, the
certificate and Harbor, end to end.

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

As of this draft: no image has been pushed, no build has gone through Harbor,
and the arm64 image has never run.

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
