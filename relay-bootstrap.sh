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

# Outbound is LOCKED to RCQ destinations only — the relay must NOT be an open
# proxy. Without this, anyone with the relay's credentials (they're handed out
# by the broker + shared in chats) can point a normal VLESS client at it and
# surf the open internet from YOUR IP (VK, torrents, whatever) — the operator
# eats the abuse/legal exposure. The allow-list is the RCQ islands (every
# *.rcq.app + any you add via RCQ_ISLANDS) plus this relay's own masquerade host;
# everything else is rejected. Self-hosting your own island? Add its hostname:
#   RCQ_ISLANDS="island.example.com,island2.example.com" curl -fsSL …|bash
ISLAND_JSON='"rcq.app"'
IFS=',' read -ra _RCQ_ISL <<< "${RCQ_ISLANDS:-}"
for _d in "${_RCQ_ISL[@]}"; do
    _d="$(printf '%s' "$_d" | tr -d '[:space:]')"
    [ -n "$_d" ] && ISLAND_JSON="$ISLAND_JSON, \"$_d\""
done

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
  ],
  "route": {
    "rules": [
      { "domain_suffix": [ $ISLAND_JSON ], "outbound": "direct" },
      { "domain": ["$SNI"], "outbound": "direct" },
      { "ip_cidr": ["165.232.69.229/32", "165.22.95.218/32"], "outbound": "direct" },
      { "action": "reject" }
    ]
  }
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
# Address that clients + the broker's liveness canary dial. Defaults to the
# detected public IP. For a HOME / DYNAMIC-IP relay (DDNS) set
# RCQ_RELAY_HOST=your.ddns.example so the relay registers the HOSTNAME — the
# broker re-resolves it at probe time, so the registration survives IP changes
# (an IP registration silently goes stale and stops being served when the IP
# rotates). Port-forward your relay PORT on the router to this box.
SERVER_ADDR="${RCQ_RELAY_HOST:-$PUBLIC_IP}"

echo
echo "===================================================="
echo "  RELAY READY — your relay parameters"
echo "===================================================="
echo "  server      $SERVER_ADDR"
echo "  port        $PORT"
echo "  uuid        $UUID"
echo "  flow        xtls-rprx-vision"
echo "  sni         $SNI"
echo "  public_key  $PUBLIC_KEY"
echo "  short_id    $SHORT_ID"
echo
echo "  Smoke test — run it from OUTSIDE your LAN (e.g. your phone on mobile data,"
echo "  not the same network as the relay; home NAT often can't hairpin to itself):"
echo "    nc -z -v -w 5 $SERVER_ADDR $PORT          # port reachable?"
echo "    curl -kI --resolve $SNI:$PORT:$PUBLIC_IP https://$SNI:$PORT/"
echo "      ^ hits the relay on its REAL port with the masquerade SNI, so REALITY"
echo "        forwards to the genuine $SNI and you get ITS response (e.g. 400/200)."
echo "        Plain 'curl https://IP/' tests port 443, NOT your relay port — ignore it."
echo "  In journalctl, 'REALITY: processed invalid connection' is NORMAL — it's the"
echo "  relay rejecting scanners/your router/curl that don't speak the RCQ handshake."
echo
echo "  This relay forwards ONLY to RCQ (every *.rcq.app island"${RCQ_ISLANDS:+", $RCQ_ISLANDS"}") — it is"
echo "  NOT an open internet proxy, so its credentials can't be abused to surf the"
echo "  open web (VK, torrents, …) from your IP."
echo "===================================================="

# Shareable token — paste it into an RCQ group/chat and members tap Add. This is
# the censorship-resistant social distribution path: it works even if the broker
# auto-registration below is blocked from THIS box (e.g. domestic hosting whose
# egress to api.rcq.app is filtered), and it reaches a whole community group at
# once. Matches the rcq-relay:// format the clients parse (ContactRelayStore).
SHARE_TOKEN="rcq-relay://vless?s=${SERVER_ADDR}&p=${PORT}&sni=${SNI}&id=${UUID}&pbk=${PUBLIC_KEY}&sid=${SHORT_ID}&fl=xtls-rprx-vision"
echo
echo "  SHARE THIS RELAY directly (paste into an RCQ group/chat; members tap Add):"
echo "    $SHARE_TOKEN"
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
    RCQ_BROKER="$BROKER" OPKEY="$OPKEY" SERVER="$SERVER_ADDR" PORT="$PORT" SNI="$SNI" \
    UUID="$UUID" PBK="$PUBLIC_KEY" SID="$SHORT_ID" python3 - <<'PYEOF'
import os, json, time, base64, urllib.request, urllib.error
try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives import serialization
except Exception:
    raise SystemExit("   (python3-cryptography missing — register later with broker-register.py)")
opk = os.environ["OPKEY"]
key = None
if os.path.exists(opk):
    try:
        key = Ed25519PrivateKey.from_private_bytes(base64.b64decode(open(opk).read().strip()))
    except Exception:
        key = None  # empty/corrupt key file (e.g. left behind by an earlier failed run) -> regenerate
if key is None:
    key = Ed25519PrivateKey.generate()
    open(opk, "w").write(base64.b64encode(key.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption())).decode()); os.chmod(opk, 0o600)
desc = {"proto": "vless", "server": os.environ["SERVER"], "port": int(os.environ["PORT"]),
        "sni": os.environ["SNI"], "uuid": os.environ["UUID"], "pbk": os.environ["PBK"],
        "sid": os.environ["SID"], "flow": "xtls-rprx-vision"}
ts = int(time.time())
signed = json.dumps({"descriptor": desc, "ts": ts}, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
body = {"descriptor": desc, "key": base64.b64encode(key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)).decode(),
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
