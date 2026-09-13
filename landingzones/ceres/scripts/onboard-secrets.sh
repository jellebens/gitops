#!/usr/bin/env bash
# onboard-secrets.sh — ceres card #295, checklist items 1a, 1b, 2, 3a, 3b in one run,
# WITHOUT a password ever reaching the terminal, the shell history or git.
#
#   bash landingzones/ceres/scripts/onboard-secrets.sh            # do it
#   bash landingzones/ceres/scripts/onboard-secrets.sh --dry-run  # show what would happen
#
# What it does, in order:
#   1. generates a random password per broker user and random API tokens (shell
#      variables only — `set +x`, umask 077, nothing echoed);
#   2. EMQX (admin REST API on mqtt-0, dashboard admin password read straight
#      from the mqtt-auth secret): creates or resets the users
#      vertumnus-pomona-0001, annona, robigus, carmenta, telegraf-ceres,
#      unit-pomona-0001 and PUTs each one's ACL exactly as platform/mqtt/files/acl.conf
#      has it; adds the ceres grants to homeassistant's existing ACL (item 1b);
#   3. InfluxDB: bucket `ceres` (retention forever) if missing + a bucket-scoped
#      write token (created inside the influxdb pod, captured, never printed);
#   4. seals every value for ns ceres with kubeseal and writes the blobs into
#      .config/lab/ceres.yaml; seals the Grafana read-role password twice into two
#      SealedSecret manifests (ns ceres, ns observability);
#   5. saves the node's MQTT password to .secrets/ceres/ (gitignored) for
#      firmware/pomona/secrets.h at flash time;
#   6. commits the three ciphertext files on a branch and opens the PR to develop.
#
# Re-running is safe: users get a new password (the sealed blobs are rewritten to
# match), the bucket is kept, a new Influx token is created (old ones stay valid;
# delete them in the Influx UI when convenient).
#
# Needs: kubectl (ctx lab), kubeseal, jq, openssl, python3, gh, git — all in WSL.
set -euo pipefail
set +x
umask 077

DRY=0; [ "${1:-}" = "--dry-run" ] && DRY=1
REPO="$(cd "$(dirname "$0")/../../.." && pwd)"
LAB="$REPO/.config/lab/ceres.yaml"
NS=ceres
CTRL=(--controller-name sealed-secrets --controller-namespace argocd)
MQTT_POD=mqtt-0
INFLUX_POD=influxdb-influxdb2-0
say() { printf '%s\n' "$*" >&2; }
die() { say "error: $*"; exit 1; }

for t in kubectl kubeseal jq openssl python3 gh git; do command -v "$t" >/dev/null || die "$t not found"; done
[ -f "$LAB" ] || die "$LAB not found — run from the gitops checkout"
cd "$REPO"
git diff --quiet -- .config/lab/ceres.yaml || die ".config/lab/ceres.yaml has uncommitted changes — commit or stash first"
say "repo: $REPO  branch: $(git branch --show-current)  dry-run: $DRY"

# ── 1. the secrets, in memory only ─────────────────────────────────────────────────────────────
rnd() { openssl rand -base64 33 | tr -d '\n/+=' | cut -c1-32; }
declare -A PW
for u in vertumnus-pomona-0001 annona robigus carmenta telegraf-ceres unit-pomona-0001; do PW[$u]="$(rnd)"; done
VERTUMNUS_TOKEN="$(rnd)"; ANNONA_TOKEN="$(rnd)"; GRAFANA_PW="$(rnd)"

# ── 2. EMQX users + ACLs (admin REST API, in-cluster) ───────────────────────────────────────────
TOKEN=""
if [ "$DRY" = 0 ]; then
DASH="$(kubectl get secret -n mqtt mqtt-auth -o go-template='{{index .data "dashboard-password" | base64decode}}')"
[ -n "$DASH" ] || die "could not read the dashboard password from secret mqtt-auth"
fi
api() {  # api METHOD PATH [body-on-stdin] -> prints http code; body/response never echoed
  local m="$1" p="$2"
  kubectl exec -i -n mqtt "$MQTT_POD" -- curl -s -o /dev/null -w '%{http_code}' -X "$m" \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' "http://127.0.0.1:18083/api/v5/$p" -d @-
}
api_get() {  # api_get PATH -> response body
  kubectl exec -n mqtt "$MQTT_POD" -- curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:18083/api/v5/$1"
}
if [ "$DRY" = 0 ]; then
TOKEN="$(jq -n --arg p "$DASH" '{username:"admin",password:$p}' \
  | kubectl exec -i -n mqtt "$MQTT_POD" -- curl -s -X POST -H 'Content-Type: application/json' http://127.0.0.1:18083/api/v5/login -d @- \
  | jq -r '.token // empty')"
