#!/bin/bash

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root"
    exit 1
fi

# Install required packages
apt-get update
apt-get install -y hostapd dnsmasq

# Stop services to prevent conflicts
systemctl stop hostapd
systemctl stop dnsmasq

# Configure hostapd
cat >/etc/hostapd/hostapd.conf <<EOF
interface=wlan0
driver=nl80211
ssid=MyAccessPoint
hw_mode=g
channel=7
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=MySecurePassword
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

# Configure dnsmasq
cat >/etc/dnsmasq.conf <<EOF
interface=wlan0
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,24h
EOF

# Configure network interface
cat >/etc/network/interfaces.d/wlan0 <<EOF
auto wlan0
iface wlan0 inet static
    address 192.168.4.1
    netmask 255.255.255.0
EOF

# Enable IP forwarding
echo 1 >/proc/sys/net/ipv4/ip_forward

# Configure NAT
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Save iptables rules
apt-get install -y iptables-persistent
netfilter-persistent save

# Start services
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq
systemctl start hostapd
systemctl start dnsmasq

echo "Access point setup complete!"
echo "SSID: MyAccessPoint"
echo "Password: MySecurePassword"
