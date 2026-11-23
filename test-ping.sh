#!/usr/bin/env bash
LAB=clab-dc-l2

x() { docker exec "$LAB-$1" "${@:2}"; }

bridge_up() {
  node=$1; trunks=$2; access=$3
  x $node ip link del br0 2>/dev/null           
  x $node ip link add br0 type bridge vlan_filtering 1 stp_state 0
  x $node ip link set br0 up
  for p in $trunks $access; do
    x $node ip link set $p master br0          
    x $node ip link set $p up
    x $node bridge vlan del dev $p vid 1       
  done
  for p in $trunks; do x $node bridge vlan add dev $p vid 10; done
  for p in $access; do x $node bridge vlan add dev $p vid 10 pvid untagged; done
}

#          
bridge_up  acc1  "eth1"        "eth2"         
bridge_up  agg1  "eth4 eth5"   ""              
bridge_up  acc2  "eth1"        "eth2" 
         

x client1 ip addr replace 10.0.10.1/24 dev eth1
x client1 ip link set eth1 up
x client3 ip addr replace 10.0.10.2/24 dev eth1
x client3 ip link set eth1 up

echo "--- ping client1 -> client3 ---"
x client1 ping -c 3 10.0.10.2