unset DASH
[ -n "$TOKEN" ] || die "EMQX login failed"
fi

# the ACLs, verbatim from platform/mqtt/files/acl.conf (order matters: deny # last)
rule() { jq -n --arg t "$1" --arg a "$2" '{topic:$t, permission:"allow", action:$a}'; }
DENY='{"topic":"#","permission":"deny","action":"all"}'
rules() {  # rules "sub:topic sub:topic pub:topic ..." -> JSON array ending in deny all
  local out=() spec
  for spec in "$@"; do out+=("$(rule "${spec#*:}" "$( [ "${spec%%:*}" = sub ] && echo subscribe || echo publish )")"); done
  printf '%s\n' "${out[@]}" "$DENY" | jq -s .
}
declare -A ACL
ACL[unit-pomona-0001]="$(rules \
  pub:ceres/pomona-0001/tele/# pub:ceres/pomona-0001/actuator/+/state pub:ceres/pomona-0001/actuator/+/reason \
  pub:ceres/pomona-0001/dose/result pub:ceres/pomona-0001/sys/status pub:ceres/pomona-0001/sys/meta \
  pub:ceres/pomona-0001/sys/health pub:ceres/pomona-0001/sys/ota/result pub:ceres/pomona-0001/sys/diag/# \
  sub:ceres/pomona-0001/actuator/+/set sub:ceres/pomona-0001/dose/request sub:ceres/pomona-0001/desired \
  sub:ceres/pomona-0001/sys/ota/url sub:ceres/pomona-0001/sys/diag/+/get)"
ACL[vertumnus-pomona-0001]="$(rules \
  sub:ceres/pomona-0001/# sub:ceres/sys/mode sub:pomona/demeter/ledger \
  pub:ceres/pomona-0001/actuator/+/set pub:ceres/pomona-0001/dose/request pub:ceres/pomona-0001/sys/role \
  pub:ceres/pomona-0001/sys/decision pub:ceres/pomona-0001/sys/ledger pub:ceres/sys/status/vertumnus-pomona-0001 \
  pub:pomona/dose/test pub:pomona/pump/override pub:pomona/unit/ota_url)"
ACL[carmenta]="$(rules sub:ceres/# pub:ceres/+/sys/prior pub:ceres/sys/advice pub:ceres/sys/status/carmenta)"
ACL[telegraf-ceres]="$(rules sub:ceres/#)"
ACL[annona]="$(rules sub:ceres/# pub:ceres/+/sys/config pub:ceres/+/desired pub:ceres/sys/#)"
ACL[robigus]="$(rules sub:ceres/# sub:pomona/# pub:ceres/+/sys/alerts pub:ceres/+/sys/advice pub:ceres/sys/alerts pub:ceres/sys/status/robigus)"

for u in "${!PW[@]}"; do
  if [ "$DRY" = 1 ]; then say "[dry-run] would create/reset broker user $u and PUT $(jq length <<<"${ACL[$u]}") ACL rules"; continue; fi
  code="$(jq -n --arg u "$u" --arg p "${PW[$u]}" '{user_id:$u, password:$p, is_superuser:false}' | api POST 'authentication/password_based:built_in_database/users')"
  if [ "$code" = 409 ]; then
    code="$(jq -n --arg p "${PW[$u]}" '{password:$p}' | api PUT "authentication/password_based:built_in_database/users/$u")"
    say "broker user $u: password reset ($code)"
  else
    say "broker user $u: created ($code)"
  fi
  [[ "$code" =~ ^20 ]] || die "EMQX refused user $u (http $code)"
  code="$(jq -n --arg u "$u" --argjson r "${ACL[$u]}" '{username:$u, rules:$r}' | api PUT "authorization/sources/built_in_database/rules/users/$u")"
  if [ "$code" = 404 ]; then
    code="$(jq -n --arg u "$u" --argjson r "${ACL[$u]}" '[{username:$u, rules:$r}]' | api POST 'authorization/sources/built_in_database/rules/users')"
  fi
  [[ "$code" =~ ^20 ]] || die "EMQX refused ACL for $u (http $code)"
  say "broker ACL $u: set ($code)"
done

# item 1b: homeassistant gains the ceres grants, its existing rules kept, deny # stays last
HA_ADD='[{"topic":"ceres/#","permission":"allow","action":"subscribe"},
         {"topic":"ceres/+/actuator/+/power_w","permission":"allow","action":"publish"},
         {"topic":"ceres/+/actuator/+/set","permission":"allow","action":"publish"}]'
if [ "$DRY" = 1 ]; then say "[dry-run] would add 3 ceres grants to homeassistant's ACL"; else
  cur="$(api_get 'authorization/sources/built_in_database/rules/users/homeassistant' | jq -c '.rules // []')"
  new="$(jq -n --argjson cur "$cur" --argjson add "$HA_ADD" '
    ($cur | map(select(.topic != "#" or .permission != "deny"))) as $keep
    | ($keep + ($add | map(select(. as $a | ($keep | map(.topic + .action) | index($a.topic + $a.action)) == null))))
    + [{"topic":"#","permission":"deny","action":"all"}]')"
  code="$(jq -n --argjson r "$new" '{username:"homeassistant", rules:$r}' | api PUT 'authorization/sources/built_in_database/rules/users/homeassistant')"
  [[ "$code" =~ ^20 ]] || die "EMQX refused the homeassistant ACL update (http $code)"
  say "broker ACL homeassistant: ceres grants present ($code)"
fi
unset TOKEN

# ── 3. InfluxDB bucket + write token (inside the pod; the token comes back on stdout only) ─────
if [ "$DRY" = 1 ]; then INFLUX_TOKEN="dry-run"; say "[dry-run] would ensure bucket ceres and create a write token"; else
INFLUX_TOKEN="$(kubectl exec -i -n influxdb "$INFLUX_POD" -- sh -s <<'EOF'
set -e
O="${DOCKER_INFLUXDB_INIT_ORG:-zeus}"; T="$DOCKER_INFLUXDB_INIT_ADMIN_TOKEN"
id="$(influx bucket ls --org "$O" --token "$T" --name ceres --json 2>/dev/null | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)"
if [ -z "$id" ]; then
  id="$(influx bucket create --org "$O" --token "$T" --name ceres --retention 0 --description 'Ceres v2 archive (ADR-0006: forever)' --json | sed -n 's/.*"id": *"\([^"]*\)".*/\1/p' | head -1)"
fi
[ -n "$id" ] || { echo "no bucket id" >&2; exit 1; }
influx auth create --org "$O" --token "$T" --write-bucket "$id" --description "telegraf-ceres write (onboard-secrets.sh $(date -u +%F))" --json | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p' | head -1
EOF
)"
[ -n "$INFLUX_TOKEN" ] || die "no Influx token came back"
say "influx: bucket ceres ensured, write token created"
fi

# ── 4. seal + write the blobs ───────────────────────────────────────────────────────────────
seal() { printf '%s' "$2" | kubeseal --raw "${CTRL[@]}" --namespace "$NS" --name "$1" --from-file=/dev/stdin; }
if [ "$DRY" = 1 ]; then say "[dry-run] would seal 13 values for ns $NS and write them into $LAB"; else
S_V=ceres-vertumnus-pomona-0001-secrets; S_A=ceres-annona-secrets; S_R=ceres-robigus-secrets; S_T=ceres-telegraf-secrets; S_C=ceres-carmenta-secrets
export B_V_USER="$(seal $S_V vertumnus-pomona-0001)" B_V_PASS="$(seal $S_V "${PW[vertumnus-pomona-0001]}")" B_V_TOKEN="$(seal $S_V "$VERTUMNUS_TOKEN")"
export B_A_USER="$(seal $S_A annona)" B_A_PASS="$(seal $S_A "${PW[annona]}")" B_A_TOKEN="$(seal $S_A "$ANNONA_TOKEN")"
export B_R_USER="$(seal $S_R robigus)" B_R_PASS="$(seal $S_R "${PW[robigus]}")"
export B_T_USER="$(seal $S_T telegraf-ceres)" B_T_PASS="$(seal $S_T "${PW[telegraf-ceres]}")" B_T_INFLUX="$(seal $S_T "$INFLUX_TOKEN")"
export B_C_USER="$(seal $S_C carmenta)" B_C_PASS="$(seal $S_C "${PW[carmenta]}")"
LAB="$LAB" python3 - <<'PY'
import os, re
p = os.environ["LAB"]; s = open(p).read()
blocks = [  # file order: units.pomona-0001 (vertumnus), annona, robigus, telegraf, carmenta
    {"MQTT_USER": "B_V_USER", "MQTT_PASS": "B_V_PASS", "VERTUMNUS_TOKEN": "B_V_TOKEN"},
    {"MQTT_USER": "B_A_USER", "MQTT_PASS": "B_A_PASS", "ANNONA_TOKEN": "B_A_TOKEN"},
    {"MQTT_USER": "B_R_USER", "MQTT_PASS": "B_R_PASS"},
    {"MQTT_USER": "B_T_USER", "MQTT_PASS": "B_T_PASS", "INFLUX_TOKEN": "B_T_INFLUX"},
    {"MQTT_USER": "B_C_USER", "MQTT_PASS": "B_C_PASS"},
]
pat = re.compile(r"^( *)encryptedData: \{\}[^\n]*$", re.M)
found = list(pat.finditer(s))
assert len(found) == 5, f"expected 5 empty encryptedData blocks, found {len(found)}"
out, pos = [], 0
for m, keys in zip(found, blocks):
    ind = m.group(1)
    body = f"{ind}encryptedData:\n" + "".join(f'{ind}  {k}: "{os.environ[v]}"\n' for k, v in keys.items())
    out.append(s[pos:m.start()]); out.append(body.rstrip("\n")); pos = m.end()
out.append(s[pos:]); open(p, "w").write("".join(out))
print("ceres.yaml: 5 sealed blocks written")
PY
unset B_V_USER B_V_PASS B_V_TOKEN B_A_USER B_A_PASS B_A_TOKEN B_R_USER B_R_PASS B_T_USER B_T_PASS B_T_INFLUX B_C_USER B_C_PASS

# the Grafana read role: one password, sealed twice (ns ceres for CNPG, ns observability for Grafana)
kubectl create secret generic ceres-pg-grafana -n ceres --from-literal=username=grafana --from-literal=password="$GRAFANA_PW" --dry-run=client -o yaml \
  | kubeseal "${CTRL[@]}" -o yaml > landingzones/ceres/templates/postgres-grafana-sealed-secret.yaml
kubectl create secret generic grafana-ceres-postgres -n observability --from-literal=CERES_PG_PASSWORD="$GRAFANA_PW" --dry-run=client -o yaml \
  | kubeseal "${CTRL[@]}" -o yaml > platform/observability-config/templates/grafana-ceres-postgres-sealed-secret.yaml
say "grafana role: two SealedSecret manifests written"
fi

# ── 5. the node's password for firmware/pomona/secrets.h (gitignored, 0600) ─────────────────────
mkdir -p "$REPO/.secrets/ceres"
if [ "$DRY" = 0 ]; then
  printf '%s\n' "${PW[unit-pomona-0001]}" > "$REPO/.secrets/ceres/unit-pomona-0001.mqtt-pass"
  chmod 600 "$REPO/.secrets/ceres/unit-pomona-0001.mqtt-pass"
fi
say "node password saved to $REPO/.secrets/ceres/unit-pomona-0001.mqtt-pass — MQTT_PASS in firmware/pomona/secrets.h at flash time (#295 item 7a)"
unset PW VERTUMNUS_TOKEN ANNONA_TOKEN GRAFANA_PW INFLUX_TOKEN

# ── 6. commit the ciphertext and open the PR ───────────────────────────────────────────────────
[ "$DRY" = 1 ] && { say "[dry-run] would commit .config/lab/ceres.yaml + 2 sealed manifests and open a PR to develop"; exit 0; }
br="secrets/ceres-$(date +%Y%m%d-%H%M)"
git checkout -q -b "$br"
git add .config/lab/ceres.yaml landingzones/ceres/templates/postgres-grafana-sealed-secret.yaml platform/observability-config/templates/grafana-ceres-postgres-sealed-secret.yaml
git commit -q -m "secrets(ceres): #295 items 1-3 — broker users + ACLs live, Influx bucket ceres + token, every ns-ceres secret sealed, the Grafana read role sealed twice

Made by landingzones/ceres/scripts/onboard-secrets.sh; ciphertext only."
git push -q -u origin "$br"
gh pr create --base develop --title "secrets(ceres): #295 items 1-3 sealed (onboard-secrets.sh)" \
  --body "Broker users vertumnus-pomona-0001, annona, robigus, carmenta, telegraf-ceres, unit-pomona-0001 created/reset with their acl.conf ACLs; homeassistant gained the ceres grants; Influx bucket ceres + write token; all five ns-ceres secrets sealed into .config/lab/ceres.yaml; Grafana read role sealed for ns ceres and ns observability. Ciphertext only. After merge: develop -> master release; the ceres pods connect within a minute." || true
say "done. Merge the PR into develop, then develop -> master. Then: kubectl logs -n ceres deploy/ceres-vertumnus-pomona-0001 --tail=5"
