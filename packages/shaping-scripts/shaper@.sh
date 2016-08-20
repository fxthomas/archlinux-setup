#!/bin/bash

# Usage: shaper.sh <interface> [up|down]
#
# This script is intended to be used as a NetworkManager-Dispatcher script, see
# networkmanager(8) for more information.

# Show executed commands for easier debugging
# set -x

# Store command arguments
IFNAME=$1        # Interface name
IFSTATUS=$2      # Interface status (up or down)

####################
# General settings #
####################

# Maximum upload speed (in kbps)
MAX_UPLOAD=85

# Pretty names for each class
CLASS_LAN=10
CLASS_WAN=11
CLASS_WAN1=110
CLASS_WAN2=130
CLASS_WAN3=150
CLASS_WAN4=170
CLASS_WAN1_DNS=111
CLASS_WAN1_TCP=112
CLASS_WAN1_IPSEC_CONTROL=113
CLASS_WAN1_OTHERS=129
CLASS_WAN2_WEB=131
CLASS_WAN2_SSH=132
CLASS_WAN2_SUBSONIC=133
CLASS_WAN2_MAIL=134
CLASS_WAN2_IPSEC_PAYLOAD=135
CLASS_WAN2_OTHERS=149

# Local networks to use when filtering local packets.
LOCALNET_IPV4=192.168.1.0/24
LOCALNET_IPV6=fe80::

###############
# Main script #
###############

function ip64tables() {
  iptables $*
  ip6tables $*
}

# Clear iptables rules
function ip64tables_clear() {
  ip64tables -t mangle -D POSTROUTING -j shaping >/dev/null 2>&1
  ip64tables -t mangle -F shaping >/dev/null 2>&1
  ip64tables -t mangle -X shaping >/dev/null 2>&1
}

# Initialize shaping rules
function ip64tables_init() {
  echo "Initializing shaping tables..."
  ip64tables_clear
  ip64tables -t mangle -N shaping
  ip64tables -t mangle -A POSTROUTING -j shaping
  accept_mark
}

# Filter packets for both IPv4 and IPv6
function rule() {
  ip64tables -t mangle -A shaping -o $IFNAME $*
}

# Trace packets in the syslog
function trace() {
  ip64tables -A PREROUTING -t raw $* -j TRACE
  ip64tables -A OUTPUT -t raw -o $IFNAME $* -j TRACE
}

# Accept marked packets and return from the iptables chain without processing
# other rules.
function accept_mark() {
  ip64tables -t mangle -A shaping -m mark ! --mark 0 -j RETURN
}

# Create a new TC class with the ceil parameter being the same as the rate
# parameter.
#
# Usage: create_max_class <name> <rate> [parent]
function create_max_class() {
  CLASS_NAME=$1
  CLASS_RATE=$2
  CLASS_PARENT=$3
  tc class add dev $IFNAME parent 1:${CLASS_PARENT} classid 1:${CLASS_NAME} htb rate ${CLASS_RATE} ceil ${CLASS_RATE}
  tc qdisc add dev $IFNAME parent 1:${CLASS_NAME} handle ${CLASS_NAME}: sfq perturb 10
  tc filter add dev $IFNAME parent 1: prio ${CLASS_NAME} handle ${CLASS_NAME} fw flowid 1:${CLASS_NAME}
}

# Create a new TC class
#
# Usage: create_class <name> <rate> [parent]
function create_class() {
  CLASS_NAME=$1
  CLASS_RATE=$2
  CLASS_PARENT=$3
  tc class add dev $IFNAME parent 1:${CLASS_PARENT} classid 1:${CLASS_NAME} htb rate ${CLASS_RATE} ceil ${MAX_UPLOAD}kbps
  tc qdisc add dev $IFNAME parent 1:${CLASS_NAME} handle ${CLASS_NAME}: sfq perturb 10
  tc filter add dev $IFNAME parent 1: prio ${CLASS_NAME} handle ${CLASS_NAME} fw flowid 1:${CLASS_NAME}
}

