# Projet 7 : migration L2 + STP vers leaf-spine VXLAN / BGP EVPN

Conception complète : [conception.pdf](conception.pdf).

## Lancer les labs

```bash
# Architecture A (3 niveaux, L2 + STP)
sudo containerlab deploy -t l2.clab.yml
./l2.sh                       # RATE= ./l2.sh pour ne pas limiter les liens
./scripts/mesures_l2.sh       # S3
./scripts/tempete_l2.sh       # S4

# Architecture B (leaf-spine)
sudo containerlab deploy -t leaf_spine.clab.yml
```

## Correspondance hôtes (identique en A et en B, EF5)

| Conteneur | Hôte | Locataire | IP | A | B |
|---|---|---|---|---|---|
| client1 | h11 | 1 | 192.168.10.11 | acc1 | leaf1 |
| client3 | h12 | 1 | 192.168.10.12 | acc2 | leaf2 |
| client5 | h13 | 1 | 192.168.11.13 | acc3 | leaf3 |
| client7 | h14 | 1 | 192.168.11.14 | acc4 | leaf4 |
| client2 | h21 | 2 | 192.168.20.21 | acc1 | leaf1 |
| client4 | h22 | 2 | 192.168.20.22 | acc2 | leaf2 |
| client6 | h23 | 2 | 192.168.21.23 | acc3 | leaf3 |
| client8 | h24 | 2 | 192.168.21.24 | acc4 | leaf4 |

Les hôtes joignent 192.168.0.0/16 via la passerelle .1 de leur sous-réseau ; eth0 reste le réseau de gestion de containerlab.

## Écarts par rapport à la conception (à reprendre dans le rapport)

- **STP et non RSTP** : le pont du noyau Linux ne fait que du 802.1D. La convergence mesurée (~30 s = 2 × forward delay) est donc celle de STP classique ; RSTP ferait mieux (quelques secondes) mais resterait loin de BFD.
- **Passerelle de type VRRP sans protocole VRRP** : agg1 porte l'IP virtuelle .1 (et .2), agg2 porte .3. Aucun démon VRRP dans l'image, donc pas de bascule automatique de .1 vers agg2. Chaque locataire a son VRF sur les agg (isolation EF2 aussi en A).
- **Liens bridés à 1 Gbit/s** (`tc tbf`) sur les liens inter-commutateurs en A comme en B : sans plafond, un veth seul dépasse 20 Gbit/s et l'apport d'ECMP n'apparaît pas dans le débit.
- **Résultats de référence de A** : `mesures/run_20261128_155050` (S3) et `mesures/tempete_20261128_141736` (S4), obtenus avec l'adressage et le plafond actuels. Ils remplacent les mesures du 27/11 (ancien adressage VLAN 10/20, sans plafond).

## Résultats de référence de A (S3, S4)

| Indicateur | Valeur |
|---|---|
| Liens inter-commutateurs bloqués par STP | 6 sur 13 |
| Liens réellement traversés par un flux acc1 → acc4 | 2 sur 13 (acc1–agg1, agg1–acc4 ; cœurs inutilisés) |
| Débit acc1 → acc4, 1 flux / 4 flux | 957 / 956 Mbit/s (un seul chemin, 4 flux n'apportent rien) |
| Coupure après panne du lien actif de acc1 | 30,4 / 30,3 / 30,9 s |
| Coupure au **rétablissement** de ce lien | 29,0 / 30,5 / 30,8 s |
| Tempête (STP coupé) : paquets/s sur core1 eth2 | ~27 500 |
| Tempête : CPU hôte en softirq | 6,3 % (≈ 1 cœur sur 16) |
| Tempête : perte ping / débit iperf | 70 à 100 % / 0 |
| Tempête : ports où la MAC de h11 est vue sur core1 | 3 (instabilité de la table MAC) |

Les deux coupures valent 2 × forward delay (2 × 15 s) : en STP 802.1D, le port qui prend le relais passe par les états listening puis learning avant de transmettre. Rebrancher le lien coupe donc aussi le trafic : l'ancien port racine est bloqué tout de suite, et le nouveau doit encore franchir ces deux états.

Les coupures sont mesurées d'après l'horodatage des réponses (`ping -D`) : compter les pings perdus × 0,2 s les sous-estimait (600 pings duraient en réalité 130 à 140 s), et la durée est bornée par `timeout` car `ping -w` s'arrête à la première erreur ICMP.

Le CPU de la tempête se lit dans `/proc/stat` de l'hôte : le pont Linux commute dans le noyau (softirq), hors des cgroups des conteneurs, donc `docker stats` affiche 0 %.
