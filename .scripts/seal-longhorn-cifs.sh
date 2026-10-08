#!/usr/bin/env bash
# Seal the NAS credentials for Longhorn's CIFS backup target into
# .config/lab/longhorn-config.yaml (SealedSecret longhorn-system/longhorn-backup-credentials,
# keys CIFS_USERNAME / CIFS_PASSWORD). Prompts without echo; the plaintext only
# goes to kubeseal over stdin. Re-run to rotate. See platform/longhorn/README.md "Backups".
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
F=.config/lab/longhorn-config.yaml
seal() {
  kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd \
    --namespace longhorn-system --name longhorn-backup-credentials --from-file=/dev/stdin
}
read -rp  "NAS user for the longhorn-backup share: " u
read -rsp "Password: " p; echo
[ -n "$u" ] && [ -n "$p" ] || { echo "empty user or password" >&2; exit 1; }
su=$(printf '%s' "$u" | seal)
sp=$(printf '%s' "$p" | seal)
unset p
# Replace any previous secret block (it is always the last block in the file).
sed -i '/^# --- sealed backup credentials ---$/,$d' "$F"
cat >> "$F" <<EOF
# --- sealed backup credentials ---
# Sealed for longhorn-system/longhorn-backup-credentials by .scripts/seal-longhorn-cifs.sh.
secret:
  sealedSecret:
    encryptedData:
      CIFS_USERNAME: "$su"
      CIFS_PASSWORD: "$sp"
EOF
echo "sealed into $F"
