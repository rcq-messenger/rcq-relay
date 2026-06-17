#!/usr/bin/env bash
# Lock down an EXISTING RCQ relay so it stops being an open internet proxy.
#
# A relay set up before this change forwards to ANY destination the connecting
# client asks for. Since relay credentials are handed out by the broker and
# shared in chats, anyone can point a normal VLESS client at the relay and surf
# the open internet (VK, torrents, …) from the operator's IP. This adds an
# outbound allow-list (RCQ islands + this relay's masquerade host only) and
# rejects everything else — WITHOUT touching the relay's keys/UUID/port, so
# every already-shared token keeps working, just for RCQ traffic only.
#
#   curl -fsSL https://raw.githubusercontent.com/rcq-messenger/rcq-relay/main/relay-lockdown.sh | sudo bash
#   # self-hosting your own island? allow its hostname too:
#   curl -fsSL …/relay-lockdown.sh | sudo RCQ_ISLANDS="island.example.com" bash
#
# Safe: the new config is validated with `sing-box check` BEFORE it replaces the
# live one. If validation fails, nothing changes and the relay keeps running.
set -euo pipefail

CONF="/etc/sing-box/config.json"
[ -f "$CONF" ] || { echo "no $CONF — is this an RCQ relay set up by relay-bootstrap.sh?"; exit 1; }

# Bring sing-box up to the version this config targets (the bootstrap installs
# from the sagernet repo; route-rule `action` needs a current build).
if command -v apt-get >/dev/null 2>&1; then
    apt-get install -y --only-upgrade sing-box >/dev/null 2>&1 || true
fi

RCQ_ISLANDS="${RCQ_ISLANDS:-}" python3 - "$CONF" <<'PY'
import json, os, sys
conf = sys.argv[1]
c = json.load(open(conf))
# Masquerade host this relay already presents (REALITY server_name) — keep it
# reachable so the anti-probing handshake forwarding can't be collateral-blocked.
sni = c.get("inbounds", [{}])[0].get("tls", {}).get("server_name", "")
suffixes = ["rcq.app"]
for d in os.environ.get("RCQ_ISLANDS", "").split(","):
    d = d.strip()
    if d:
        suffixes.append(d)
rules = [{"domain_suffix": suffixes, "outbound": "direct"}]
if sni:
    rules.append({"domain": [sni], "outbound": "direct"})
rules.append({"ip_cidr": ["165.232.69.229/32", "165.22.95.218/32"], "outbound": "direct"})
rules.append({"action": "reject"})   # default-deny everything else (no open proxy)
c.setdefault("outbounds", [{"type": "direct", "tag": "direct"}])
c["route"] = {"rules": rules}
json.dump(c, open(conf + ".new", "w"), indent=2)
print(f"  allow: domain_suffix={suffixes}" + (f", masquerade={sni}" if sni else ""))
PY

if sing-box check -c "$CONF.new"; then
    cp -f "$CONF" "$CONF.bak-preLockdown"
    mv -f "$CONF.new" "$CONF"
    systemctl reload sing-box 2>/dev/null || systemctl restart sing-box
    echo "==> LOCKED DOWN + reloaded. Backup: $CONF.bak-preLockdown"
    echo "    The relay now forwards ONLY to RCQ; general internet is rejected."
else
    rm -f "$CONF.new"
    echo "!! sing-box check FAILED — config NOT changed, relay untouched."
    echo "   Send me the error above (and \`sing-box version\`) and I'll fix the rule syntax."
    exit 1
fi
