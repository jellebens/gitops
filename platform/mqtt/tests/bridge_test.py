"""Functional test of the republish bridge against a throw-away local EMQX
(docker, no authn): publish on one tree, expect the mirror on the other; then
a FRESH subscriber must see exactly the retained ones (ADR-0008 rule 1). Exit 1
on any miss."""
import json
import sys
import threading
import time

import paho.mqtt.client as mqtt

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18830
live: dict[str, str] = {}
fresh: dict[str, tuple[str, bool]] = {}
lock = threading.Lock()


def _client(cid, store, with_retain):
    def on_message(_c, _u, msg):
        with lock:
            store[msg.topic] = (msg.payload.decode(), bool(msg.retain)) if with_retain else msg.payload.decode()
    c = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=cid)
    c.on_message = on_message
    c.connect("127.0.0.1", PORT)
    c.subscribe([("demeter/#", 1), ("pomona/#", 1)])
    c.loop_start()
    return c


sub = _client("t-sub", live, False)
time.sleep(1)
pub = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id="t-pub")
pub.connect("127.0.0.1", PORT)
pub.loop_start()

cases = [
    # (publish topic, payload, retain) -> (expected topic, expected payload | None, expected retained)
    (("pomona/water/ph", "6.10", False), ("demeter/pomona-0001/tele/water/ph", "6.10", False)),
    (("pomona/air/lux", "812", False), ("demeter/pomona-0001/tele/air/lux", "812", False)),
    (("pomona/unit/rssi_dbm", "-61", False), ("demeter/pomona-0001/tele/node/rssi_dbm", "-61", False)),
    (("pomona/unit/status", "online", True), ("demeter/pomona-0001/sys/status", "online", True)),
    (("pomona/unit/sensors", '{"ph_calibrated":true}', True), ("demeter/pomona-0001/sys/health", '{"ph_calibrated":true}', True)),
    (("pomona/unit/fw_version", "1.3.8", True), ("demeter/pomona-0001/sys/meta", None, True)),
    (("pomona/pump/request", "on", True), ("demeter/pomona-0001/actuator/pump/state", "on", True)),
    (("pomona/pump/reason", "schedule", True), ("demeter/pomona-0001/actuator/pump/reason", "schedule", True)),
    (("pomona/pump/power", "4.7", True), ("demeter/pomona-0001/actuator/pump/power_w", "4.7", True)),
    (("pomona/light/request", "off", True), ("demeter/pomona-0001/actuator/light/state", "off", True)),
    (("pomona/dose/result", "ch1 done", True), ("demeter/pomona-0001/dose/result", "ch1 done", True)),
    (("pomona/unit/i2c_scan", '{"found":2}', True), ("demeter/pomona-0001/sys/diag/i2c_scan", '{"found":2}', True)),
    (("demeter/pomona-0001/actuator/pump/set", "on", False), ("pomona/pump/override", "on", False)),
    (("demeter/pomona-0001/sys/ota/url", "http://x/pomona-2.0.0.ota", False), ("pomona/unit/ota_url", "http://x/pomona-2.0.0.ota", False)),
    (("demeter/pomona-0001/sys/diag/i2c_scan/get", "1", False), ("pomona/unit/i2c_scan/get", "1", False)),
    (("demeter/pomona-0001/desired", json.dumps({"stage": "established", "targets": {}}), True), ("pomona/control/mode", "established", True)),
]
for (t, p, r), _ in cases:
    pub.publish(t, p, qos=1, retain=r).wait_for_publish(5)
time.sleep(2)
# a fresh subscriber sees only what the broker retained
sub2 = _client("t-fresh", fresh, True)
time.sleep(2)

fails = 0
for (t, p, r), (et, ep, er) in cases:
    v = live.get(et)
    ok = v is not None and (ep is None or v == ep)
    if et.endswith("sys/meta") and v is not None:
        try:
            meta = json.loads(v)
            ok = ok and meta["fw_version"] == "1.3.8" and meta["contract"] == 1
        except Exception:
            ok = False
    f = fresh.get(et)
    if er:
        ok = ok and f is not None and f[1] is True and (ep is None or f[0] == ep)
        note = "retained" if f else "NOT retained"
    else:
        ok = ok and f is None
        note = "not retained" if f is None else f"UNEXPECTEDLY retained {f}"
    print(("PASS" if ok else "FAIL"), f"{t} -> {et} = {v!r} [{note}]")
    fails += 0 if ok else 1

# a desired without stage must NOT publish control/mode
before = live.get("pomona/control/mode")
pub.publish("demeter/pomona-0001/desired", json.dumps({"targets": {}}), qos=1, retain=True).wait_for_publish(5)
time.sleep(1)
after = live.get("pomona/control/mode")
print(("PASS" if before == after else "FAIL"), "desired without stage leaves control/mode alone", after)
fails += 0 if before == after else 1
# nothing translated twice (a loop would show a v2 topic under pomona/ or vice versa)
loops = [k for k in live if k.startswith("pomona/demeter/") or k.startswith("demeter/pomona-0001/pomona/")]
print(("PASS" if not loops else "FAIL"), "no double translation", loops)
fails += 1 if loops else 0
for c in (sub, sub2, pub):
    c.loop_stop()
print("FAILS", fails)
sys.exit(1 if fails else 0)
