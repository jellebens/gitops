# arc-config

Cluster-scoped prerequisites for ARC (#339), deployed by the Argo app
`arc-config` (project platform-services, wave 19). They live here rather than in
the [`arc-runners`](../../landingzones/arc-runners) landing zone because the
`landing-zones` AppProject only allows Namespaces at cluster scope.

| Object | Why |
|---|---|
| StorageClass `longhorn-arc-work` | Longhorn RWX class for the kubernetes-mode runner work volumes: reclaim **Delete** (the default `longhorn` class is Retain, which would leak one volume per job), 1 replica, `dataLocality: best-effort`. |

Values: [`values.yaml`](values.yaml), lab overrides in
`.config/lab/arc-config.yaml` (optional, not present). The full ARC write-up,
including the RWX verdict, is in
[landingzones/arc-runners/README.md](../../landingzones/arc-runners/README.md).
