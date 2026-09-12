# Local validation of the republish bridge (demeter #295): renders the chart, boots a throw-away
# emqx/emqx:5.8.9 in docker with exactly the rendered rule env vars, checks every mapping.
#   bash platform/mqtt/tests/bridge_test.sh
#!/bin/bash
# Render the chart, lift the rule-engine env vars off the StatefulSet, boot a
# throw-away EMQX with exactly those, list the rules, run the functional test.
set -e
cd "/home/jelle/repos/gitops-card-291"
helm lint platform/mqtt -f .config/lab/mqtt.yaml 2>&1 | tail -1
helm template mqtt platform/mqtt -f .config/lab/mqtt.yaml > /tmp/mqtt-rendered.yaml
python3 - <<'PY'
import yaml
docs = [d for d in yaml.safe_load_all(open("/tmp/mqtt-rendered.yaml")) if d and d.get("kind") == "StatefulSet"]
env = docs[0]["spec"]["template"]["spec"]["containers"][0]["env"]
rules = [e for e in env if e["name"].startswith("EMQX_RULE_ENGINE__")]
print(f"{len(rules)} rule env vars on the StatefulSet")
with open("/tmp/emqx-rules.env", "w") as fh:
    for e in rules:
        fh.write(f"{e['name']}={e['value']}\n")
PY
docker rm -f emqx-rules-test >/dev/null 2>&1 || true
docker run -d --name emqx-rules-test --env-file /tmp/emqx-rules.env -p 18830:1883 -p 18083:18083 emqx/emqx:5.8.9 >/dev/null
for i in $(seq 1 40); do docker exec emqx-rules-test emqx ctl status 2>/dev/null | grep -q "is started" && break; sleep 2; done
docker exec emqx-rules-test emqx ctl status | tail -1
echo "=== rules known to the broker"
docker exec emqx-rules-test emqx ctl rules list 2>&1 | grep -c -i 'pomona' 
docker exec emqx-rules-test emqx ctl rules list 2>&1 | head -3
echo "=== functional"
python3 platform/mqtt/tests/bridge_test.py 18830   # needs paho-mqtt (pip install paho-mqtt)
rc=$?
docker logs emqx-rules-test 2>&1 | grep -i -E "error|invalid|failed" | grep -v "^$" | head -5
docker rm -f emqx-rules-test >/dev/null
exit $rc
