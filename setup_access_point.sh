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
apt-get install -y hostapd dnsmasq openssh-server

# Stop services to prevent conflicts
systemctl stop hostapd
systemctl stop dnsmasq
systemctl stop ssh

# Remove any existing dnsmasq leases
rm -f /var/lib/misc/dnsmasq.leases

# Create necessary directories
mkdir -p /etc/network/interfaces.d
mkdir -p /etc/hostapd
mkdir -p /var/lib/misc

# Check if wlan1 interface exists, if not create it
if ! iw dev | grep -q "wlan1"; then
    echo "Creating wlan1 interface..."
    # Create the interface with a different MAC address to avoid conflicts
    iw phy phy0 interface add wlan1 type __ap
    ip link set dev wlan1 address $(printf '02:%02x:%02x:%02x:%02x:%02x' $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)) $((RANDOM % 256)))
fi

# Make sure wlan1 is up and has no IP address
ip link set wlan1 down
ip addr flush dev wlan1
ip link set wlan1 up

# Get the current channel of wlan0 to avoid interference
CURRENT_CHANNEL=$(iw dev wlan0 info | grep channel | awk '{print $2}')
if [ -z "$CURRENT_CHANNEL" ]; then
    CURRENT_CHANNEL=7
fi

# Configure hostapd with minimal settings
cat >/etc/hostapd/hostapd.conf <<EOF
interface=wlan1
driver=nl80211
ssid=robot
hw_mode=g
channel=$CURRENT_CHANNEL
wmm_enabled=1
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=1
wpa_passphrase=superrobot
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
country_code=US
ieee80211d=1
ieee80211h=1
logger_syslog=-1
logger_syslog_level=2
logger_stdout=-1
logger_stdout_level=2
ctrl_interface=/var/run/hostapd
ctrl_interface_group=0
# nl80211 specific options
ieee80211n=0
ht_capab=
EOF

# Configure dnsmasq with simpler settings
cat >/etc/dnsmasq.conf <<EOF
# Disable DNS server
port=0

# DHCP configuration
interface=wlan1
dhcp-range=192.168.4.2,192.168.4.20,255.255.255.0,12h
dhcp-option=3,192.168.4.1
dhcp-option=6,8.8.8.8,8.8.4.4
no-resolv
no-poll
log-queries
log-dhcp
listen-address=192.168.4.1
bind-interfaces
dhcp-authoritative
EOF

# Configure network interface
cat >/etc/network/interfaces.d/wlan1 <<EOF
auto wlan1
iface wlan1 inet static
    address 192.168.4.1
    netmask 255.255.255.0
    network 192.168.4.0
    broadcast 192.168.4.255
EOF

# Set up the IP address immediately
ip addr add 192.168.4.1/24 dev wlan1

# Enable IP forwarding
echo 1 >/proc/sys/net/ipv4/ip_forward

# Flush existing iptables rules
iptables -F
iptables -t nat -F
iptables -X
iptables -t nat -X

# Configure NAT and forwarding rules
iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
iptables -A FORWARD -i wlan1 -o wlan0 -j ACCEPT
iptables -A FORWARD -i wlan0 -o wlan1 -m state --state RELATED,ESTABLISHED -j ACCEPT

# Allow SSH traffic
iptables -A INPUT -i wlan1 -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -i wlan0 -p tcp --dport 22 -j ACCEPT

# Allow DNS and DHCP traffic
iptables -A INPUT -i wlan1 -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i wlan1 -p udp --dport 67:68 -j ACCEPT
iptables -A INPUT -i wlan1 -p tcp --dport 53 -j ACCEPT

# Save iptables rules
apt-get install -y iptables-persistent
netfilter-persistent save

# Configure hostapd to use our config file
echo "DAEMON_CONF=\"/etc/hostapd/hostapd.conf\"" >/etc/default/hostapd

# Configure SSH server
cat >/etc/ssh/sshd_config <<EOF
Port 22
Protocol 2
HostKey /etc/ssh/ssh_host_rsa_key
HostKey /etc/ssh/ssh_host_ecdsa_key
HostKey /etc/ssh/ssh_host_ed25519_key
UsePrivilegeSeparation yes
KeyRegenerationInterval 3600
ServerKeyBits 1024
SyslogFacility AUTH
LogLevel INFO
LoginGraceTime 120
PermitRootLogin yes
StrictModes yes
RSAAuthentication yes
PubkeyAuthentication yes
IgnoreRhosts yes
RhostsRSAAuthentication no
HostbasedAuthentication no
PermitEmptyPasswords no
ChallengeResponseAuthentication no
X11Forwarding yes
X11DisplayOffset 10
PrintMotd no
PrintLastLog yes
TCPKeepAlive yes
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
UsePAM yes
EOF

# Start services
systemctl unmask hostapd
systemctl enable hostapd
systemctl enable dnsmasq
systemctl enable ssh

# Check hostapd configuration
echo "Checking hostapd configuration..."
hostapd -d /etc/hostapd/hostapd.conf

# If debug mode was successful, start the service
if [ $? -eq 0 ]; then
    echo "Starting hostapd service..."
    systemctl start hostapd
    if [ $? -ne 0 ]; then
        echo "Failed to start hostapd service. Checking systemd logs..."
        journalctl -u hostapd -n 50
        exit 1
    fi

    echo "Starting dnsmasq service..."
    systemctl start dnsmasq
    if [ $? -ne 0 ]; then
        echo "Failed to start dnsmasq service. Checking systemd logs..."
        journalctl -u dnsmasq -n 50
        echo "Trying to start dnsmasq manually..."
        dnsmasq -C /etc/dnsmasq.conf --no-daemon
        exit 1
    fi

    echo "Starting SSH service..."
    systemctl start ssh
    if [ $? -ne 0 ]; then
        echo "Failed to start SSH service. Checking systemd logs..."
        journalctl -u ssh -n 50
        exit 1
    fi
else
    echo "Error: hostapd failed to start in debug mode"
    echo "Please check the error messages above"
    exit 1
fi

# Verify wlan0 is still connected
if ! iw dev wlan0 link | grep -q "Connected to"; then
    echo "Warning: wlan0 connection was lost. Attempting to reconnect..."
    systemctl restart networking
fi

# Check hostapd status
echo "Checking hostapd status..."
systemctl status hostapd

# Check hostapd logs
echo "Checking hostapd logs..."
journalctl -u hostapd -n 50

# Check dnsmasq status
echo "Checking dnsmasq status..."
systemctl status dnsmasq

# Check dnsmasq logs
echo "Checking dnsmasq logs..."
journalctl -u dnsmasq -n 50

# Check SSH status
echo "Checking SSH status..."
systemctl status ssh

# Check SSH logs
echo "Checking SSH logs..."
journalctl -u ssh -n 50

# Check network interfaces
echo "Checking network interfaces..."
ip addr show wlan1

# Check DHCP server status
echo "Checking DHCP server status..."
ps aux | grep dnsmasq

# Check iptables rules
echo "Checking iptables rules..."
iptables -L -n -v
iptables -t nat -L -n -v

echo "Access point setup complete!"
echo "SSID: robot"
echo "Password: superrobot"
echo "Note: wlan0 is used for normal WiFi connection, wlan1 is used for the access point"
echo "Clients should receive IP addresses in the range 192.168.4.2-192.168.4.20"
echo "To check connected devices, run: arp -a"
echo ""
echo "SSH Access:"
echo "1. Connect to the 'robot' WiFi network"
echo "2. SSH to 192.168.4.1 using: ssh root@192.168.4.1"
echo "3. The default root password is required for first login"
echo "4. For security, consider changing the root password after first login"
