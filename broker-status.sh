#!/usr/bin/env bash
#
# Show the status of YOUR relays as the RCQ broker sees them: is each one being
# served to users right now, when the liveness canary last verified it alive, and
# how many times it has been handed out recently. Signs the request with the same
# persisted operator key relay-bootstrap.sh created.
#
#   sudo bash broker-status.sh
#
# Env: RCQ_BROKER (default https://api.rcq.app), RCQ_OPKEY (default the path the
# bootstrap script wrote).
set -euo pipefail

BROKER="${RCQ_BROKER:-https://api.rcq.app}"
OPKEY="${RCQ_OPKEY:-/etc/sing-box/rcq-operator-ed25519.b64}"

[ -r "$OPKEY" ] || { echo "operator key not found at $OPKEY (run relay-bootstrap.sh first, or set RCQ_OPKEY=)" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 required" >&2; exit 1; }
python3 -c "import cryptography" 2>/dev/null || { echo "python3-cryptography required (apt-get install -y python3-cryptography)" >&2; exit 1; }

RCQ_BROKER="$BROKER" OPKEY="$OPKEY" python3 - <<'PYEOF'
import os, json, time, base64, urllib.request, urllib.error
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives import serialization

key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(os.environ["OPKEY"]).read().strip()))
ts = int(time.time())
signed = json.dumps({"action": "status", "ts": ts}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
pub = base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode()
body = {"key": pub, "sig": base64.b64encode(key.sign(signed)).decode(), "ts": ts}
req = urllib.request.Request(os.environ["RCQ_BROKER"] + "/broker/status",
                            data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
try:
    data = json.loads(urllib.request.urlopen(req, timeout=15).read().decode())
except urllib.error.HTTPError as e:
    print("status query failed:", e.code, e.read().decode()); raise SystemExit(1)

rs = data.get("relays", [])
if not rs:
    print("No relays registered under this operator key yet."); raise SystemExit(0)
for r in rs:
    if not r["enabled"]:
        state = "DISABLED by an admin"
    elif r["serving"]:
        state = "SERVING ✓  — being handed to users right now"
    else:
        state = "NOT YET SERVED — waiting for the liveness canary to verify it (probes ~every 10 min)"
    age = r.get("last_ok_age_sec")
    age_s = f"{age}s ago" if age is not None else "never (not probed yet)"
    print(f"- {r.get('proto')} {r.get('server')}:{r.get('port')}  [{r['tier']}]")
    print(f"    {state}")
    print(f"    canary last verified alive: {age_s}    fails: {r['fail_count']}    handed out (~24h): {r['served_recent']}")
print("\n(The broker distributes relay descriptors, not traffic — 'handed out' is how often your relay")
print(" was given to clients, not live connections. Your relay's own sing-box sees actual connections.)")
PYEOF