# If the interface is being brought up, then clear all existing rules and setup
# traffic shaping for this interface.
if [[ $IFSTATUS == "up" ]]; then

  echo "Enabling traffic shaping on $IFNAME..."

  # Make sure forwarding is enabled
  echo "Enabling forwarding on interface $IFNAME..."
  sysctl net.ipv4.ip_forward=1
  sysctl net.ipv6.conf.default.forwarding=1
  sysctl net.ipv6.conf.all.forwarding=1

  # Create or replace the root qdisc by an HTB qdisc, defaulting to the class
  # with the least important priority (1:112).
  echo "Adding root qdisc on interface $IFNAME..."
  tc qdisc del dev $IFNAME root 2> /dev/null
  tc qdisc add dev $IFNAME root handle 1: htb default $CLASS_WAN2 r2q 1

  # Create the root classs, i.e. the ones that are attached to the root qdisc
  # directly. Root classes cannot borrow bandwidth from another root class, so
  # they are well-suited for separating local and internet traffic.
  #
  # Each tc class is written x:y, where x is the qdisc id, and y the class id.
  # Here, we create one class (1:10) for local traffic and another (1:11) for
  # internet traffic.
  echo "Creating LAN/WAN classes on interface $IFNAME..."
  create_max_class $CLASS_LAN 1gbit
  create_class $CLASS_WAN ${MAX_UPLOAD}kbps

  # The local traffic should be more than fine without supervision, but the
  # internet traffic needs some prioritization. We create subclasses of the
  # root internet class, each able to borrow from the others if there is enough
  # available bandwidth.
  create_class $CLASS_WAN1 10kbps  ${CLASS_WAN}
  create_class $CLASS_WAN2 70kbps  ${CLASS_WAN}
  create_class $CLASS_WAN3 5kbps   ${CLASS_WAN}
  create_class $CLASS_WAN4 5kbps   ${CLASS_WAN}

  # Traffic-specific classes
  create_class $CLASS_WAN1_DNS            1kbps   $CLASS_WAN1
  create_class $CLASS_WAN1_TCP            1kbps   $CLASS_WAN1
  create_class $CLASS_WAN1_IPSEC_CONTROL  1kbps   $CLASS_WAN1
  create_class $CLASS_WAN1_OTHERS         1kbps   $CLASS_WAN1
  create_class $CLASS_WAN2_WEB            1kbps   $CLASS_WAN2
  create_class $CLASS_WAN2_SSH            1kbps   $CLASS_WAN2
  create_class $CLASS_WAN2_SUBSONIC       1kbps   $CLASS_WAN2
  create_class $CLASS_WAN2_MAIL           1kbps   $CLASS_WAN2
  create_class $CLASS_WAN2_IPSEC_PAYLOAD  1kbps   $CLASS_WAN2
  create_class $CLASS_WAN2_OTHERS         1kbps   $CLASS_WAN2

  # Initialize iptable rules
  echo "Adding traffic categorization rules..."
  ip64tables_init

  # Priority 1: Match local or tunnelled packets.
  iptables  -t mangle -A shaping -m policy --dir out --pol ipsec -j MARK --set-mark $CLASS_WAN2_IPSEC_PAYLOAD
  ip6tables -t mangle -A shaping -m policy --dir out --pol ipsec -j MARK --set-mark $CLASS_WAN2_IPSEC_PAYLOAD
  accept_mark
  iptables  -t mangle -A shaping -o $IFNAME -d $LOCALNET_IPV4 -j MARK --set-mark $CLASS_LAN
  ip6tables -t mangle -A shaping -o $IFNAME -d $LOCALNET_IPV6 -j MARK --set-mark $CLASS_LAN
  accept_mark

  # Priority 5: Bittorrent traffic
  rule -m owner --uid-owner transmission -j MARK --set-mark $CLASS_WAN4
  accept_mark

  # Priority 2: Match high-priority packets (ICMP, DNS and small FIN/ACK/SYN).
  rule -p tcp --dport 53   -j MARK --set-mark $CLASS_WAN1_DNS
  rule -p udp --dport 53   -j MARK --set-mark $CLASS_WAN1_DNS
  rule -p icmp             -j MARK --set-mark $CLASS_WAN1_OTHERS
  rule -p udp --sport 500  -j MARK --set-mark $CLASS_WAN1_IPSEC_CONTROL
  accept_mark
  rule -p tcp --tcp-flags FIN,SYN,RST,ACK ACK -m length --length 0:60 -j MARK --set-mark $CLASS_WAN1_TCP
  rule -p tcp --tcp-flags FIN,SYN,RST,ACK RST,ACK                     -j MARK --set-mark $CLASS_WAN1_TCP
  rule -p tcp --tcp-flags FIN,SYN,RST,ACK SYN,ACK                     -j MARK --set-mark $CLASS_WAN1_TCP
  rule -p tcp --tcp-flags FIN,SYN,RST,ACK FIN,ACK                     -j MARK --set-mark $CLASS_WAN1_TCP
  rule -p tcp --tcp-flags FIN,SYN,RST,ACK RST                         -j MARK --set-mark $CLASS_WAN1_TCP
  accept_mark

  # Priority 3: Match intermediate-priority packets.
  rule -p esp              -j MARK --set-mark $CLASS_WAN2_IPSEC_PAYLOAD
  rule -p udp --sport 4500 -j MARK --set-mark $CLASS_WAN2_IPSEC_PAYLOAD
  rule -p tcp --dport 1723 -j MARK --set-mark $CLASS_WAN2_OTHERS
  rule -p tcp --sport 1723 -j MARK --set-mark $CLASS_WAN2_OTHERS
  rule -p tcp --dport 5001 -j MARK --set-mark $CLASS_WAN2_OTHERS
  rule -p udp --dport 5001 -j MARK --set-mark $CLASS_WAN2_OTHERS
  rule -p tcp --dport 993  -j MARK --set-mark $CLASS_WAN2_MAIL
  rule -p tcp --dport 443  -j MARK --set-mark $CLASS_WAN2_WEB
  rule -p tcp --sport 443  -j MARK --set-mark $CLASS_WAN2_WEB
  rule -p tcp --dport 4443 -j MARK --set-mark $CLASS_WAN2_SUBSONIC
  rule -p tcp --sport 4443 -j MARK --set-mark $CLASS_WAN2_SUBSONIC
  rule -p tcp --dport 80   -j MARK --set-mark $CLASS_WAN2_WEB
  rule -p tcp --sport 80   -j MARK --set-mark $CLASS_WAN2_WEB
  rule -p tcp --dport 22   -j MARK --set-mark $CLASS_WAN2_SSH
  rule -p tcp --sport 22   -j MARK --set-mark $CLASS_WAN2_SSH
  accept_mark

  # Priority 4: Match low-priority packets with the default class, and save the
  # final connection mark.
  rule -j MARK --set-mark $CLASS_WAN3

  # Packet tracing
  #trace -p udp --sport 4500
  #trace -p udp --sport 500

  echo "Done, traffic shaping is enabled on $IFNAME."

# If the interface is being brought down, clear all traffic shaping rules.
elif [[ $IFSTATUS == "down" ]]; then
  echo "Disabling traffic shaping on $IFNAME..."
  echo "Clearing root qdisc..."
  tc qdisc del dev $IFNAME root 2> /dev/null
  echo "Clearing shaping tables..."
  ip64tables_clear
  echo "Done, traffic shaping is disabled on $IFNAME."

# If the status is anything else, exit with an error.
else
  echo "Invalid interface status: $IFSTATUS"
  exit 1
fi
