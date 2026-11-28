#!/bin/bash
# S6 : entrées MAC de l'architecture A, même comptage que mesures_ls.sh (comparaison A / B).
# A lancer depuis la racine du dépôt, lab A déployé et configuré par l2.sh.
P=clab-dc-l2
SW="core1 core2 agg1 agg2 acc1 acc2 acc3 acc4"
OUT=mesures/mac_l2_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
D() { n=$1; shift; docker exec "$P-$n" "$@"; }

# chaque hôte parle à sa passerelle : sa MAC est apprise partout où l'ARP est diffusé
for c in client1 client2 client3 client4 client5 client6 client7 client8; do
  gw=$(D $c ip route show 192.168.0.0/16 | awk '{print $3}')
  D $c ping -c 2 -W 1 $gw > /dev/null 2>&1
done
sleep 3
echo "equipement,mac_apprises" > "$OUT/mac.csv"
for n in $SW; do
  D $n bridge fdb show > "$OUT/fdb_$n.txt"
  echo "$n,$(grep 'master br0' "$OUT/fdb_$n.txt" | grep -vc permanent)" >> "$OUT/mac.csv"
done
echo "== Résultats dans $OUT"
cat "$OUT/mac.csv"
