#!/usr/bin/env bash
# Make and seal what Legion's middleware and image admission need
# (landingzones/legion/README.md, "NATS"), and turn them on in
# .config/lab/legion.yaml:
#
#   legion-nats-legate          seed   legate's own NATS user (nkey, U...)
#   legion-nats-callout-issuer  seed   the auth callout's issuer (account key, A...)
#   legion-nats-callout-xkey    seed   the callout's curve key (X...)
#   legion-harbor-admit         username, password   robot$legion+pull, read back
#                                      from its secret in namespace harbor
#
# The three keys are made here, with `nk`. Each seed goes from `nk` to
# kubeseal through a variable, and is never printed or written to a file; only
# the public halves are written in the clear, into nats.keys. Re-run to replace
# all of them (every centurion and fabrica admitted since is then refused and
# must be admitted again; legate's own user is replaced too).
#
# Usage:  .scripts/seal-legion-nats.sh
# Needs: kubeseal, kubectl with a context that reaches the cluster (the
# sealed-secrets controller in ns argocd, and ns harbor for the robot's
# secret), python3, and `nk` on PATH or Go to run it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
F=.config/lab/legion.yaml
grep -q '^legate:$' "$F" || { echo "$F has no legate: block" >&2; exit 1; }

if command -v nk >/dev/null 2>&1; then
  NK=(nk)
elif command -v go >/dev/null 2>&1; then
  NK=(go run github.com/nats-io/nkeys/nk@latest)
else
  echo "needs nk (go install github.com/nats-io/nkeys/nk@latest) or Go" >&2; exit 1
fi

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

# gen <kind> <secret name> <prefix>: makes a key, seals its seed, and sets
# PUB to its public half and SEALED to the sealed seed.
gen() {
  local out seed
  out=$("${NK[@]}" -gen "$1" -pubout)
  seed=$(printf '%s\n' "$out" | sed -n 1p)
  PUB=$(printf '%s\n' "$out" | sed -n 2p)
  [[ "$seed" == S* && "$PUB" == "$3"* ]] || { echo "nk gave no $1 key" >&2; exit 1; }
  SEALED=$(printf '%s' "$seed" | seal "$2")
  unset seed out
}

gen user legion-nats-legate U;              export K_USER=$PUB S_USER=$SEALED
gen account legion-nats-callout-issuer A;   export K_ISSUER=$PUB S_ISSUER=$SEALED
gen curve legion-nats-callout-xkey X;       export K_XKEY=$PUB S_XKEY=$SEALED

# The pull robot of project legion; its secret is what the harbor-bootstrap
# job set on it (platform/harbor-config).
robot=$(kubectl -n harbor get secret harbor-legion-pull-robot -o jsonpath='{.data.secret}' | base64 -d)
[ -n "$robot" ] || { echo "cannot read secret harbor-legion-pull-robot in ns harbor" >&2; exit 1; }
S_HUSER=$(printf '%s' 'robot$legion+pull' | seal legion-harbor-admit)
S_HPASS=$(printf '%s' "$robot" | seal legion-harbor-admit)
unset robot
export S_HUSER S_HPASS

python3 - "$F" <<'PY'
import os, sys
path = sys.argv[1]
e = os.environ
text = open(path, encoding="utf-8").read()
lines = text.split("\n")

def cut(lines, begin, end):
    if begin in lines:
        i = lines.index(begin); j = lines.index(end)
        del lines[i:j + 1]

B1, E1 = "  # BEGIN .scripts/seal-legion-nats.sh", "  # END .scripts/seal-legion-nats.sh"
B2, E2 = "# BEGIN .scripts/seal-legion-nats.sh", "# END .scripts/seal-legion-nats.sh"
cut(lines, B1, E1); cut(lines, B2, E2)

legate = [
    B1,
    "  middleware:",
    "    secrets:",
    "      user:",
    "        encryptedData:",
    '          seed: "%s"' % e["S_USER"],
    "      calloutIssuer:",
    "        encryptedData:",
    '          seed: "%s"' % e["S_ISSUER"],
    "      calloutXKey:",
    "        encryptedData:",
    '          seed: "%s"' % e["S_XKEY"],
    "  harbor:",
    "    enabled: true",
    "    secret:",
    "      encryptedData:",
    '        username: "%s"' % e["S_HUSER"],
    '        password: "%s"' % e["S_HPASS"],
    E1,
]
i = lines.index("legate:") + 1
lines[i:i] = legate

top = [
    B2,
    "# NATS on, with the public halves of the keys whose seeds are sealed above.",
    "nats:",
    "  enabled: true",
    "  keys:",
    '    legateUser: "%s"' % e["K_USER"],
    '    calloutIssuer: "%s"' % e["K_ISSUER"],
    '    calloutXKey: "%s"' % e["K_XKEY"],
    "fabricae:",
    "  enabled: true",
    E2,
]
while lines and lines[-1] == "":
    lines.pop()
lines += [""] + top + [""]
open(path, "w", encoding="utf-8", newline="\n").write("\n".join(lines))
PY
echo "sealed into $F; NATS, the fabricae's namespace and image admission are ON there"
echo "next, on a branch off develop:  git add $F && git commit -m 'feat(legion): seal NATS and turn it on' && git push, then a PR into develop"
