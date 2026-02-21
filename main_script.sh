#!/usr/bin/env bash
set -e

# ============================================================================
# Orange Pi 3B — NAT router mode with zapret2 (nfqws2 + Lua)
#
# Network topology:
#   Provider → [WAN_IFACE] → Orange Pi (NAT) → [LAN_IFACE] → Keenetic (DMZ)
#
# POSTNAT scheme: nfqws2 intercepts traffic after NAT in postrouting chain
#
# Strategy is loaded from strategies/ directory (see conf.env for active one)
# ============================================================================

# --- Paths ---
BASE_DIR="$(realpath "$(dirname "$0")")"
NFQWS_PATH="/opt/zapret2/nfq2/nfqws2"
NFQWS2_LUA="/opt/zapret2/lua"
NFQWS2_FAKES="/opt/zapret2/files/fake"
FLOWSEAL_BIN="$BASE_DIR/zapret-latest/bin"
LISTS_DIR="$BASE_DIR/zapret-latest/lists"
STRATEGIES_DIR="$BASE_DIR/strategies"
STOP_SCRIPT="$BASE_DIR/stop_and_clean_nft.sh"
CONF_ENV="$BASE_DIR/conf.env"

# --- Network ---
WAN_IFACE="enx00e04c176c60"
LAN_IFACE="eth0"
KEENETIC_IP="10.10.10.190"

# --- nftables defaults (strategy can override TCP_PORTS / UDP_PORTS) ---
FWMARK="0x40000000"
QNUM=220
MAX_PKT_OUT=20
MAX_PKT_IN=15
TCP_PORTS="80,443"
UDP_PORTS="443"

# --- Debug ---
DEBUG=false

# --- Strategy name (set via conf.env or -strategy flag) ---
STRATEGY_NAME=""

# ============================================================================
# Utility functions
# ============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

debug_log() {
    if $DEBUG; then
        echo "[DEBUG] $1"
    fi
}

handle_error() {
    log "ERROR: $1"
    exit 1
}

check_dependencies() {
    local deps=("nft" "sysctl")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" >/dev/null 2>&1; then
            handle_error "Missing dependency: $dep"
        fi
    done
    if [ ! -x "$NFQWS_PATH" ]; then
        handle_error "nfqws2 not found at $NFQWS_PATH"
    fi
}

# ============================================================================
# Configuration
# ============================================================================

load_conf() {
    if [ -f "$CONF_ENV" ]; then
        # Read network config
        local val
        val=$(grep -E '^wan_iface=' "$CONF_ENV" | cut -d= -f2-)
        [ -n "$val" ] && WAN_IFACE="$val"
        val=$(grep -E '^lan_iface=' "$CONF_ENV" | cut -d= -f2-)
        [ -n "$val" ] && LAN_IFACE="$val"
        val=$(grep -E '^keenetic_ip=' "$CONF_ENV" | cut -d= -f2-)
        [ -n "$val" ] && KEENETIC_IP="$val"

        # Read strategy if not set via command line
        if [ -z "$STRATEGY_NAME" ]; then
            val=$(grep -E '^strategy=' "$CONF_ENV" | cut -d= -f2-)
            [ -n "$val" ] && STRATEGY_NAME="$val"
        fi
    fi

    if [ -z "$STRATEGY_NAME" ]; then
        handle_error "No strategy specified. Set 'strategy=...' in conf.env or use -strategy NAME"
    fi
}

load_strategy() {
    local strategy_file="$STRATEGIES_DIR/$STRATEGY_NAME.sh"
    if [ ! -f "$strategy_file" ]; then
        handle_error "Strategy not found: $strategy_file"
    fi

    # Strategy file sets: BLOB_OPTS, STRATEGY, and optionally TCP_PORTS, UDP_PORTS
    source "$strategy_file"

    if [ -z "$BLOB_OPTS" ]; then
        handle_error "Strategy '$STRATEGY_NAME' must define BLOB_OPTS"
    fi
    if [ -z "$STRATEGY" ]; then
        handle_error "Strategy '$STRATEGY_NAME' must define STRATEGY"
    fi

    log "Loaded strategy: $STRATEGY_NAME"
    debug_log "TCP_PORTS=$TCP_PORTS UDP_PORTS=$UDP_PORTS"
}

# ============================================================================
# NAT setup (masquerade + DMZ)
# ============================================================================

setup_nat() {
    log "Setting up NAT (masquerade + DMZ to $KEENETIC_IP)..."

    # Ensure IP forwarding is enabled
    sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

    # Remove existing NAT table if present
    if sudo nft list tables | grep -q "ip nat"; then
        sudo nft delete table ip nat
    fi

    sudo nft add table ip nat

    # Masquerade outgoing traffic on WAN
    sudo nft add chain ip nat postrouting "{ type nat hook postrouting priority srcnat; }"
    sudo nft add rule ip nat postrouting oifname "$WAN_IFACE" masquerade

    # DMZ: forward all incoming NEW connections to Keenetic
    sudo nft add chain ip nat prerouting "{ type nat hook prerouting priority dstnat; }"
    sudo nft add rule ip nat prerouting iifname "$WAN_IFACE" ct state new dnat to "$KEENETIC_IP"

    log "NAT configured: masquerade on $WAN_IFACE, DMZ to $KEENETIC_IP"
}

