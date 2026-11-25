#!/usr/bin/env bash
# Seal the three secrets legate needs (landingzones/legion/README.md, "Secrets")
# into .config/lab/legion.yaml, block `legate.secrets`:
#
#   legion-admin-token      digest                    the admin token's digest
#   legion-github-app       client-id, client-secret  the sign-in
#   legion-github-app-key   app-id, private-key       reading GitHub
#
# Usage:  .scripts/seal-legion-secrets.sh <path-to-app-private-key.pem>
# Asks for the admin token's digest, the App's Client ID and its client secret
# (the secret is not shown as you type). Every value goes to kubeseal over
# stdin; nothing plaintext is written into the repo. Re-run to replace all
# three. Needs a kubectl context that can reach the sealed-secrets controller
# (ns argocd).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
F=.config/lab/legion.yaml
KEY=${1:?usage: $0 <path-to-app-private-key.pem>}
[ -r "$KEY" ] || { echo "cannot read $KEY" >&2; exit 1; }
grep -q 'BEGIN .*PRIVATE KEY' "$KEY" || { echo "$KEY does not look like a PEM private key" >&2; exit 1; }
grep -q '^  secrets:$' "$F" || { echo "$F has no legate.secrets block" >&2; exit 1; }

# The controller's public certificate is fetched once, with retries (WSL's
# lookup of the API server's name fails now and then), and everything is then
# sealed against that file without the cluster.
CERT=$(mktemp)
trap 'rm -f "$CERT"' EXIT
for try in 1 2 3 4 5 6; do
  if kubeseal --fetch-cert --controller-name sealed-secrets --controller-namespace argocd > "$CERT" 2>/dev/null \
     && grep -q 'BEGIN CERTIFICATE' "$CERT"; then break; fi
  [ "$try" = 6 ] && { echo "cannot reach the sealed-secrets controller (kubectl context? DNS?)" >&2; exit 1; }
  sleep 3
done

seal() {  # seal <secret name>, the value on stdin
  kubeseal --raw --cert "$CERT" --namespace legion --name "$1" --from-file=/dev/stdin
}

read -rp "Admin token digest (64 characters, from 'legion admin-token new'): " digest
read -rp "GitHub App Client ID (starts with Iv): " client_id
read -rsp "GitHub App client secret (not shown): " client_secret; echo
[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo "the digest is 64 lowercase hexadecimal characters; this is not one (did you paste the token?)" >&2; exit 1; }
[[ "$client_id" =~ ^Iv[A-Za-z0-9.]+$ ]] || { echo "a Client ID starts with Iv" >&2; exit 1; }
[[ "$client_secret" =~ ^[A-Za-z0-9_]{20,}$ ]] || { echo "that does not look like a client secret" >&2; exit 1; }

S_DIGEST=$(printf '%s' "$digest" | seal legion-admin-token)
S_CLIENT_ID=$(printf '%s' "$client_id" | seal legion-github-app)
S_CLIENT_SECRET=$(printf '%s' "$client_secret" | seal legion-github-app)
# GitHub takes the Client ID as the App's id (legion legate/README.md).
S_APP_ID=$(printf '%s' "$client_id" | seal legion-github-app-key)
S_KEY=$(seal legion-github-app-key < "$KEY")
unset client_secret
export S_DIGEST S_CLIENT_ID S_CLIENT_SECRET S_APP_ID S_KEY

# Replace the `  secrets:` block of legate (up to the next empty line).
python3 - "$F" <<'PY'
import os, sys
path = sys.argv[1]
lines = open(path, encoding="utf-8").read().split("\n")
start = lines.index("  secrets:")
end = start + 1
while end < len(lines) and lines[end].strip() != "":
    end += 1
e = os.environ
block = [
    "  secrets:",
    "    # Sealed for namespace legion by .scripts/seal-legion-secrets.sh.",
    "    adminToken:",
    "      encryptedData:",
    '        digest: "%s"' % e["S_DIGEST"],
    "    githubApp:",
    "      encryptedData:",
    '        client-id: "%s"' % e["S_CLIENT_ID"],
    '        client-secret: "%s"' % e["S_CLIENT_SECRET"],
    "    githubAppKey:",
    "      encryptedData:",
    '        app-id: "%s"' % e["S_APP_ID"],
    '        private-key: "%s"' % e["S_KEY"],
]
open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines[:start] + block + lines[end:]))
PY
echo "sealed into $F"
echo "next: delete the .pem, then  git add $F && git commit -m 'feat(legion): seal the secrets of legate' && git push"
