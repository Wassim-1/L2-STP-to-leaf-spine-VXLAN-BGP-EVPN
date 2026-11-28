#!/bin/bash
# Mesures de référence architecture A (L2 + STP). A lancer depuis la racine du dépôt.
P=clab-dc-l2
SW="core1 core2 agg1 agg2 acc1 acc2 acc3 acc4"
OUT=mesures/run_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
D() { n=$1; shift; docker exec "$P-$n" "$@"; }

echo "== 1. Ports bloqués"
for n in $SW; do D $n bridge link | grep blocking | sed "s/^/$n /"; done | tee "$OUT/ports_bloques.txt"

echo "== 2. Débit iperf3 (acc1->acc2 en L2, acc1->acc4 routé par agg1)"
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
run_iperf acc1_acc4_1flux client1 192.168.11.14 1 10
run_iperf acc1_acc4_4flux client1 192.168.11.14 4 10

echo "== 3. Utilisation des liens (octets émis pendant 20 s de trafic, 4 flux)"
snap() {
  for n in $SW; do
    D $n sh -c 'for i in /sys/class/net/eth*; do echo "$(basename $i) $(cat $i/statistics/tx_bytes)"; done' | sed "s/^/$n /"
  done
}
snap > "$OUT/avant.txt"
D client1 iperf3 -c 192.168.11.14 -t 20 -P 4 > "$OUT/iperf_liens.txt"
snap > "$OUT/apres.txt"
echo "switch,interface,octets_emis" > "$OUT/liens.csv"
awk 'NR==FNR{a[$1" "$2]=$3;next}{print $1","$2","$3-a[$1" "$2]}' "$OUT/avant.txt" "$OUT/apres.txt" >> "$OUT/liens.csv"

echo "== 4. Convergence STP (3 essais, coupure puis rétablissement du lien actif de acc1)"
# ping toutes les 0,2 s pendant 120 s : panne à 10 s, rétablissement à 60 s.
# Coupure = intervalle de plus de 0,5 s entre deux réponses horodatées (ping -D), classée selon qu'elle
# commence avant ou après le rétablissement. (Compter les pings perdus × 0,2 s sous-estime : le rythme
# réel de ping est plus lent, 600 pings durent 130 à 140 s.)
attendre_reseau() {  # jusqu'à 5 réponses consécutives (max ~90 s)
  for t in $(seq 1 90); do
    D client1 ping -c 5 -i 0.2 -W 1 192.168.11.14 2>/dev/null | grep -q " 0% packet loss" && return
    sleep 1
  done
  echo "réseau non rétabli"
}
echo "essai,coupure_panne_s,coupure_retablissement_s" > "$OUT/convergence.csv"
for i in 1 2 3; do
  attendre_reseau
  t0=$(date +%s.%N)
  D client1 timeout -s INT 120 ping -D -i 0.2 -W 1 192.168.11.14 > "$OUT/ping_panne_$i.txt" &
  PID=$!
  sleep 10
  D acc1 ip link set eth1 down
  sleep 50
  t_retab=$(date +%s.%N)
  D acc1 ip link set eth1 up
  wait $PID
  c=$(grep 'bytes from' "$OUT/ping_panne_$i.txt" | sed -E 's/^\[([0-9.]+)\].*/\1/' |
      awk -v r=$t_retab -v fin=$(echo "$t0 + 120" | bc) 'NR>1 && $1-p>0.5 { g=$1-p; if (p<r) a+=g; else b+=g }
        { p=$1 }
        END { if (fin-p>0.5) { g=fin-p; if (p<r) a+=g; else b+=g }; printf "%.1f,%.1f", a, b }')
  echo "$i,$c" >> "$OUT/convergence.csv"
done
attendre_reseau
echo "== Résultats dans $OUT"
cat "$OUT/debit.csv" "$OUT/convergence.csv"
