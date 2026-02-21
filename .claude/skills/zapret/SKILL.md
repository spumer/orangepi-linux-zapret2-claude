---
description: >
  This skill should be used when the user asks about zapret2 (nfqws2), creating Lua
  DPI bypass strategies, configuring nftables for NFQUEUE interception, interpreting
  blockcheck2.sh results, migrating from zapret1 to zapret2, translating Flowseal .bat
  strategies to zapret2, setting up transparent bridge or NAT router for DPI bypass,
  writing NFQWS2_OPT config, or troubleshooting blocked YouTube/Discord.
  Triggers on: /zapret, "zapret", "nfqws2", "DPI bypass", "обход блокировок",
  "blockcheck", "стратегия zapret", "NFQWS2_OPT", "nftables NFQUEUE",
  "bridge vs NAT", "Flowseal", "YouTube blocked", "YouTube не работает".
---

# Skill: zapret2 DPI Bypass Expert

When invoked, you must:

1. **Determine intent**: creating/adapting strategy / diagnosing blockage / interpreting blockcheck2 /
   configuring nftables / setting up bridge or NAT / translating Flowseal .bat
2. **Determine platform**: NAT router / transparent bridge / OpenWrt / regular Linux / Windows
3. **If bridge mode**: warn about technique limitations BEFORE suggesting strategies
4. **If the user needs precise function signatures**, fetch from GitHub:
   - `https://raw.githubusercontent.com/bol-van/zapret2/master/lua/zapret-antidpi.lua`
   - `https://raw.githubusercontent.com/bol-van/zapret2/master/docs/manual.en.md`

For detailed references, read these files from the skill directory:
- `references/flowseal-translation.md` — Flowseal .bat → zapret2 parameter mapping
- `references/nftables-rules.md` — nftables rules for NAT, bridge, Windows
- `references/function-reference.md` — zapret-antidpi.lua function reference

---

## Architecture

zapret2 = **nfqws2** (C core) + **Lua strategies** + **utilities**.

- **nfqws2**: intercepts packets via NFQUEUE (Linux) or WinDivert (Windows). Handles protocol
  detection, host/IP lists, connection tracking. Does NOT modify traffic — Lua does that.
- **Lua**: `zapret-lib.lua` (helpers), `zapret-antidpi.lua` (attacks), `zapret-auto.lua` (orchestration).
- **Blobs**: binary files loaded via `--blob=name:@path`. Built-in defaults always available:
  `fake_default_tls`, `fake_default_http`, `fake_default_quic`. User blobs MUST NOT reuse these names.

### How functions are called

```
--lua-desync=funcname:arg1=val1:arg2:arg3=val3
```
- Arguments separated by colons. Boolean flags have no `=value`.
- `--new` separates profiles. First matching profile wins.

### Profile filtering chain

Each profile filters traffic in this order:
```
--filter-tcp=PORT → --filter-l7=PROTO → --payload=TYPE → --hostlist=FILE → --lua-desync=...
```

- `--filter-tcp=<ports>` / `--filter-udp=<ports>` — match by destination port
- `--filter-l7=tls|http|quic|discord|stun` — match by detected L7 protocol. **Omitting means match any protocol on that port** — usually wrong, always specify
- `--payload=tls_client_hello|quic_initial|http_req` — which payload type triggers the lua-desync functions. Without it, desync fires on every packet, not just the handshake
- `--hostlist=<file>` / `--hostlist-domains=<list>` — domain filtering
- `--ipset=<file>` — IP-based filtering (fallback when SNI unavailable)

---

## Bridge vs NAT: Real-World Comparison

### Technique Compatibility

| Technique | Bridge | NAT |
|-----------|--------|-----|
| multisplit / multidisorder | YES | YES |
| fake (inject fake packets) | **NO** | YES |
| fakedsplit / fakeddisorder | **NO** | YES |
| seqovl (sequence overlap) | **NO** | YES |
| wssize (window size) | **NO** | YES |

**Why fake doesn't work on bridge**: bridge intercepts in FORWARD chain but sends fakes via
raw socket from OUTPUT chain. Timing mismatch → DPI sees them out of order or ignores them.

**Recommendation**: Always prefer NAT. Modern Russian ISP DPI (2025+) requires fake + seqovl.
Use bridge only if you cannot change network topology AND splitting alone bypasses your DPI.

### NAT Router Setup (one-time)

Key steps (full details in deployment guide):
1. Configure WAN (DHCP) and LAN (static 10.10.10.1/24) via nmcli
2. Enable IP forwarding: `/etc/sysctl.d/99-nat.conf`
3. Install dnsmasq with `bind-dynamic` (NOT `bind-interfaces` — see gotchas)
4. Add static DHCP lease for downstream router MAC
5. systemd service for main_script.sh

nftables rules created by service at each start: NAT table (masquerade + DMZ) + zapret table
(POSTNAT scheme: postnat/pre/predefrag chains). See `references/nftables-rules.md`.

---

## Strategy System

Strategies live in `strategies/` directory. Each is a `.sh` file sourced by `main_script.sh`.

### Strategy file format

```bash
# strategies/my_strategy.sh
# Required: TCP_PORTS/UDP_PORTS (for nftables), BLOB_OPTS, STRATEGY

TCP_PORTS="80,443,2053,2083,2087,2096,8443"
UDP_PORTS="443,19294-19344,50000-50100"

# Blobs — $NFQWS2_FAKES, $FLOWSEAL_BIN expanded at source time
BLOB_OPTS="--blob=quic_google:@$NFQWS2_FAKES/quic_initial_www_google_com.bin ..."

# Profiles — $LISTS_DIR stays literal, expanded by eval at runtime
read -r -d '' STRATEGY << 'EOF' || true
--filter-tcp=443 --filter-l7=tls --hostlist=$LISTS_DIR/list-general.txt --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000:repeats=8 --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google
--new
--filter-udp=443 --filter-l7=quic --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11
EOF
```

