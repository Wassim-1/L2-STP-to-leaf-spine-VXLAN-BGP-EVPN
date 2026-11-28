#!/bin/bash
# S4 : tempête de broadcast sur l'architecture A. A lancer depuis la racine du dépôt.
P=clab-dc-l2
SW="core1 core2 agg1 agg2 acc1 acc2 acc3 acc4"
OUT=mesures/tempete_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
D() { n=$1; shift; docker exec "$P-$n" "$@"; }
DONE=0
restore() {
  [ $DONE = 1 ] && return
  DONE=1
  echo "== Rétablissement de STP"
  for n in $SW; do D $n ip link set br0 type bridge stp_state 1 2>/dev/null; done
}
trap restore EXIT INT TERM

echo "phase,metrique,valeur" > "$OUT/resume.csv"
MAC=$(D client1 cat /sys/class/net/eth1/address)

mesure() {  # $1 = phase
  L=$1
  echo "-- Mesures : $L"
  # paquets/s reçus sur core1 eth2, et CPU de la machine pendant les mêmes 5 s.
  # Les ponts commutent dans le noyau (softirq), hors des cgroups des conteneurs :
  # docker stats affiche 0 %, il faut lire /proc/stat de l'hôte.
  t0=$(date +%s.%N); a=$(D core1 cat /sys/class/net/eth2/statistics/rx_packets)
  c0=$(head -1 /proc/stat)
  sleep 5
  c1=$(head -1 /proc/stat)
  b=$(D core1 cat /sys/class/net/eth2/statistics/rx_packets); t1=$(date +%s.%N)
  echo "$L,pps_core1_eth2,$(echo "($b-$a)/($t1-$t0)" | bc)" >> "$OUT/resume.csv"
  echo "$c0" > "$OUT/cpu_$L.txt"; echo "$c1" >> "$OUT/cpu_$L.txt"
  # colonnes de /proc/stat : user nice system idle iowait irq softirq steal
  echo "$c0 $c1" | awk -v L=$L '{
    for (i=2; i<=9; i++) { t0+=$i; t1+=$(i+11) }
    printf "%s,cpu_hote_softirq_pct,%.1f\n", L, 100*($19-$8)/(t1-t0)
    printf "%s,cpu_hote_total_pct,%.1f\n",   L, 100*(1-($16-$5)/(t1-t0)) }' >> "$OUT/resume.csv"
  echo "$L,loadavg_1min,$(cut -d' ' -f1 /proc/loadavg)" >> "$OUT/resume.csv"
  # table MAC
  echo "$L,entrees_fdb_agg1,$(D agg1 bridge fdb show | wc -l)" >> "$OUT/resume.csv"
  # instabilité du MAC de client1 : port vu sur core1, 5 échantillons
  : > "$OUT/mac_client1_$L.txt"
  for i in 1 2 3 4 5; do
    D core1 bridge fdb show | grep -i "$MAC" | grep -v permanent | awk '{print $3}' | tr '\n' ' ' >> "$OUT/mac_client1_$L.txt"
    echo >> "$OUT/mac_client1_$L.txt"; sleep 1
  done
  echo "$L,ports_distincts_mac_client1,$(sort -u "$OUT/mac_client1_$L.txt" | tr ' ' '\n' | grep -c eth)" >> "$OUT/resume.csv"
  # perte et latence
  timeout 25 docker exec $P-client1 ping -c 10 -i 0.2 -W 1 192.168.10.12 > "$OUT/ping_$L.txt" 2>&1
  echo "$L,perte_ping_pct,$(grep -oE '[0-9.]+% packet loss' "$OUT/ping_$L.txt" | cut -d% -f1)" >> "$OUT/resume.csv"
  # débit iperf3
  timeout 25 docker exec $P-client1 iperf3 -c 192.168.10.12 -t 5 > "$OUT/iperf_$L.txt" 2>&1
  deb=$(grep receiver "$OUT/iperf_$L.txt" | awk '{print $(NF-2)" "$(NF-1)}')
  echo "$L,debit_iperf,${deb:-0 echec}" >> "$OUT/resume.csv"
}

D client3 pkill iperf3 2>/dev/null; docker exec -d $P-client3 iperf3 -s; sleep 2

echo "== 1. Référence (STP actif)"
mesure reference

echo "== 2. Désactivation de STP sur les 8 switches"
for n in $SW; do D $n ip link set br0 type bridge stp_state 0; done
sleep 2
for n in $SW; do
  for p in $(D $n bridge link | grep blocking | grep -oE "eth[0-9]+"); do
    D $n sh -c "ip link set dev $p down; sleep 0.5; ip link set dev $p up"
  done
done
sleep 2
echo "ports encore bloques : $(for n in $SW; do D $n bridge link | grep -c blocking; done | paste -sd+ | bc)"
echo "== 3. Déclenchement du broadcast"
D client1 ping -c 1 -W 1 192.168.10.99 > /dev/null 2>&1
sleep 3
echo "== 4. Capture et mesures pendant la tempête"
timeout 8 docker exec $P-core1 tcpdump -nn -e -i eth2 -c 30 arp > "$OUT/tcpdump_tempete.txt" 2>&1
mesure tempete

echo "== 5. Rétablissement et vérification"
restore
sleep 45
timeout 15 docker exec $P-client1 ping -c 5 -W 1 192.168.10.12 > "$OUT/ping_apres.txt" 2>&1
echo "apres,perte_ping_pct,$(grep -oE '[0-9.]+% packet loss' "$OUT/ping_apres.txt" | cut -d% -f1)" >> "$OUT/resume.csv"
echo "== Résultats dans $OUT"
column -t -s, "$OUT/resume.csv"
