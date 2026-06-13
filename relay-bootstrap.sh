#!/usr/bin/env bash
#
# Stand up a fresh sing-box VLESS+Reality relay on a clean Ubuntu/Debian box,
# then self-register it with the RCQ broker so users start getting it
# automatically (no manual approval). This is the "гидра": the more relays
# people run, the harder RCQ is to block.
#
# Run it as root on a fresh VPS:
#   curl -fsSL https://raw.githubusercontent.com/rcq-messenger/rcq-relay/main/relay-bootstrap.sh | bash
#   (or: scp this file to the box and run `bash relay-bootstrap.sh`)
#
# What it does:
#   1. Installs sing-box from the official channel
#   2. Generates a fresh Reality keypair + uuid + short_id
#   3. Writes the server config to /etc/sing-box/config.json
#   4. Opens TCP 443 (ufw + iptables)
#   5. Enables + starts the systemd unit
#   6. Prints the relay parameters
#   7. Registers the relay with the RCQ broker (skip with RCQ_NO_REGISTER=1)
#
# Options: RCQ_RELAY_SNI (Reality SNI, default www.microsoft.com),
#          RCQ_RELAY_PORT (default 443), RCQ_NO_REGISTER=1 (don't auto-register),
#          RCQ_BROKER (default https://api.rcq.app).
#
# Tested on: Oracle Cloud Free Tier Ubuntu 22.04 ARM/AMD, AWS Lightsail.
# Idempotent — re-running on the same box re-generates fresh creds but keeps the
# SAME broker registration (operator key at /etc/sing-box/rcq-operator-ed25519.b64).

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Run as root (or via 'sudo bash')" >&2
    exit 1
fi

SNI="${RCQ_RELAY_SNI:-www.microsoft.com}"
PORT="${RCQ_RELAY_PORT:-443}"

echo "==> Installing sing-box"
if ! command -v sing-box >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y curl jq ca-certificates gpg
    curl -fsSL https://sing-box.app/gpg.key \
        | gpg --dearmor -o /usr/share/keyrings/sagernet.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/sagernet.gpg] https://deb.sagernet.org/ * *" \
        > /etc/apt/sources.list.d/sagernet.list
    apt-get update -y
    apt-get install -y sing-box
fi

echo "==> Generating Reality keypair + short_id + uuid"
KEYS_JSON=$(sing-box generate reality-keypair)
PRIVATE_KEY=$(echo "$KEYS_JSON" | awk -F': ' '/PrivateKey/ {print $2}' | tr -d '[:space:]')
PUBLIC_KEY=$(echo "$KEYS_JSON" | awk -F': ' '/PublicKey/ {print $2}' | tr -d '[:space:]')
UUID=$(sing-box generate uuid)
SHORT_ID=$(sing-box generate rand --hex 8)

if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" || -z "$UUID" || -z "$SHORT_ID" ]]; then
    echo "Key generation failed — sing-box CLI output unexpected" >&2
    echo "$KEYS_JSON"
    exit 1
fi

