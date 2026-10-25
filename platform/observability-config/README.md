# observability-config — local config next to kube-prometheus-stack

The upstream chart `kube-prometheus-stack` (pin `repos.prometheus.targetRevision` in
`.config/shared/values.yaml`, values in `.config/lab/observability.yaml`) is the
`observability` Argo app: prometheus-operator, Prometheus, Alertmanager, Grafana,
kube-state-metrics, node-exporter. This chart (`observability-config`, synced after
it) holds what the stack needs from us: the Grafana admin secret, the statically
mounted datasource files (InfluxDB, Jaeger, Annona and jupiter PostgreSQL — see the
comments in `.config/lab/observability.yaml` on why not the sidecar), the sealed
datasource passwords, the lab-CA certificate for the gateway's HTTPS listener and
the backup PrometheusRule. Dashboards live next to the thing they show
(`landingzones/*/dashboards`, `platform/*/dashboards`) and reach Grafana through the
sidecar (`grafana_folder` annotation).

`appVersion` tracks the kube-prometheus-stack chart version this config is for.

## Upgrading kube-prometheus-stack (procedure of record since #352, 82.18.0 -> 92.11.0, 2026-10-24)

1. Survey: `helm search repo prometheus-community/kube-prometheus-stack --versions`
   and the chart's `UPGRADE.md`, one entry per major. A **major is a CRD update**
   (prometheus-operator CRDs) and sometimes a Grafana major.
2. Render the new version with our values, **with the CRDs**: the `crds` subchart
   ships them in a `crds/` dir that plain `helm template` skips.

   ```sh
   helm template kube-prometheus-stack prometheus-community/kube-prometheus-stack \
     --version <new> -n observability -f .config/lab/observability.yaml --include-crds
   ```

   Diff images and CRD sizes against the current version; check every new image
   has an arm64 manifest (`docker manifest inspect <image> | grep arm64`). Removed
   or renamed values do not fail the render (no strict schema): read UPGRADE.md.
3. Grafana major: smoke-test it locally before touching the cluster. Docker in WSL:

   ```sh
   docker run -d --name gtest -p 3000:3000 \
     -e GF_PLUGINS_PREINSTALL_SYNC=volkovlabs-echarts-panel \
     -e GF_AUTH_ANONYMOUS_ENABLED=true -e GF_AUTH_ANONYMOUS_ORG_ROLE=Admin \
     docker.io/grafana/grafana:<tag>
   curl -s localhost:3000/api/plugins/volkovlabs-echarts-panel/settings   # signature valid, no angular
   jq -c '{dashboard: (. + {id: null}), overwrite: true}' landingzones/zeus/dashboards/battery-monthly.json \
     | curl -s -X POST -H 'Content-Type: application/json' localhost:3000/api/dashboards/db -d @-
   ```

   Open the imported boards (the echarts ones and any with legacy `graph` panels)
   and look for "Panel plugin not found" or console errors; data errors are expected
   (no datasources). `docker rm -f gtest` afterwards.
4. Rollback point: Grafana's SQLite lives on the `longhorn` PVC
   `kube-prometheus-stack-grafana` (nas-daily backup 04:30). **Grafana 13+ migrates
   the DB to unified storage at first start; the only way back is restoring that
   PVC from the backup.** Dashboards themselves are in git; only plugin state,
   annotations and UI-made changes are at stake.
5. Bump the pin, this chart's `version` and `appVersion`, PR into `develop`,
   release. Argo applies the CRDs and the operator in one sync (they must match);
   Prometheus and Alertmanager roll as StatefulSets, Grafana recreates its pod.
6. Verify: `observability` and `observability-config` Synced/Healthy; all targets
   up (`/api/v1/targets` or the Prometheus UI); PrometheusRules loaded (cerberus
   reads these alerts); Grafana up with every datasource and the plugin
   (`/api/plugins/volkovlabs-echarts-panel/settings`), the kiosk dashboards rendered,
   the InfluxDB static-mount datasource present; remote write to telemetry-archive
   flowing (`prometheus_remote_storage_samples_total`).

Rules learned on the way: `grafana.deploymentStrategy: {type: Recreate, rollingUpdate: null}` (RWO Longhorn PVC + RollingUpdate deadlocks the rollout when the new pod lands on another node — seen on the 92.11.0 release; the explicit `rollingUpdate: null` alone did NOT fix the server-side apply — Argo drops it — so the Deployment carries `argocd.argoproj.io/sync-options: ServerSideApply=false` via `grafana.annotations`: client-side apply honours the `retainKeys` directive on `spec.strategy` and clears the defaulted rollingUpdate block; without it the sync fails with "spec.strategy.rollingUpdate: Forbidden: may not be specified when strategy type is Recreate"); `grafana.testFramework.enabled: false` (Helm test hook
Pod, useless under Argo); the grafana chart 13+/14+ runs distroless with a read-only
root FS — plugins only via the `plugins` list (preinstall), never `GF_INSTALL_PLUGINS`,
no `GF_*__FILE` env; the Business Charts plugin (volkovlabs-echarts-panel) declares
`grafanaDependency >=12.3.0` and loaded fine on 13.2.4.