**Note on heredoc**: `read -r -d '' STRATEGY << 'EOF' || true` — the `|| true` is required
because `-d ''` causes non-zero exit. Do not simplify this line.

### Switching strategies

```bash
# Change conf.env: strategy=my_new_strategy
systemctl restart zapret_discord_youtube

# Or test temporarily:
/opt/zapret-scripts/main_script.sh -strategy my_new_strategy
```

---

## Creating and Adapting Strategies

### Profile ordering (CRITICAL — first match wins)

```
1. Most specific:  --hostlist-domains=discord.media        (single domain)
2. Specific list:  --hostlist=list-google.txt               (short list)
3. General list:   --hostlist=list-general.txt              (large list)
4. IP fallback:    --ipset=ipset-all.txt                    (IPs without SNI)
```

Common mistake: general `--filter-tcp=443` above specific Discord profile → Discord never
reaches its dedicated profile.

### Technique selection

| Situation | Technique |
|-----------|-----------|
| Basic DPI (first packet) | `multisplit:pos=1,midsld` |
| Smart DPI (reassembles) | `fake` + `multisplit` with `seqovl` |
| Aggressive DPI | `fake:tcp_seq=N:tls_mod=rnd,dupsid,sni=X` |
| QUIC blocked | `fake:blob=quic_google:repeats=6-11` |
| Discord voice/video | `fake:blob=zero_256:repeats=6` on 19294-19344 |
| Late blocking (10KB stall) | `wssize:wsize=1:scale=6` |

### Fooling selection

| Fooling | Reliability | Notes |
|---------|------------|-------|
| `tcp_seq=10000000` | **HIGH** | Server rejects (wrong seq), DPI accepts. Best choice |
| `tcp_md5` | **HIGH** | Server ignores (RFC), DPI skips TCP options |
| `badsum` | MEDIUM | Some NICs do checksum offload — may pass with bad sum |
| `ip_ttl=N` | LOW | Must guess hop count |

### Conflict detection

Profiles conflict when same protocol + port + host matches multiple profiles.
Debug: run nfqws2 without `--daemon`, watch stdout for profile matching.

---

## Translating Flowseal .bat → zapret2

For the full parameter mapping table and worked example, read `references/flowseal-translation.md`.

Key principles:
1. `--dpi-desync=fake,multisplit` → two separate `--lua-desync=fake:... --lua-desync=multisplit:...`
2. File paths → blob names: load with `--blob=name:@path`, reference as `blob=name`
3. Global fooling → per-function args on each `--lua-desync`
4. `--wf-tcp`/`--wf-udp` not needed (nftables handles ports)
5. Add `--filter-l7=tls` and `--payload=tls_client_hello` (zapret2 needs explicit L7 filter)
6. `--new` separators map 1:1

---

## Critical Gotchas

### 1. `pkill -f nfqws2` kills SSH sessions
`pkill -f` matches FULL command line — including your SSH session containing "nfqws2".
**Fix**: Always `pkill -x nfqws2` (exact binary name match).

### 2. nftables `!=` in double-quoted bash strings
`"mark and $FWMARK != 0x00000000"` — bash expands `!` as history.
**Fix**: Don't double-quote: `mark and $FWMARK != 0x00000000 notrack`

### 3. dnsmasq `bind-interfaces` fails at boot
dnsmasq starts before NetworkManager brings up eth0: "unknown interface eth0".
**Fix**: Use `bind-dynamic` instead of `bind-interfaces` in `/etc/dnsmasq.d/lan.conf`.

### 4. WAN DHCP timeout during bridge→NAT migration
Deleting bridge + activating WAN with cables connected → DHCP timeout.
**Fix**: Configure everything with cables disconnected, then reconnect physically.

### 5. DMZ IP mismatch with DHCP
`dnat to 10.10.10.2` but router got `10.10.10.190` via DHCP.
**Fix**: Add static lease: `dhcp-host=MAC,10.10.10.190,router`. Check: `cat /var/lib/misc/dnsmasq.leases`

### 6. Blob name conflicts with built-ins
`--blob=fake_default_quic:@path` → "duplicate blob name".
**Fix**: Use custom names (`quic_google`). Reserved: `fake_default_tls`, `fake_default_http`, `fake_default_quic`.

### 7. Strategy works locally but not for forwarded traffic
nftables postnat chain must have `priority srcnat + 1` (not `srcnat`).
The `+1` ensures nfqws2 sees traffic AFTER masquerade.

---

## blockcheck2.sh

```bash
BATCH=1 DOMAINS="youtube.com discord.com" ./blockcheck2.sh | tee /tmp/bc.log
```

Results: `OK` = works, `AVAILABLE` = not blocked, `curl exit 28` = timeout (blocked).

**Important**: blockcheck2 tests OUTPUT chain (local traffic). On NAT router, forwarded
traffic goes through postnat chain (srcnat+1) which may behave differently.

---

## Diagnostic Checklist

```bash
ps aux | grep nfqws2                              # nfqws2 running?
sudo nft list ruleset | grep -E "packets [1-9]"   # traffic hitting queue?
journalctl -u zapret_discord_youtube | grep "Loaded strategy"  # which strategy?
curl -s --max-time 10 -o /dev/null -w '%{http_code}\n' https://youtube.com  # test
sudo nft list table ip nat                         # NAT/DMZ rules?
cat /var/lib/misc/dnsmasq.leases                   # DHCP leases
```

For function reference, read `references/function-reference.md`.