echo "==> Writing /etc/sing-box/config.json"
mkdir -p /etc/sing-box
cat > /etc/sing-box/config.json <<EOF
{
  "log": { "level": "warn" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $PORT,
      "users": [
        { "uuid": "$UUID", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "$SNI",
        "reality": {
          "enabled": true,
          "handshake": {
            "server": "$SNI",
            "server_port": 443
          },
          "private_key": "$PRIVATE_KEY",
          "short_id": ["$SHORT_ID"]
        }
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

if command -v ufw >/dev/null 2>&1 && ufw status | grep -qi active; then
    echo "==> ufw active, allowing $PORT/tcp"
    ufw allow "$PORT/tcp" || true
fi

# Oracle Cloud quirk: their default Ubuntu image ships with
# `iptables -P INPUT DROP` plus a saved rules file. Even after VCN
# security-list ingress is opened, the host blocks $PORT. Punch a
# hole + persist it. Harmless on non-Oracle hosts.
if command -v iptables >/dev/null 2>&1; then
    if ! iptables -C INPUT -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null; then
        echo "==> iptables: inserting ACCEPT for $PORT/tcp"
        iptables -I INPUT 1 -p tcp --dport "$PORT" -j ACCEPT
        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save || true
        elif [[ -d /etc/iptables ]]; then
            iptables-save > /etc/iptables/rules.v4 || true
        fi
    fi
fi

echo "==> Enabling + restarting sing-box"
systemctl enable sing-box >/dev/null 2>&1 || true
systemctl restart sing-box

sleep 2
if ! systemctl is-active --quiet sing-box; then
    echo "sing-box failed to start — journalctl -u sing-box --no-pager -n 50" >&2
    journalctl -u sing-box --no-pager -n 50
    exit 1
fi

PUBLIC_IP=$(curl -s4 ifconfig.me || curl -s4 ipv4.icanhazip.com || hostname -I | awk '{print $1}')

echo
echo "===================================================="
echo "  RELAY READY — your relay parameters"
echo "===================================================="
echo "  server      $PUBLIC_IP"
echo "  port        $PORT"
echo "  uuid        $UUID"
echo "  flow        xtls-rprx-vision"
echo "  sni         $SNI"
echo "  public_key  $PUBLIC_KEY"
echo "  short_id    $SHORT_ID"
echo
echo "  Smoke test from your Mac:"
echo "    nc -z -v -w 5 $PUBLIC_IP $PORT"
echo "    curl -kI https://$PUBLIC_IP/   # expect HTTP 400 (Reality masquerade)"
echo "===================================================="

# ── гидра: self-register with the RCQ broker (no manual approval needed) ──────
# The relay signs a descriptor with a fresh, persisted operator key and POSTs it
# to the broker. Users then get this relay distributed to them automatically.
# Default ON; skip with RCQ_NO_REGISTER=1. Override the broker with RCQ_BROKER=.
BROKER="${RCQ_BROKER:-https://api.rcq.app}"
if [ -z "${RCQ_NO_REGISTER:-}" ]; then
    echo
    echo "==> Registering with the RCQ broker ($BROKER)"
    command -v python3 >/dev/null 2>&1 || apt-get install -y python3 >/dev/null 2>&1 || true
    python3 -c "import cryptography" 2>/dev/null || apt-get install -y python3-cryptography >/dev/null 2>&1 || true
    OPKEY=/etc/sing-box/rcq-operator-ed25519.b64   # persisted: a re-run refreshes the SAME registration
    RCQ_BROKER="$BROKER" OPKEY="$OPKEY" SERVER="$PUBLIC_IP" PORT="$PORT" SNI="$SNI" \
    UUID="$UUID" PBK="$PUBLIC_KEY" SID="$SHORT_ID" python3 - <<'PYEOF'
import os, json, time, base64, urllib.request, urllib.error
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
except Exception:
    raise SystemExit("   (python3-cryptography missing — register later with broker-register.py)")
opk = os.environ["OPKEY"]
if os.path.exists(opk):
    key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(opk).read().strip()))
else:
    key = Ed25519PrivateKey.generate()
    open(opk, "w").write(base64.b64encode(key.private_bytes_raw()).decode()); os.chmod(opk, 0o600)
desc = {"proto": "vless", "server": os.environ["SERVER"], "port": int(os.environ["PORT"]),
        "sni": os.environ["SNI"], "uuid": os.environ["UUID"], "pbk": os.environ["PBK"],
        "sid": os.environ["SID"], "flow": "xtls-rprx-vision"}
ts = int(time.time())
signed = json.dumps({"descriptor": desc, "ts": ts}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
body = {"descriptor": desc, "key": base64.b64encode(key.public_key().public_bytes_raw()).decode(),
        "sig": base64.b64encode(key.sign(signed)).decode(), "ts": ts}
req = urllib.request.Request(os.environ["RCQ_BROKER"] + "/broker/register",
        data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
try:
    print("   broker:", urllib.request.urlopen(req, timeout=15).read().decode())
except urllib.error.HTTPError as e:
    print("   broker register failed:", e.code, e.read().decode())
except Exception as e:
    print("   broker register error:", e)
PYEOF
    echo "  Your relay is registered. Operator key: $OPKEY (keep it to refresh later)."
fi
echo "===================================================="
