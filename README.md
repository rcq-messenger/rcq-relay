# Run an RCQ relay (help people get through censorship)

This is the canonical home for the RCQ relay bootstrap. A **relay** is a blind
tunnel. It carries obfuscated traffic for RCQ users whose network blocks the app,
then forwards it on. It is the "гидра": the more relays people run, the harder RCQ
is to block, block one, the rest live.

**A relay never sees your messages.** Traffic is end-to-end encrypted, the sender
is hidden (sealed sender), and with onion routing on, a single relay cannot link
*who* to *which server*, it only sees opaque bytes passing through. Running one
exposes you to nothing about anyone's conversations.

## What you need
- A cheap VPS (1 vCPU / 1 GB is plenty), Ubuntu or Debian, **root** access.
- Port **443** open (TCP).
- That's it. No RCQ account, no approval step, your relay registers itself.

## One command

SSH into your fresh VPS as root and run:

```bash
curl -fsSL https://raw.githubusercontent.com/rcq-messenger/rcq-relay/main/relay-bootstrap.sh | bash
```

(or `scp` the script and run it locally). It will:
1. install sing-box,
2. generate fresh VLESS + Reality credentials,
3. open port 443,
4. start the relay as a systemd service,
5. **register itself with the RCQ broker**, so users start getting it
   automatically, with no manual approval.

When it finishes it prints your relay's parameters and confirms registration.

### Options
Pass these on the **bash** side of the pipe (a variable before `curl` never reaches the script). For example, to run on a non-443 port:
```
curl -fsSL https://raw.githubusercontent.com/rcq-messenger/rcq-relay/main/relay-bootstrap.sh | sudo RCQ_RELAY_PORT=8443 bash
```
- `RCQ_RELAY_PORT=443`, the port your relay listens on (default 443). Use another
  port if 443 is taken or you can only forward a different one (still works, 443
  is just the most innocuous).
- `RCQ_RELAY_SNI=www.yandex.ru`, the domain your relay impersonates (Reality).
  Pick a big, locally-popular HTTPS site. Default: `www.microsoft.com`. For a
  relay inside Russia, an intra-RF site like `www.yandex.ru` looks most innocuous.
- `RCQ_NO_REGISTER=1`, set up the relay but **don't** auto-register (you'll
  register manually later).
- `RCQ_BROKER=https://api.rcq.app`, the broker to register with (default).
- `RCQ_ISLANDS=island.example.com,island2.example.com`, extra island hostnames
  to allow if you self-host. The relay only forwards to RCQ (every `*.rcq.app`
  plus anything you list here) — see **Not an open proxy** below.

Re-running the script on the same box refreshes the **same** registration (it
keeps your operator key at `/etc/sing-box/rcq-operator-ed25519.b64`, back it up
if you want to move the relay later).

## Not an open proxy
Your relay forwards traffic ONLY to RCQ destinations (the islands). It is **not**
a general internet proxy: its credentials are shared widely (the broker hands
them out, users paste them into group chats), so without this lock-down anyone
could point a normal VLESS client at your relay and surf the open web — VK,
torrents, anything — from **your** IP, leaving you holding the abuse. The relay
rejects every destination that isn't an RCQ island.

**Already ran an older version of this script?** Those relays forward anywhere —
lock them down in place (keeps your keys, so shared tokens keep working):

```bash
curl -fsSL https://raw.githubusercontent.com/rcq-messenger/rcq-relay/main/relay-lockdown.sh | sudo bash
```

## How your relay reaches users
RCQ doesn't publish the whole relay list publicly (a censor would just block them
all). The **broker** hands relays out a few-at-a-time per request, bucketed by
network, so the pool can't be scraped wholesale. Your relay joins that pool and
is distributed to users who need a way through. A canary end-to-end-probes every
relay on a schedule and serves only the live ones, so a dead or unreachable relay
is simply not handed out, you don't need to babysit it.

## Trust & safety
- Community relays are used as **extra capacity / exit hops**; the metadata-
  sensitive **entry** hop stays on a vetted relay, so even a malicious relay
  learns nothing useful (with onion on, it can't see both your IP and your
  destination).
- A dead or unreachable relay is simply not handed out, you don't need to babysit
  it, but keeping it up helps people.

## Where to run it — region matters

A relay's value depends on **where** it sits relative to the people it helps.

- **Inside the censored country (e.g. a relay in Russia).** This is the most
  valuable kind. A blocked user reaches *you* over a short in-country hop that
  looks like ordinary HTTPS to a no-name host, far less conspicuous than a
  connection straight to a foreign VPN endpoint. **If you're in RF and run a
  relay, you directly help other people in RF get through.** In onion mode a
  domestic relay is the ideal entry (sees the user's IP, never the destination)
  or exit hop.
- **Outside the country.** Useful as the border-crossing hop and as an onion
  **exit** (sees the destination server, never the user's IP). Lower personal
  risk to run, but it does less to disguise that a domestic user is reaching
  *something* abroad.

**Onion (2-hop) splits the trust by design.** RCQ chains an ENTRY relay and an
EXIT relay so no single relay sees both ends: the entry sees `your IP → forward
to the exit` (it can't read the destination, it's sealed inside the exit's
tunnel); the exit sees `entry-IP → destination server` (never your IP). To your
relay, both single-hop and onion traffic just look like normal VLESS connections,
you can't even tell which role you're playing. So pick a region you're
comfortable in, and know that more **domestic** relays are what move the needle.

## Before you run one

- **No logs, nothing to hand over.** The relay keeps no traffic logs; the broker
  stores only your relay's public key + enabled/disabled state, never who
  registered it. Your VPS provider / upstream ISP still sees your box's traffic,
  so pick a provider you trust.
- **Jurisdiction.** A domestic relay carries more legal/physical risk to *you*
  (the same adversary your users face can reach your box). Run one where you're
  comfortable; if unsure, a foreign relay is lower-risk to operate.
- **Abuse / DoS.** Your relay has no per-IP limiting of its own; clients back off
  and fail over, but a flood can still hit your uplink, so use your provider's
  DDoS protection or cap bandwidth if needed.
- **It's disposable.** Seized, or just done? Delete
  `/etc/sing-box/rcq-operator-ed25519.b64` and redeploy fresh (or just stop, the
  canary drops a dead relay from rotation automatically). One relay dying costs
  the network nothing, that's the point.

Questions or a relay you want promoted to the trusted tier? Reach us in-app at
RCQ **#911** or `security@rcq.app`.
