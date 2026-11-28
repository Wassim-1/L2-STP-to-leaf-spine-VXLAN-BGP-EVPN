#!/bin/bash
# S6 : mesures de l'architecture B, mêmes flux qu'en S3 pour la comparaison. A lancer depuis la racine du dépôt.
P=clab-dc-ls
SPINES="spine1 spine2"; LEAFS="leaf1 leaf2 leaf3 leaf4"
OUT=mesures/ls_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
D() { n=$1; shift; docker exec "$P-$n" "$@"; }

echo "== 1. Sessions et ECMP"
D leaf1 ip route show 10.0.0.14 | tee "$OUT/ecmp_leaf1_vers_leaf4.txt"

echo "== 2. Débit iperf3 (leaf1->leaf2 en L2VNI, leaf1->leaf4 routé en L3VNI)"
for c in client3 client7; do D $c pkill iperf3 2>/dev/null; docker exec -d $P-$c iperf3 -s; done
sleep 2
echo "test,debit,unite" > "$OUT/debit.csv"
run_iperf() {  # nom source ip_dest nb_flux duree
  D $2 iperf3 -c $3 -t $5 -P $4 > "$OUT/iperf_$1.txt"
  r=$(grep receiver "$OUT/iperf_$1.txt" | tail -1 | awk '{print $(NF-2)","$(NF-1)}')
  echo "$1,$r" >> "$OUT/debit.csv"
}
run_iperf leaf1_leaf2_1flux client1 192.168.10.12 1 10
run_iperf leaf1_leaf2_4flux client1 192.168.10.12 4 10
run_iperf leaf1_leaf4_1flux client1 192.168.11.14 1 10
run_iperf leaf1_leaf4_4flux client1 192.168.11.14 4 10
run_iperf leaf1_leaf4_8flux client1 192.168.11.14 8 10

echo "== 3. Utilisation des liens (octets émis pendant 20 s de trafic, 8 flux leaf1->leaf4)"
snap() {
  for n in $SPINES $LEAFS; do
    D $n sh -c 'for i in /sys/class/net/eth*; do echo "$(basename $i) $(cat $i/statistics/tx_bytes)"; done' | sed "s/^/$n /"
  done
}
snap > "$OUT/avant.txt"
D client1 iperf3 -c 192.168.11.14 -t 20 -P 8 > "$OUT/iperf_liens.txt"
snap > "$OUT/apres.txt"
echo "switch,interface,octets_emis" > "$OUT/liens.csv"
awk 'NR==FNR{a[$1" "$2]=$3;next}{print $1","$2","$3-a[$1" "$2]}' "$OUT/avant.txt" "$OUT/apres.txt" >> "$OUT/liens.csv"
# liens inter-commutateurs = ports des spines ; un lien est "utilisé" s'il a porté plus de 10 Mo dans un sens
utilises=$(awk -F, '$1 ~ /spine/ && $3 > 10000000' "$OUT/liens.csv" | wc -l)
echo "liens spine-leaf utilisés par le flux leaf1->leaf4 (sens spine->leaf) : $utilises / 8"
echo "chemins parallèles leaf1->leaf4 : $(awk -F, '$1=="leaf1" && ($2=="eth1"||$2=="eth2") && $3 > 10000000' "$OUT/liens.csv" | wc -l)"

echo "== 4. Tables MAC (MAC apprises par le pont, hors entrées permanentes ; même comptage que mac_l2.sh)"
for c in client1 client2 client3 client4 client5 client6 client7 client8; do
  gw=$(D $c ip route show 192.168.0.0/16 | awk '{print $3}')
  D $c ping -c 2 -W 1 $gw > /dev/null 2>&1
done
sleep 3
echo "equipement,mac_apprises" > "$OUT/mac.csv"
for n in $SPINES $LEAFS; do
  echo "$n,$(D $n bridge fdb show 2>/dev/null | grep 'master br0' | grep -vc permanent)" >> "$OUT/mac.csv"
done
cat "$OUT/mac.csv"

echo "== Résultats dans $OUT"
cat "$OUT/debit.csv"
