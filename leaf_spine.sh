#!/usr/bin/env bash
# Architecture B : fabrique leaf-spine, underlay eBGP + ECMP + BFD, overlay VXLAN / BGP EVPN.
# FRR (adresses underlay, BGP, EVPN, BFD) est configuré par configs/<noeud>/frr.conf ;
# ce script crée ce que FRR ne crée pas : MTU, ponts, VXLAN, VRF, passerelles anycast, hôtes.
LAB=clab-dc-ls
RATE=${RATE-1gbit}           # même plafond que dans A (l2.sh)
ANYCAST_MAC=02:00:00:00:00:01
x() { docker exec "$LAB-$1" "${@:2}"; }

# underlay : MTU 9000 (VXLAN ajoute 50 octets), plafond de débit, routage, hachage ECMP sur L4
underlay() {
    node=$1; ports=$2
    x $node sysctl -qw net.ipv4.ip_forward=1
    x $node sysctl -qw net.ipv4.fib_multipath_hash_policy=1
    for p in $ports; do
        x $node ip link set $p mtu 9000 up
        [ -n "$RATE" ] && x $node tc qdisc replace dev $p root tbf rate $RATE burst 512k latency 20ms
    done
}

# leaf : un pont vlan-aware, un VXLAN par L2VNI, un VRF + L3VNI par locataire, passerelle anycast
#   VLAN : L2VNI : sous-réseau        VRF    : L3VNI (VLAN interne)
SEGMENTS="10:10010:VRF-T1 11:10011:VRF-T1 20:10020:VRF-T2 21:10021:VRF-T2"
TENANTS="VRF-T1:50001:4001:1001 VRF-T2:50002:4002:1002"   # VRF:L3VNI:VLAN:table

vxlan_up() {  # node vni vlan
    node=$1; vni=$2; vlan=$3
    x $node ip link add vxlan$vni type vxlan id $vni local $LO dstport 4789 nolearning
    x $node ip link set vxlan$vni master br0
    x $node bridge vlan del dev vxlan$vni vid 1
    x $node bridge vlan add dev vxlan$vni vid $vlan pvid untagged
    # EVPN fournit les MAC distantes : pas d'apprentissage, suppression ARP locale
    x $node bridge link set dev vxlan$vni learning off neigh_suppress on
    x $node ip link set vxlan$vni up
}

leaf_up() {
    node=$1; LO=$2; h1=$3; h2=$4     # h1/h2 = "port:vlan" des hôtes
    underlay $node "eth1 eth2"
    for d in br0 VRF-T1 VRF-T2; do x $node ip link del $d 2>/dev/null; done
    for v in 10010 10011 10020 10021 50001 50002; do x $node ip link del vxlan$v 2>/dev/null; done

    x $node ip link add br0 type bridge vlan_filtering 1 stp_state 0
    x $node ip link set br0 up

    for t in $TENANTS; do
        IFS=: read vrf vni vlan table <<< "$t"
        x $node ip link add $vrf type vrf table $table
        x $node ip link set $vrf up
        vxlan_up $node $vni $vlan
        # SVI du L3VNI : sa MAC (unique par leaf) sert de router-MAC EVPN
        x $node bridge vlan add dev br0 vid $vlan self
        x $node ip link add link br0 name vlan$vlan type vlan id $vlan
        x $node ip link set vlan$vlan master $vrf up
    done

    for s in $SEGMENTS; do
        IFS=: read vlan vni vrf <<< "$s"
        vxlan_up $node $vni $vlan
        # passerelle anycast : même IP .1 et même MAC sur tous les leaf
        x $node bridge vlan add dev br0 vid $vlan self
        x $node ip link add link br0 name vlan$vlan type vlan id $vlan
        x $node ip link set vlan$vlan address $ANYCAST_MAC
        x $node bridge fdb replace $ANYCAST_MAC dev br0 vlan $vlan self local
        x $node ip link set vlan$vlan master $vrf
        x $node ip addr add 192.168.$vlan.1/24 dev vlan$vlan
        x $node ip link set vlan$vlan up
    done

    for a in $h1 $h2; do
        p=${a%%:*}; v=${a##*:}
        x $node ip link set $p mtu 1500 master br0 up
        x $node bridge vlan del dev $p vid 1
        x $node bridge vlan add dev $p vid $v pvid untagged
    done
}

underlay spine1 "eth1 eth2 eth3 eth4"
underlay spine2 "eth1 eth2 eth3 eth4"
#      node   loopback    hôte L1   hôte L2
leaf_up leaf1 10.0.0.11  "eth3:10" "eth4:20"
leaf_up leaf2 10.0.0.12  "eth3:10" "eth4:20"
leaf_up leaf3 10.0.0.13  "eth3:11" "eth4:21"
leaf_up leaf4 10.0.0.14  "eth3:11" "eth4:21"

# hôtes : identiques à l2.sh (EF5)
setip() {
    x $1 ip addr flush dev eth1
    x $1 ip addr add $2/24 dev eth1
    x $1 ip link set eth1 mtu 1500 up
    x $1 ip route replace 192.168.0.0/16 via ${2%.*}.1
}
setip client1 192.168.10.11   # h11  Locataire 1  leaf1
setip client3 192.168.10.12   # h12  Locataire 1  leaf2
setip client5 192.168.11.13   # h13  Locataire 1  leaf3
setip client7 192.168.11.14   # h14  Locataire 1  leaf4
setip client2 192.168.20.21   # h21  Locataire 2  leaf1
setip client4 192.168.20.22   # h22  Locataire 2  leaf2
setip client6 192.168.21.23   # h23  Locataire 2  leaf3
setip client8 192.168.21.24   # h24  Locataire 2  leaf4
sleep 10
