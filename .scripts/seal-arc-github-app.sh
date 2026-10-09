#!/usr/bin/env bash
# Seal the ARC GitHub App credential (#339) into .config/lab/arc-runners-config.yaml:
# SealedSecret arc-runners/arc-github-app, keys github_app_id,
# github_app_installation_id, github_app_private_key — the pre-defined secret
# the scale set reads (githubConfigSecret in .config/lab/arc-runners.yaml).
#
# Usage:  .scripts/seal-arc-github-app.sh <path-to-app-private-key.pem>
# Prompts for the App ID and the Installation ID. The private key only goes to
# kubeseal over stdin; nothing plaintext is written into the repo. Re-run to
# rotate. Needs a kubectl context that can reach the sealed-secrets controller
# (ns argocd). Procedure: landingzones/arc-runners/README.md "Enable the scale set".
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
F=.config/lab/arc-runners-config.yaml
KEY=${1:?usage: $0 <path-to-app-private-key.pem>}
[ -r "$KEY" ] || { echo "cannot read $KEY" >&2; exit 1; }
grep -q 'BEGIN .*PRIVATE KEY' "$KEY" || { echo "$KEY does not look like a PEM private key" >&2; exit 1; }

seal() {
  kubeseal --raw --controller-name sealed-secrets --controller-namespace argocd \
    --namespace arc-runners --name arc-github-app --from-file=/dev/stdin
}

read -rp "GitHub App ID (or Client ID): " app_id
read -rp "Installation ID (github.com/settings/installations/<id>): " inst_id
[[ "$app_id" =~ ^[A-Za-z0-9.]+$ ]] || { echo "bad App ID" >&2; exit 1; }
[[ "$inst_id" =~ ^[0-9]+$ ]] || { echo "Installation ID must be numeric" >&2; exit 1; }

s_app=$(printf '%s' "$app_id" | seal)
s_inst=$(printf '%s' "$inst_id" | seal)
s_key=$(seal < "$KEY")

# Replace any previous GitHub App block (always the last block in the file).
sed -i '/^# --- sealed GitHub App credential ---$/,$d' "$F"
cat >> "$F" <<EOF
# --- sealed GitHub App credential ---
# Sealed for arc-runners/arc-github-app by .scripts/seal-arc-github-app.sh.
githubApp:
  encryptedData:
    github_app_id: "$s_app"
    github_app_installation_id: "$s_inst"
    github_app_private_key: "$s_key"
EOF
echo "sealed into $F"
echo "next: set arc.runners.enabled: true in .config/lab/apps.yaml, commit both on a card branch, PR into develop."
