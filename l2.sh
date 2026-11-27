#!/usr/bin/env bash
LAB=clab-dc-l2
VLANS="10 20"
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
#         node  prio    trunk ports                              access ports
bridge_up core1  4096  "eth1 eth2 eth3"                 ""
bridge_up core2  8192  "eth1 eth2 eth4"                 ""
bridge_up agg1  16384  "eth1 eth2 eth4 eth5 eth6 eth7"  ""
bridge_up agg2  20480  "eth2 eth3 eth4 eth5 eth6 eth7"  ""
bridge_up acc1  32768  "eth1 eth4"                      "eth2:10 eth3:20"
bridge_up acc2  32768  "eth1 eth4"                      "eth2:10 eth3:20"
bridge_up acc3  32768  "eth1 eth4"                      "eth2:10 eth3:20"
bridge_up acc4  32768  "eth1 eth4"                      "eth2:10 eth3:20"
setip() { x $1 ip addr replace $2 dev eth1; x $1 ip link set eth1 up; }
setip client1 192.168.10.11/24
setip client3 192.168.10.12/24
setip client5 192.168.10.13/24
setip client7 192.168.10.14/24
setip client2 192.168.20.21/24
setip client4 192.168.20.22/24
setip client6 192.168.20.23/24
setip client8 192.168.20.24/24
sleep 35
