#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Check if wlan0 is connected
if ! iw dev wlan0 link | grep -q "Connected to"; then
    echo "Error: wlan0 is not connected to a network"
    echo "Please connect to a WiFi network first"
    exit 1
fi

# Install required packages
apt-get update
apt-get install -y hostapd dnsmasq

# Stop services to prevent conflicts
systemctl stop hostapd
systemctl stop dnsmasq

# Check if wlan1 interface exists, if not create it
if ! iw dev | grep -q "wlan1"; then
    echo "Creating wlan1 interface..."
    # Create the interface with a different MAC address to avoid conflicts
    iw phy phy0 interface add wlan1 type __ap
    ip link set dev wlan1 address $(printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
fi

# Configure hostapd
cat >/etc/hostapd/hostapd.conf <<EOF
interface=wlan1
driver=nl80211
ssid=robot
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=robot
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# Configure dnsmasq
cat >/etc/dnsmasq.conf <<EOF
interface=wlan1
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
EOF

# Configure network interface
cat >/etc/network/interfaces.d/wlan1 <<EOF
auto wlan1
iface wlan1 inet static
    address 192.168.4.1
    netmask 255.255.255.0
EOF

# Enable IP forwarding
echo 1 >/proc/sys/net/ipv4/ip_forward

# Configure NAT
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -A FORWARD -i wlan1 -o wlan0 -j ACCEPT
iptables -A FORWARD -i wlan0 -o wlan1 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Save iptables rules
apt-get install -y iptables-persistent
netfilter-persistent save

# Start services
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq
systemctl start hostapd
systemctl start dnsmasq

# Verify wlan0 is still connected
if ! iw dev wlan0 link | grep -q "Connected to"; then
    echo "Warning: wlan0 connection was lost. Attempting to reconnect..."
    systemctl restart networking
fi

echo "Access point setup complete!"
echo "SSID: robot"
echo "Password: robot"
echo "Note: wlan0 is used for normal WiFi connection, wlan1 is used for the access point"
