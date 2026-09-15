# gateway-config

The shared Cilium `Gateway` (`cilium-gateway`, ns `gateway`, LB VIP
`192.168.50.200`) and the platform `HTTPRoute`s / `ReferenceGrant`s that hang
off it. Values per environment in `.config/<env>/gateway.yaml` (`routes`,
`httpRedirects`, extra HTTPS listeners). Landing zones may ship their own
HTTPRoutes against the same Gateway (hermes does); the `http` listener admits
every namespace.

## Prerequisite that does NOT live here

The Gateway API CRDs. Argo CD comes up after the CNI, so they are applied by
the homelab Ansible role `roles/cilium` (`cilium_gateway_api_version`, pinned
together with `cilium_chart_version`) before the Cilium chart. If the bundle
is older than what the running Cilium requires, the operator's Gateway API
controller stays off and new routes are never programmed: empty
`.status`, 404 from Envoy, app `Progressing`. See AGENTS.md "Known Pitfalls".

## Adding a route

1. A record + zone serial bump in `.config/<env>/coredns-lab.yaml`.
2. An entry under `routes:` in `.config/<env>/gateway.yaml` (hostname,
   namespace, backend service + port). HTTPS needs its own listener and a
   lab-CA certificate per hostname; plain-http-only services must say so in
   their README (the GIGA firmware server is one, deliberately).
3. Check `kubectl -n <ns> get httproute <name>` shows `Accepted=True` before
   calling it done.