# ============================================================================
# nftables for zapret2 (POSTNAT scheme per manual.en.md:381-417)
# ============================================================================

setup_nftables_zapret() {
    local table_name="inet zapretunix"

    log "Setting up nftables for zapret2 (POSTNAT scheme)..."

    # Remove existing zapret table if present
    if sudo nft list tables | grep -q "$table_name"; then
        sudo nft delete table $table_name
    fi

    sudo nft add table $table_name

    # --- POSTNAT chain: outgoing traffic after NAT (srcnat + 1) ---
    sudo nft add chain $table_name postnat "{ type filter hook postrouting priority srcnat + 1; }"

    # TCP outgoing: first N packets of each connection
    sudo nft add rule $table_name postnat \
        oifname "$WAN_IFACE" meta mark and $FWMARK == 0 \
        tcp dport "{$TCP_PORTS}" \
        ct original packets 1-$MAX_PKT_OUT \
        counter queue num $QNUM bypass

    # UDP outgoing: first N packets
    sudo nft add rule $table_name postnat \
        oifname "$WAN_IFACE" meta mark and $FWMARK == 0 \
        udp dport "{$UDP_PORTS}" \
        ct original packets 1-5 \
        counter queue num $QNUM bypass

    # TCP FIN/RST (for conntrack)
    sudo nft add rule $table_name postnat \
        oifname "$WAN_IFACE" meta mark and $FWMARK == 0 \
        tcp dport "{$TCP_PORTS}" \
        "tcp flags fin,rst" \
        counter queue num $QNUM bypass

    # --- PRE chain: incoming traffic (for wssize cutoff, SYN+ACK, RST/FIN) ---
    sudo nft add chain $table_name pre "{ type filter hook prerouting priority filter; }"

    # TCP incoming: first N reply packets
    sudo nft add rule $table_name pre \
        iifname "$WAN_IFACE" \
        tcp sport "{$TCP_PORTS}" \
        ct reply packets 1-$MAX_PKT_IN \
        counter queue num $QNUM bypass

    # TCP SYN+ACK
    sudo nft add rule $table_name pre \
        iifname "$WAN_IFACE" \
        tcp sport "{$TCP_PORTS}" \
        "tcp flags & (syn | ack) == (syn | ack)" \
        counter queue num $QNUM bypass

    # TCP FIN/RST incoming
    sudo nft add rule $table_name pre \
        iifname "$WAN_IFACE" \
        tcp sport "{$TCP_PORTS}" \
        "tcp flags fin,rst" \
        counter queue num $QNUM bypass

    # UDP incoming replies
    sudo nft add rule $table_name pre \
        iifname "$WAN_IFACE" \
        udp sport "{$UDP_PORTS}" \
        ct reply packets 1-3 \
        counter queue num $QNUM bypass

    # --- PREDEFRAG chain: notrack for nfqws2-generated packets ---
    # Prevents NAT validity checks from dropping modified packets
    sudo nft add chain $table_name predefrag "{ type filter hook output priority -401; }"
    sudo nft add rule $table_name predefrag \
        mark and $FWMARK != 0x00000000 notrack

    log "nftables zapret2 configured: postnat + pre + predefrag chains on $WAN_IFACE"
}

# ============================================================================
# nfqws2 launch
# ============================================================================

start_nfqws2() {
    log "Starting nfqws2 (strategy: $STRATEGY_NAME)..."
    sudo pkill -x nfqws2 2>/dev/null || true
    sleep 1

    local lua_opts="--lua-init=@$NFQWS2_LUA/zapret-lib.lua --lua-init=@$NFQWS2_LUA/zapret-antidpi.lua --lua-init=@$NFQWS2_LUA/zapret-auto.lua"

    # Flatten strategy to single line
    local strategy_flat
    strategy_flat=$(echo "$STRATEGY" | tr '\n' ' ' | sed 's/  */ /g')

    debug_log "nfqws2 full command: $NFQWS_PATH --daemon --bind-fix4 --bind-fix6 --fwmark=$FWMARK --qnum=$QNUM $lua_opts $BLOB_OPTS $strategy_flat"

    eval "sudo $NFQWS_PATH --daemon --bind-fix4 --bind-fix6 --fwmark=$FWMARK --qnum=$QNUM $lua_opts $BLOB_OPTS $strategy_flat" ||
        handle_error "Failed to start nfqws2"

    log "nfqws2 started successfully"
}

# ============================================================================
# Cleanup
# ============================================================================

cleanup() {
    sudo /usr/bin/env bash "$STOP_SCRIPT"
}

# ============================================================================
# Main
# ============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -debug)
            DEBUG=true
            shift
            ;;
        -strategy)
            STRATEGY_NAME="$2"
            shift 2
            ;;
        *)
            break
            ;;
        esac
    done

    # Load configuration and strategy
    load_conf
    load_strategy

    check_dependencies

    # Stop previous instance
    cleanup
    sleep 1

    # Setup network rules
    setup_nat
    setup_nftables_zapret

    # Launch nfqws2
    start_nfqws2

    log "Setup complete. NAT + zapret2 active (strategy: $STRATEGY_NAME)."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"

    trap cleanup SIGINT SIGTERM

    sleep infinity &
    wait
fi
