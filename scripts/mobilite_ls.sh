#!/bin/bash
# S6 : mobilité de h11 (client1) de leaf1 vers leaf3 puis retour, en gardant IP, MAC et passerelle (EF4).
# h11 a un second câble vers leaf3 (client1:eth2 - leaf3:eth5, VLAN 10) : le déplacer revient à couper
# eth1 et à reprendre MAC et IP sur eth2. A lancer depuis la racine du dépôt.
# Attention : FRR gèle une MAC qui bouge plus de 5 fois en 180 s (dup-addr-detection) ; ne pas enchaîner
# plus de 2 lancements en 3 minutes.
P=clab-dc-ls
OUT=mesures/mobilite_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
D() { n=$1; shift; docker exec "$P-$n" "$@"; }
V() { n=$1; shift; docker exec "$P-$n" vtysh -c "$*"; }
MAC=$(D client1 cat /sys/class/net/eth1/address)
IP=192.168.10.11
# observateurs : h12 (même sous-réseau, leaf2, L2VNI) et h13 (autre sous-réseau, leaf3, L3VNI)
FLUX="client3:$IP client5:$IP"
T_MOUV=5; DUREE=15

etat() {  # $1 = étiquette ; où la fabrique voit la MAC de h11, et passerelle vue par h11
  {
    echo "### $1"
    for n in leaf1 leaf2 leaf3; do echo "--- $n"; V $n show evpn mac vni 10010 mac $MAC; done
    echo "--- h11 : passerelle"; D client1 ip neigh show 192.168.10.1
  } >> "$OUT/evpn_etat.txt"
  vtep=$(V leaf2 show evpn mac vni 10010 mac $MAC | grep -oE 'Remote VTEP: [0-9.]+' | awk '{print $3}')
  seq=$(V leaf2 show evpn mac vni 10010 mac $MAC | grep -oE 'Remote Seq: [0-9]+' | awk '{print $3}')
  gwmac=$(D client1 ip neigh show 192.168.10.1 | grep -oE '([0-9a-f]{2}:){5}[0-9a-f]{2}')
  echo "$1,${vtep:-local},${seq:-?},${gwmac:-?}" >> "$OUT/etat.csv"
}

vers_leaf3() {
  D client1 sh -c "ip link set eth1 down; ip addr flush dev eth1
    ip link set eth2 address $MAC; ip addr add $IP/24 dev eth2; ip link set eth2 mtu 1500 up
    ip route replace 192.168.0.0/16 via 192.168.10.1 dev eth2
    arping -q -U -c 2 -I eth2 $IP"
}
vers_leaf1() {
  D client1 sh -c "ip link set eth2 down; ip addr flush dev eth2
    ip addr add $IP/24 dev eth1; ip link set eth1 up
    ip route replace 192.168.0.0/16 via 192.168.10.1 dev eth1
    arping -q -U -c 2 -I eth1 $IP"
}

mouvement() {  # nom fonction
  i=0
  t0=$(date +%s.%N)
  for f in $FLUX; do
    i=$((i+1))
    D ${f%%:*} timeout -s INT $DUREE ping -D -i 0.01 -W 1 ${f##*:} > "$OUT/ping_$1_f$i.txt" 2>&1 &
  done
  sleep $T_MOUV; $2
  wait
  i=0
  for f in $FLUX; do
    i=$((i+1))
    # coupure = intervalles de plus de 50 ms entre deux réponses horodatées (ping -D)
    g=$(grep 'bytes from' "$OUT/ping_$1_f$i.txt" | sed -E 's/^\[([0-9.]+)\].*/\1/' |
        awk -v fin=$(echo "$t0 + $DUREE" | bc) 'NR>1 && $1-p>0.05 {a+=$1-p} {p=$1}
          END{ if (fin-p>0.05) a+=fin-p; printf "%.2f", a }')
    gw=$(D client1 ping -c 3 -i 0.2 -W 1 192.168.10.1 | grep -oE '[0-9.]+% packet loss' | cut -d% -f1)
    echo "$1,${f%%:*}->${f##*:},$g,$gw" | tee -a "$OUT/mobilite.csv"
  done
}

echo "etape,vtep_vu_par_leaf2,seq_mobilite,mac_passerelle_vue_par_h11" > "$OUT/etat.csv"
echo "mouvement,flux,coupure_s,perte_ping_passerelle_pct" > "$OUT/mobilite.csv"
D client1 ping -c 2 -W 1 192.168.10.1 > /dev/null
D client3 ping -c 2 -W 1 $IP > /dev/null; sleep 2
etat "1_h11_sur_leaf1"
echo "== h11 : leaf1 -> leaf3"
mouvement leaf1_vers_leaf3 vers_leaf3; sleep 2
etat "2_h11_sur_leaf3"
echo "== h11 : leaf3 -> leaf1"
mouvement leaf3_vers_leaf1 vers_leaf1; sleep 2
etat "3_h11_revenu_sur_leaf1"
echo "== Résultats dans $OUT"
column -t -s, "$OUT/etat.csv"
