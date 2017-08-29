#!/bin/bash
# Deploy single client VPNs on failover IPs
# Very useful for home servers

# Server configuraiton
vpnname="" # Give a lowercase simple VPN name
localip="" # Listening IP local and public

# Both configuration
port="1194" # Default 1194
proto="udp" # Protocol: udp better ping, tcp better packet delivery
routing="tun" # Routing: routed tunnel (tun) or ethernet tunnel (tap)
vpnsubnet="10.8.0.0" # VPN subnet (IP range)
vpnnetmask="255.255.255.0" # VPN Netmask

# Client configuration
clientconnectip="${localip}" # The IP clients will connect to; default set to localip assuming it is public or reachable locally

# Firewall configuration
failover="${localip}" # Server listening public IP
vpnnetwork="${vpnsubnet}/24" # VPN Network, default 10.8.0.0/24
vpnclient="10.8.0.2" # Expected failover IP

if [ -z "${vpnname}" ]||[ -z "${localip}" ]; then
	echo "This script is non-interactive, please edit the configuration at its beginning."
	exit
fi

apt update
apt -y install openvpn easy-rsa

# easy-rsa
echo "Copying easy-rsa"
cp -r /usr/share/easy-rsa/ /etc/openvpn
chown -R root:root /etc/openvpn/easy-rsa/

# Key generation
echo "Building keys (might take a while)"
cd /etc/openvpn/easy-rsa/ || echo "Cannot cd into easy-rsa dir"; exit
source vars
./clean-all
./build-dh
./pkitool --initca
./pkitool --server server
openvpn --genkey --secret keys/ta.key
./build-key ${vpnname}-client

echo "Creating directories"
mkdir -pv "/etc/openvpn/server/${vpnname}"
mkdir -pv "/etc/openvpn/client/${vpnname}"
echo "Copying keys"
cp keys/ca.crt keys/ta.key keys/server.crt keys/server.key keys/dh2048.pem "/etc/openvpn/server/${vpnname}"
cp keys/ca.crt keys/ta.key keys/${vpnname}-client.crt keys/${vpnname}-client.key "/etc/openvpn/client/${vpnname}"

echo "Creating jail"
mkdir -pv /etc/openvpn/jail/tmp

echo "Generating config file: ${vpnname}.conf"

echo "# Local listening IP
local ${localip}
# Local listening port (default 1194)
port ${port}
# Protocol: udp/tcp
proto ${proto}
# Routing: routed tunnel (tun) or ethernet tunnel (tap)
dev ${routing}
# VPN Subnet
server ${vpnsubnet} ${vpnnetmask}
# Used cipher from: BF-CBC; AES-128-CBC; AES-256-CBC; DES-EDE3-CBC
cipher AES-256-CBC
# Pïng every X seconds and assume down after Y seconds
keepalive 10 60
# Compression
comp-lzo no
# Disable buffering
sndbuf 0
rcvbuf 0

# Restrict VPN rights...
user nobody
group nogroup
chroot /etc/openvpn/jail
# ...and avoid issues upon restart
persist-key
persist-tun

# Try to maintain the same IP for clients
ifconfig-pool-persist ipp.txt
# Route clients traffic through VPN
push \"redirect-gateway def1 bypass-dhcp\"
# Push OpenDNS DNS
push \"dhcp-option DNS 208.67.222.222\"
push \"dhcp-option DNS 208.67.220.220\"

# Certificates
ca server/${vpnname}/ca.crt
cert server/${vpnname}/server.crt
key server/${vpnname}/server.key
dh server/${vpnname}/dh2048.pem
tls-auth server/${vpnname}/ta.key 0

# Short status log
status ${vpnname}-status.log
# Full log
log-append /var/log/openvpn-cloud.log
# Verbosity: 0 lowest, 9 max
verb 6
# Silence repeated messages after X occurrences
mute 20" > /etc/openvpn/${vpnname}.conf

# Generating firewall script
touch "/etc/openvpn/firewall_${vpnname}.sh"
echo '#!/bin/bash' > "/etc/openvpn/firewall_${vpnname}.sh"
echo "# This simple script is intended to route traffic from a VPN through a failover IP

# Script

if [ -z \"$1\" ]; then
        echo \"Info! Please specify enable or disable\"
        exit
fi
if [ \"$1\" != \"enable\" ]&&[ \"${1}\" != \"disable\" ];then
        echo \"Info! Please specify enable or disable\"
        exit
fi

# Enable rule
if [ \"$1\" == \"enable\" ];then
	echo \"Enable VPN rules\"
	# Allow forward
	echo \"Allowing forwarding\"
	echo 1 > /proc/sys/net/ipv4/ip_forward

	# Apply table
	echo \"Applying iptables:\"
	echo \" -> Redirect failover: ${failover} to client: ${vpnclient} on network: ${vpnnetwork}\"
	# Any traffic incoming to the failover IP is routed into the VPN client
	iptables -t nat -A PREROUTING -d \"${failover}\" -j DNAT --to-destination \"${vpnclient}\"
	# Anything traffic sent by the VPN network to outside the VPN network is routed through the failover IP
	iptables -t nat -A POSTROUTING -s \"${vpnnetwork}\" ! -d \"${vpnnetwork}\" -j SNAT --to-source \"${failover}\"
	echo \"[OK] Job done\"
	exit
fi

# Disable rules
if [ \"$1\" == \"disable\" ];then
	echo \"Disable VPN rules\"
	# Disallow forward
	echo \"Disallow forwarding\"
	echo 0 > /proc/sys/net/ipv4/ip_forward

	# Remove table
	echo \"Removing iptables:\"
	echo \" <- Redirect failover: ${failover} to client: ${vpnclient} on network: ${vpnnetwork}\"
	iptables -t nat -D PREROUTING -d \"${failover}\" -j DNAT --to-destination \"${vpnclient}\"
	iptables -t nat -D POSTROUTING -s \"${vpnnetwork}\" ! -d \"${vpnnetwork}\" -j SNAT --to-source \"${failover}\"

	echo \"[OK] Job done\"
	exit
fi\"" >> "/etc/openvpn/firewall_${vpnname}.sh"
chmod +x "/etc/openvpn/firewall_${vpnname}.sh"

# Client config
echo "Generating client config"



# Starting services
echo "Stop and start new vpn instance"
systemctl stop openvpn@${vpnname}.service
systemctl start openvpn@${vpnname}.service
echo "Enabling firewall redirect to failover"
/etc/openvpn/firewall_${vpnname}.sh enable
