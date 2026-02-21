#!/usr/bin/env bash
# Stop nfqws2 and clean up all nftables tables created by zapret scripts

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

log "Stopping nfqws2..."
sudo pkill -x nfqws2 2>/dev/null || true

log "Cleaning up nftables..."

# Remove zapret2 table
if sudo nft list tables | grep -q "inet zapretunix"; then
    sudo nft delete table inet zapretunix
    log "Deleted table inet zapretunix"
fi

# Remove NAT table
if sudo nft list tables | grep -q "ip nat"; then
    sudo nft delete table ip nat
    log "Deleted table ip nat"
fi

log "Cleanup complete."
