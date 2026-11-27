#!/bin/bash
# Mesures de référence architecture A (L2 + STP). A lancer depuis la racine du dépôt.
P=clab-dc-l2
SW="core1 core2 agg1 agg2 acc1 acc2 acc3 acc4"
OUT=mesures/run_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
D() { n=$1; shift; docker exec "$P-$n" "$@"; }

echo "== 1. Ports bloqués"
for n in $SW; do D $n bridge link | grep blocking | sed "s/^/$n /"; done | tee "$OUT/ports_bloques.txt"

echo "== 2. Débit iperf3"
for c in client3 client7; do D $c pkill iperf3 2>/dev/null; docker exec -d $P-$c iperf3 -s; done
sleep 2
echo "test,debit,unite" > "$OUT/debit.csv"
run_iperf() {  # nom source ip_dest nb_flux duree
  D $2 iperf3 -c $3 -t $5 -P $4 > "$OUT/iperf_$1.txt"
  r=$(grep receiver "$OUT/iperf_$1.txt" | tail -1 | awk '{print $(NF-2)","$(NF-1)}')
  echo "$1,$r" >> "$OUT/debit.csv"
}
run_iperf acc1_acc2_1flux client1 192.168.10.12 1 10
run_iperf acc1_acc2_4flux client1 192.168.10.12 4 10
run_iperf acc1_acc4_1flux client1 192.168.10.14 1 10
run_iperf acc1_acc4_4flux client1 192.168.10.14 4 10

echo "== 3. Utilisation des liens (octets émis pendant 20 s de trafic, 4 flux)"
snap() {
  for n in $SW; do
    D $n sh -c 'for i in /sys/class/net/eth*; do echo "$(basename $i) $(cat $i/statistics/tx_bytes)"; done' | sed "s/^/$n /"
  done
}
snap > "$OUT/avant.txt"
D client1 iperf3 -c 192.168.10.14 -t 20 -P 4 > "$OUT/iperf_liens.txt"
snap > "$OUT/apres.txt"
echo "switch,interface,octets_emis" > "$OUT/liens.csv"
awk 'NR==FNR{a[$1" "$2]=$3;next}{print $1","$2","$3-a[$1" "$2]}' "$OUT/avant.txt" "$OUT/apres.txt" >> "$OUT/liens.csv"

echo "== 4. Convergence STP (3 essais, coupure du lien actif de acc1)"
echo "essai,envoyes,recus,perdus,convergence_s" > "$OUT/convergence.csv"
for i in 1 2 3; do
  D client1 ping -i 0.2 -c 350 192.168.10.14 > "$OUT/ping_panne_$i.txt" &
  PID=$!
  sleep 10
  D acc1 ip link set eth1 down
  wait $PID
  tx=$(grep -oE '[0-9]+ packets transmitted' "$OUT/ping_panne_$i.txt" | awk '{print $1}')
  rx=$(grep -oE '[0-9]+ received' "$OUT/ping_panne_$i.txt" | awk '{print $1}')
  lost=$((tx-rx))
  echo "$i,$tx,$rx,$lost,$(echo "$lost*0.2" | bc -l)" >> "$OUT/convergence.csv"
  D acc1 ip link set eth1 up
  sleep 50
done
echo "== Résultats dans $OUT"
cat "$OUT/debit.csv" "$OUT/convergence.csv"
