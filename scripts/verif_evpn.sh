#!/bin/bash
# S5 : vérification de l'architecture B (underlay, L2VNI, L3VNI, isolation, MTU). A lancer depuis la racine du dépôt.
P=clab-dc-ls
OUT=mesures/evpn_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
D() { n=$1; shift; docker exec "$P-$n" "$@"; }
V() { n=$1; shift; docker exec "$P-$n" vtysh -c "$*"; }

echo "== 1. Underlay : sessions eBGP, BFD, ECMP"
{ V leaf1 show bgp summary; V leaf1 show bfd peers brief; } > "$OUT/leaf1_bgp_bfd.txt"
D leaf1 ip route show 10.0.0.14 > "$OUT/leaf1_ecmp_vers_leaf4.txt"
cat "$OUT/leaf1_ecmp_vers_leaf4.txt"

echo "== 2. Préchauffage ARP (les hôtes s'annoncent, EVPN publie les routes type 2)"
for c in client1 client2 client3 client4 client5 client6 client7 client8; do
  gw=$(D $c ip route show 192.168.0.0/16 | awk '{print $3}')
  D $c ping -c 2 -W 1 $gw > /dev/null 2>&1
done
sleep 3

echo "== 3. Connectivité"
echo "exigence,test,source,destination,attendu,perte_pct,resultat" > "$OUT/verifications.csv"
check() {  # exigence test source ip_dest attendu(ok|bloque)
  perte=$(D $3 ping -c 5 -i 0.2 -W 1 $4 2>&1 | grep -oE '[0-9.]+% packet loss' | cut -d% -f1)
  if [ "$5" = ok ]; then [ "$perte" = 0 ] && r=OK || r=ECHEC
  else [ "$perte" = 100 ] && r=OK || r=ECHEC; fi
  echo "$1,$2,$3,$4,$5,$perte,$r" | tee -a "$OUT/verifications.csv"
}
check EF1 "L2VNI h11->h12"        client1 192.168.10.12 ok
check EF1 "L2VNI h21->h22"        client2 192.168.20.22 ok
check EF1 "L2VNI h13->h14"        client5 192.168.11.14 ok
check EF3 "L3VNI h11->h13"        client1 192.168.11.13 ok
check EF3 "L3VNI h12->h14"        client3 192.168.11.14 ok
check EF3 "L3VNI h21->h24"        client2 192.168.21.24 ok
check EF2 "isolation h11->h21"    client1 192.168.20.21 bloque
check EF2 "isolation h11->h23"    client1 192.168.21.23 bloque
check EF2 "isolation h22->h12"    client4 192.168.10.12 bloque
# 1472 o de données ICMP = paquet IP de 1500 o, non fragmentable, encapsulé en 1550 o sur l'underlay
check ENF5 "MTU 1500 L2VNI h11->h12" client1 "-M do -s 1472 192.168.10.12" ok
check ENF5 "MTU 1500 L3VNI h11->h14" client1 "-M do -s 1472 192.168.11.14" ok

echo "== 4. Plan de contrôle EVPN (leaf1)"
V leaf1 show evpn vni > "$OUT/leaf1_evpn_vni.txt"
V leaf1 show bgp l2vpn evpn route type macip     > "$OUT/leaf1_evpn_type2.txt"
V leaf1 show bgp l2vpn evpn route type multicast > "$OUT/leaf1_evpn_type3.txt"
V leaf1 show bgp l2vpn evpn route type prefix    > "$OUT/leaf1_evpn_type5.txt"
V leaf1 show ip route vrf VRF-T1 > "$OUT/leaf1_vrf_t1.txt"
V leaf1 show ip route vrf VRF-T2 > "$OUT/leaf1_vrf_t2.txt"
D leaf1 bridge fdb show > "$OUT/leaf1_fdb.txt"
echo "route,nombre" > "$OUT/evpn.csv"
for t in 2 3 5; do
  f=$(case $t in 2) echo type2;; 3) echo type3;; 5) echo type5;; esac)
  n=$(grep -oE 'Displayed [0-9]+ prefixes' "$OUT/leaf1_evpn_$f.txt" | awk '{print $2}')
  echo "type$t,${n:-0}" >> "$OUT/evpn.csv"
done
# entrées MAC apprises sur le pont (hors entrées locales/permanentes), à comparer à agg1 dans A
echo "mac_fdb_leaf1,$(grep -vcE 'permanent|self' "$OUT/leaf1_fdb.txt")" >> "$OUT/evpn.csv"
# chaque leaf doit voir les type 5 de tous les leaf : 4 leaf x 2 VRF x 2 sous-réseaux = 16
for n in leaf1 leaf2 leaf3 leaf4; do
  t5=$(V $n show bgp l2vpn evpn route type prefix | grep -oE 'Displayed [0-9]+' | awk '{print $2}')
  echo "type5_$n,${t5:-0}" >> "$OUT/evpn.csv"
  [ "${t5:-0}" = 16 ] && r=OK || r=ECHEC
  echo "EF3,type 5 complets sur $n,$n,-,16,-,$r" >> "$OUT/verifications.csv"
done
cat "$OUT/evpn.csv"

echo "== Résultats dans $OUT"
echo "tests OK : $(grep -c ',OK$' "$OUT/verifications.csv") / $(($(wc -l < "$OUT/verifications.csv")-1))"
