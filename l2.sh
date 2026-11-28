#!/usr/bin/env bash
# Architecture A : 3 niveaux, ponts Linux + STP.
# Note : stp_state 1 = STP noyau Linux, c'est du 802.1D classique (pas RSTP).
LAB=clab-dc-l2
VLANS="10 11 20 21"
RATE=${RATE-1gbit}   # débit des liens inter-commutateurs ; RATE= ./l2.sh pour ne pas limiter
x() { docker exec "$LAB-$1" "${@:2}"; }

bridge_up() {
    node=$1; prio=$2; trunks=$3; access=$4
    x $node ip link del br0 2>/dev/null
    x $node ip link add br0 type bridge vlan_filtering 1 stp_state 1 priority $prio
    x $node ip link set br0 up

    # trunks: carry every VLAN, tagged
    for p in $trunks; do
        x $node ip link set $p master br0
        x $node ip link set $p up
        x $node bridge vlan del dev $p vid 1
        for v in $VLANS; do x $node bridge vlan add dev $p vid $v; done
        # même plafond qu'en B, sinon les veth (~25 Gbit/s) masquent l'apport d'ECMP
        [ -n "$RATE" ] && x $node tc qdisc replace dev $p root tbf rate $RATE burst 512k latency 20ms
    done

    # access ports: one VLAN, untagged
    for a in $access; do
        p=${a%%:*}; v=${a##*:}
        x $node ip link set $p master br0
        x $node ip link set $p up
        x $node bridge vlan del dev $p vid 1
        x $node bridge vlan add dev $p vid $v pvid untagged
    done
}

# passerelles sur agg1/agg2 : une SVI par VLAN, rangée dans le VRF du locataire.
# IP virtuelle .1 portée par agg1 (maître), agg1 = .2, agg2 = .3.
# Pas de démon VRRP dans l'image : la bascule de .1 vers agg2 n'est pas automatique.
gw_up() {
    node=$1; me=$2; master=$3
    x $node sysctl -qw net.ipv4.ip_forward=1
    for t in "VRF-T1 101 10 11" "VRF-T2 102 20 21"; do
        set -- $t; vrf=$1; table=$2; shift 2
        x $node ip link del $vrf 2>/dev/null
        x $node ip link add $vrf type vrf table $table
        x $node ip link set $vrf up
        for v in "$@"; do
            x $node bridge vlan add dev br0 vid $v self
            x $node ip link add link br0 name vlan$v type vlan id $v
            x $node ip link set vlan$v master $vrf
            x $node ip addr add 192.168.$v.$me/24 dev vlan$v
            [ $master = 1 ] && x $node ip addr add 192.168.$v.1/24 dev vlan$v
            x $node ip link set vlan$v up
        done
    done
}

#         node  prio    trunk ports                              access ports
bridge_up core1  4096  "eth1 eth2 eth3"                 ""
bridge_up core2  8192  "eth1 eth2 eth4"                 ""
bridge_up agg1  16384  "eth1 eth2 eth4 eth5 eth6 eth7"  ""
bridge_up agg2  20480  "eth2 eth3 eth4 eth5 eth6 eth7"  ""
bridge_up acc1  32768  "eth1 eth4"                      "eth2:10 eth3:20"
bridge_up acc2  32768  "eth1 eth4"                      "eth2:10 eth3:20"
bridge_up acc3  32768  "eth1 eth4"                      "eth2:11 eth3:21"
bridge_up acc4  32768  "eth1 eth4"                      "eth2:11 eth3:21"
gw_up agg1 2 1
gw_up agg2 3 0

# hôtes (plan 4.4 de la conception) ; route vers 192.168.0.0/16 seulement,
# pour garder la route par défaut de gestion de containerlab sur eth0
setip() {
    x $1 ip addr flush dev eth1
    x $1 ip addr add $2/24 dev eth1
    x $1 ip link set eth1 mtu 1500 up
    x $1 ip route replace 192.168.0.0/16 via ${2%.*}.1
}
setip client1 192.168.10.11   # h11  Locataire 1  acc1
setip client3 192.168.10.12   # h12  Locataire 1  acc2
setip client5 192.168.11.13   # h13  Locataire 1  acc3
setip client7 192.168.11.14   # h14  Locataire 1  acc4
setip client2 192.168.20.21   # h21  Locataire 2  acc1
setip client4 192.168.20.22   # h22  Locataire 2  acc2
setip client6 192.168.21.23   # h23  Locataire 2  acc3
setip client8 192.168.21.24   # h24  Locataire 2  acc4
sleep 35
