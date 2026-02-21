#!/usr/bin/env bash
# One-time setup script: migrate Orange Pi from bridge to NAT router
# Run manually once, then reboot.

set -e

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# 1. Remove bridge configuration
log "Removing bridge configuration..."
nmcli con delete br0 2>/dev/null || true
nmcli con delete br0-eth0 2>/dev/null || true
nmcli con delete br0-usb 2>/dev/null || true
nmcli con delete "Wired connection 1" 2>/dev/null || true
nmcli con delete "Wired connection 2" 2>/dev/null || true

# 2. Configure WAN interface (to provider)
log "Configuring WAN interface (enx00e04c176c60)..."
nmcli con delete wan 2>/dev/null || true
nmcli con add type ethernet ifname enx00e04c176c60 con-name wan \
    ipv4.method auto \
    connection.autoconnect yes

# 3. Configure LAN interface (to Keenetic)
log "Configuring LAN interface (eth0)..."
nmcli con delete lan 2>/dev/null || true
nmcli con add type ethernet ifname eth0 con-name lan \
    ipv4.method manual \
    ipv4.addresses 10.10.10.1/24 \
    ipv6.method disabled \
    connection.autoconnect yes

# 4. Enable IP forwarding
log "Enabling IP forwarding..."
echo "net.ipv4.ip_forward=1" | sudo tee /etc/sysctl.d/99-nat.conf
sudo sysctl -w net.ipv4.ip_forward=1

# 5. Install and configure dnsmasq
log "Installing dnsmasq..."
sudo apt-get update && sudo apt-get install -y dnsmasq

log "Configuring dnsmasq..."
sudo mkdir -p /etc/dnsmasq.d
cat <<'EOF' | sudo tee /etc/dnsmasq.d/lan.conf
# Orange Pi NAT - DHCP server on LAN (eth0)
interface=eth0
bind-dynamic
dhcp-range=10.10.10.100,10.10.10.200,24h
dhcp-option=option:router,10.10.10.1
dhcp-option=option:dns-server,8.8.8.8,1.1.1.1
EOF

sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

# 6. Remove br_netfilter (no longer needed)
log "Removing br_netfilter module autoload..."
sudo rm -f /etc/modules-load.d/br_netfilter.conf
sudo rm -f /etc/sysctl.d/99-bridge.conf

# 7. Activate interfaces
log "Activating interfaces..."
nmcli con up wan || log "WARNING: WAN interface not connected yet"
nmcli con up lan || log "WARNING: LAN interface not connected yet"

log "NAT setup complete. Reboot recommended."
log "After reboot:"
log "  - Connect Keenetic WAN port to Orange Pi eth0"
log "  - Keenetic should get IP 10.10.10.x via DHCP"
log "  - Start zapret2 service: systemctl start zapret_discord_youtube"
