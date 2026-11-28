#!/bin/bash
# S6 : pannes de lien, de spine et de leaf sur l'architecture B, avec et sans BFD. A lancer depuis la racine du dépôt.
# Panne franche   : interface coupée (ip link down), détectée immédiatement par le noyau.
# Panne silencieuse : le lien reste "up" mais ne transmet plus rien (filtre tc en entrée des deux côtés) ;
#                     seuls BFD (~0,3 s) ou le hold timer BGP (9 s, profil datacenter) la détectent.
P=clab-dc-ls
ESSAIS=${ESSAIS:-3}
OUT=mesures/pannes_$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUT"
D() { n=$1; shift; docker exec "$P-$n" "$@"; }
V() { n=$1; shift; docker exec "$P-$n" vtysh "$@"; }

# flux mesurés : 100 pings/s chacun, hachés différemment par ECMP (en-têtes internes différents)
FLUX="client1:192.168.10.12 client1:192.168.11.14 client2:192.168.20.22 client2:192.168.21.24 client3:192.168.11.13"
T_PANNE=5; T_RETAB=20; DUREE=30   # secondes

coupe()   { D $1 tc qdisc add dev $2 ingress; D $1 tc filter add dev $2 parent ffff: matchall action drop; }
recolle() { D $1 tc qdisc del dev $2 ingress 2>/dev/null; }
silence_lien() {  # down|up  noeud port  noeud port
  f=$([ $1 = down ] && echo coupe || echo recolle)
  $f $2 $3; $f $4 $5
}

bfd() {  # on|off
  for n in 1 2 3 4; do
    [ $1 = on ] && c="neighbor SPINES bfd profile rapide" || c="no neighbor SPINES bfd"
    V leaf$n -c "conf t" -c "router bgp 6500$n" -c "$c" -c end
  done
  for s in spine1 spine2; do
    [ $1 = on ] && c="neighbor LEAFS bfd profile rapide" || c="no neighbor LEAFS bfd"
    V $s -c "conf t" -c "router bgp 65000" -c "$c" -c end
  done
}

fabrique_ok() {  # 8 sessions eBGP établies et ECMP rétabli, max ~90 s
  for t in $(seq 1 90); do
    n=0
    for l in leaf1 leaf2 leaf3 leaf4; do
      n=$((n + $(V $l -c "show bgp ipv4 unicast summary" 2>/dev/null | grep -cE "^spine[12].*FRRouting")))
    done
    [ $n = 8 ] && [ $(D leaf1 ip route show 10.0.0.14 | grep -c nexthop) = 2 ] && { sleep 3; return; }
    sleep 1
  done
  echo "fabrique non rétablie"
}

# coupures d'un flux, d'après l'horodatage des réponses (ping -D) : tout intervalle de plus de 50 ms
# entre deux réponses est une coupure, classée selon qu'elle commence avant ou après le rétablissement.
# (Compter les pings perdus × 10 ms sous-estime : dans un conteneur, ping ne tient pas 100 paquets/s.
#  La durée est bornée par timeout et non par ping -w : avec -w, ping s'arrête à la première erreur ICMP.)
coupures() {  # fichier t_retab t_fin -> "panne,retablissement" en secondes
  grep 'bytes from' "$1" | sed -E 's/^\[([0-9.]+)\].*/\1/' |
    awk -v r=$2 -v fin=$3 'NR>1 && $1-p>0.05 { g=$1-p; if (p<r) a+=g; else b+=g }
      { p=$1 }
      END { if (NR==0) a=fin-r; else if (fin-p>0.05) { g=fin-p; if (p<r) a+=g; else b+=g }
            printf "%.2f,%.2f", a, b }'
}

echo "scenario,bfd,essai,flux,coupure_panne_s,coupure_retablissement_s" > "$OUT/pannes.csv"
scenario() {  # nom bfd(on|off) "commande panne" "commande retablissement"
  for e in $(seq 1 $ESSAIS); do
    fabrique_ok
    echo "-- $1 (BFD $2), essai $e"
    t0=$(date +%s.%N)
    i=0
    for f in $FLUX; do
      i=$((i+1))
      D ${f%%:*} timeout -s INT $DUREE ping -D -i 0.01 -W 1 ${f##*:} > "$OUT/ping_$1_bfd$2_e${e}_f$i.txt" 2>&1 &
    done
    sleep $T_PANNE;              eval "$3"
    sleep $((T_RETAB-T_PANNE));  t_retab=$(date +%s.%N); eval "$4"
    wait
    i=0
    for f in $FLUX; do
      i=$((i+1))
      c=$(coupures "$OUT/ping_$1_bfd$2_e${e}_f$i.txt" $t_retab $(echo "$t0 + $DUREE" | bc))
      echo "$1,$2,$e,${f%%:*}->${f##*:},$c" | tee -a "$OUT/pannes.csv"
    done
  done
}

bfd on
scenario lien_franc_leaf1_spine1        on  "D leaf1 ip link set eth1 down" "D leaf1 ip link set eth1 up"
scenario lien_silencieux_leaf1_spine1   on  "silence_lien down leaf1 eth1 spine1 eth1" "silence_lien up leaf1 eth1 spine1 eth1"
scenario spine1_silencieux              on  "for n in 1 2 3 4; do silence_lien down leaf\$n eth1 spine1 eth\$n; done" \
                                            "for n in 1 2 3 4; do silence_lien up leaf\$n eth1 spine1 eth\$n; done"
scenario leaf4_silencieux               on  "silence_lien down leaf4 eth1 spine1 eth4; silence_lien down leaf4 eth2 spine2 eth4" \
                                            "silence_lien up leaf4 eth1 spine1 eth4; silence_lien up leaf4 eth2 spine2 eth4"
bfd off
scenario lien_silencieux_leaf1_spine1   off "silence_lien down leaf1 eth1 spine1 eth1" "silence_lien up leaf1 eth1 spine1 eth1"
scenario spine1_silencieux              off "for n in 1 2 3 4; do silence_lien down leaf\$n eth1 spine1 eth\$n; done" \
                                            "for n in 1 2 3 4; do silence_lien up leaf\$n eth1 spine1 eth\$n; done"
bfd on
fabrique_ok

# synthèse : pire coupure par scénario (moyenne des essais du pire flux).
# Panne de leaf4 : ses hôtes (h14, h24) n'ont qu'un raccordement, ils sont comptés à part.
echo "scenario,bfd,pire_coupure_panne_moy_s,pire_coupure_retab_moy_s" > "$OUT/resume.csv"
awk -F, 'NR>1 { if ($1 ~ /leaf4/ && $4 ~ /(11\.14|21\.24)$/) $1=$1"_hotes_de_leaf4"
  k=$1","$2","$3; if ($5>a[k]) a[k]=$5; if ($6>b[k]) b[k]=$6; s[$1","$2]=1 }
  END { for (k in a) { split(k, x, ","); sa[x[1]","x[2]]+=a[k]; sb[x[1]","x[2]]+=b[k]; n[x[1]","x[2]]++ }
        for (k in s) printf "%s,%.2f,%.2f\n", k, sa[k]/n[k], sb[k]/n[k] }' "$OUT/pannes.csv" | sort >> "$OUT/resume.csv"
echo "== Résultats dans $OUT"
column -t -s, "$OUT/resume.csv"
