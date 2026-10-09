# Sealed-secrets key backup (disaster recovery)

Every `SealedSecret` in this repo can only be decrypted by the private keys of
the in-cluster controller (`sealed-secrets`, namespace `argocd`). If the cluster
is lost and those keys are gone, **every sealed value in git is unrecoverable**.
That covers app credentials, the Harbor secrets and the NAS backup credentials.
All of it would have to be re-created by hand and re-sealed. The NAS backups
(pg_dumps, Longhorn `nas-daily`) do not help here: the keys are not on the NAS.

So the keys must also live **outside the cluster**, held by the owner. Never put
them in git, on the cluster's own NAS shares, or in a ticket or chat.

## Facts (2026-10-09)

- Controller `bitnami/sealed-secrets-controller:0.38.4`, `--key-prefix sealed-secrets-key`.
- **Keys rotate every 30 days** (the controller default). A new key is added, and
  the old keys are kept, because secrets sealed earlier still need them. On
  2026-10-09 there were 7 keys (2026-03-28 … 2026-09-24). The next one is due
  around **2026-10-24**.
- New seals always use the newest key. **A backup taken before a rotation cannot
  decrypt anything sealed after it.** Re-export after every rotation (monthly).

## Export (owner, on a trusted machine)

The output file contains the **private keys in plaintext**. Write it straight to
an encrypted place, and delete any local copy.

```sh
kubectl -n argocd get secret -l sealedsecrets.bitnami.com/sealed-secrets-key -o yaml \
  > sealed-secrets-keys-$(date +%F).yaml
```

Store the file as an attachment in the password manager. Then remove the local
copy (`shred -u sealed-secrets-keys-*.yaml`).

Check how many keys the file holds. It must equal the number in the cluster:

```sh
grep -c 'sealedsecrets.bitnami.com/sealed-secrets-key: active' sealed-secrets-keys-*.yaml
kubectl -n argocd get secret -l sealedsecrets.bitnami.com/sealed-secrets-key --no-headers | wc -l
```

## Prove the backup works, without the cluster

`kubeseal --recovery-unseal` decrypts offline with the backed-up keys. Run this
from the gitops repo root. It shows the **key names** of one secret, never its
values. The pipeline was validated on 2026-10-09 with a throwaway key pair: it
decrypts a secret sealed with an older (rotated) key, and fails with `no key
could decrypt` when the sealing key is missing.

```sh
yq -r '.items[].data["tls.key"]' sealed-secrets-keys-*.yaml | while read k; do echo "$k" | base64 -d; done > /tmp/ss-keys.pem
helm template lc platform/longhorn -f .config/lab/longhorn-config.yaml -s templates/sealed-secret.yaml \
  | kubeseal --recovery-unseal --recovery-private-key /tmp/ss-keys.pem -o json | jq -r '.data | keys'
shred -u /tmp/ss-keys.pem
```

Expected output: `["CIFS_PASSWORD","CIFS_USERNAME"]`. An error such as
`no key could decrypt secret` means the backup misses the key that sealed it.

## Restore (new or rebuilt cluster)

Put the keys back **before** the controller decrypts anything. Otherwise it
generates a fresh key and the SealedSecrets fail with `no key could decrypt`.

```sh
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f sealed-secrets-keys-<date>.yaml            # into ns argocd
kubectl -n argocd delete pod -l app.kubernetes.io/name=sealed-secrets   # if it was already running
```

The controller then loads every key labelled
`sealedsecrets.bitnami.com/sealed-secrets-key` and decrypts the SealedSecrets
Argo applies. Check with `kubectl get sealedsecrets -A` (status `Synced`) and
look for `ErrUnsealFailed` events. The newest restored key stays the sealing key
until the next rotation.

## Routine

| When | What |
|---|---|
| After every key rotation (about monthly; next ~2026-10-24) | export, store, run the count check |
| After any restore or cluster rebuild | the recovery-unseal check above |

Find the newest key's date with
`kubectl -n argocd get secret -l sealedsecrets.bitnami.com/sealed-secrets-key --sort-by=.metadata.creationTimestamp | tail -1`.
