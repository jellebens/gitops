# csi-driver-smb-config — SMB (NAS001) storage

Cluster resources for the [`csi-driver-smb`](https://github.com/kubernetes-csi/csi-driver-smb)
platform service: a reusable **`smb` StorageClass** backed by NAS001 over SMB/CIFS,
plus the sealed SMB credentials.

| | |
|---|---|
| Driver app | `csi-driver-smb` (external chart, `repos.csiDriverSmb`, ns `kube-system`, sync-wave 10) |
| This config app | `csi-driver-smb-config` (sync-wave 11) |
| StorageClass | `smb` → `//192.168.50.102/zeus-data`, provisioner `smb.csi.k8s.io` |
| Reclaim policy | **Retain** (deleting a PVC leaves the data subdir on the NAS) |
| Credentials | SealedSecret `smbcreds` in `kube-system` (user/password) |

Each PVC gets its own subdirectory under the share, so the class is reusable by
any workload — just request it:

```yaml
spec:
  storageClassName: smb
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
```

Files are mapped to uid/gid `1000` (mount `0777`); tune in [`values.yaml`](values.yaml).

## Credentials

NAS001 = `192.168.50.102` (the name `nas001` does not resolve in-cluster, so the
StorageClass `source` uses the IP). The SMB user/password are sealed into
`kube-system/smbcreds`; the sealed values live in
`.config/<env>/csi-driver-smb-config.yaml` under `secret.sealedSecret.encryptedData`:

```sh
printf '<password>' | kubeseal --raw \
  --controller-name sealed-secrets --controller-namespace argocd \
  --namespace kube-system --name smbcreds --from-file=/dev/stdin
```

(Controller: `sealed-secrets` in namespace `argocd`.) First consumer:
[`landingzones/zeus`](../../landingzones/zeus) (`/app/reports` history + reports).
