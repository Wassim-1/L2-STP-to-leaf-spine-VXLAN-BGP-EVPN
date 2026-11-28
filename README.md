# Projet 7 : migration L2 + STP vers leaf-spine VXLAN / BGP EVPN

Conception complète : [conception.pdf](conception.pdf).

## Lancer les labs

Depuis la racine du dépôt (sous WSL : `cd "/mnt/c/.../rx ip"`). `sudo` est inutile si l'utilisateur est dans le groupe `clab_admins`.

```bash
# Architecture A (3 niveaux, L2 + STP)
containerlab deploy -t l2.clab.yml
bash l2.sh                        # RATE= bash l2.sh pour ne pas limiter les liens
bash scripts/mesures_l2.sh        # S3
bash scripts/tempete_l2.sh        # S4
bash scripts/mac_l2.sh            # S6 : entrées MAC, pour la comparaison
containerlab destroy -t l2.clab.yml

# Architecture B (leaf-spine VXLAN / BGP EVPN)
containerlab deploy -t leaf_spine.clab.yml
bash leaf_spine.sh
bash scripts/verif_evpn.sh        # S5
bash scripts/mobilite_ls.sh       # S6 : h11 leaf1 -> leaf3 -> leaf1 (pas plus de 2 lancements en 3 min)
bash scripts/mesures_ls.sh        # S6 : débit, liens, MAC (mêmes flux que S3)
bash scripts/pannes_ls.sh         # S6 : pannes lien / spine / leaf, avec et sans BFD (~15 min)
containerlab destroy -t leaf_spine.clab.yml
```

Les deux labs utilisent les mêmes noms d'hôtes : en déployer un seul à la fois.

## Architecture B : organisation

| Fichier | Contenu |
|---|---|
| `configs/<noeud>/frr.conf` | adresses underlay (/31, loopback), eBGP, ECMP (`maximum-paths 2`), BFD (100 ms × 3), EVPN (`advertise-all-vni`, route targets 65000:VNI), VRF et type 5 |
| `configs/daemons`, `configs/vtysh.conf` | démons FRR actifs : zebra, bgpd, bfdd |
| `leaf_spine.sh` | MTU 9000 et plafond 1 Gbit/s sur l'underlay, ponts, VXLAN, VRF, passerelles anycast, hôtes, câble de mobilité h11 – leaf3 (eth5) |

Choix de mise en œuvre non détaillés dans la conception :
- un seul pont `br0` vlan-aware par leaf, un périphérique VXLAN par VNI (L2 et L3) rattaché à son VLAN ;
- chaque L3VNI utilise un VLAN interne (4001 pour VRF-T1, 4002 pour VRF-T2) dont la SVI, rangée dans le VRF, porte la router-MAC EVPN propre au leaf ;
- les SVI de passerelle (`vlan10`, `vlan11`, `vlan20`, `vlan21`) portent toutes la MAC anycast 02:00:00:00:00:01 et l'IP .1 ;
- sur les spines, `attribute-unchanged next-hop` en EVPN : le next-hop reste le VTEP du leaf d'origine ;
- `no bgp deterministic-med` dans les instances BGP des VRF : avec ce réglage (activé par le profil `datacenter`), un leaf configuré après les autres gardait comme meilleure la route importée la plus ancienne au lieu de son sous-réseau local, et n'annonçait alors aucune route type 5 ;
- hachage ECMP sur L4 (`fib_multipath_hash_policy=1`) : le port UDP source VXLAN varie selon le flux interne, les flux se répartissent sur les 2 spines ;
- paquets marqués (`tc ... skbedit mark 1`) à la sortie de chaque interface VXLAN : le pilote VXLAN de Linux garde en cache, par CPU, la route vers chaque VTEP, donc tous les flux d'un même CPU prenaient le même spine (8 flux routés : 923 Mbit/s, un seul lien montant utilisé). Un paquet marqué contourne ce cache et la route est choisie flux par flux (1,85 Gbit/s, 1004 Mo sur chaque lien montant) ;
- `arp_accept=1` sur les SVI de passerelle : l'ARP gratuit d'un hôte qui arrive sur un leaf crée tout de suite son entrée, d'où une route MAC+IP de séquence supérieure. Sans cela, après un déplacement, l'ancien leaf gardait son entrée ARP locale, et sa sonde ARP n'aboutissait pas (l'hôte répond à la MAC anycast, qui s'arrête sur son nouveau leaf) : le trafic routé vers l'hôte déplacé était coupé quelques secondes après le déplacement, jusqu'à ce que l'hôte reparle de lui-même à sa passerelle ;
- câble supplémentaire `client1:eth2 – leaf3:eth5` (VLAN 10), inactif côté hôte : il sert à déplacer h11 de leaf1 vers leaf3 sans changer de MAC ni d'IP.

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
- **Résultats de référence de A** : `mesures/run_20261128_155050` (S3), `mesures/tempete_20261128_141736` (S4) et `mesures/mac_l2_20261128_154737` (entrées MAC), obtenus avec l'adressage et le plafond actuels. Ils remplacent les mesures du 27/11 (ancien adressage VLAN 10/20, sans plafond).

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

## Résultats S5 (architecture B)

15 tests sur 15 conformes. Les sorties de `bash scripts/verif_evpn.sh` (dossiers `mesures/evpn_*`) ne sont pas versionnées : le script les régénère.

| Exigence | Test | Résultat |
|---|---|---|
| Underlay | 2 sessions eBGP + BFD par leaf, route vers chaque loopback avec 2 next-hops | OK (ECMP) |
| EF1 | h11→h12, h21→h22, h13→h14 (même sous-réseau, leaf différents, L2VNI) | 0 % de perte |
| EF3 | h11→h13, h12→h14, h21→h24 (sous-réseaux différents, L3VNI, IRB symétrique) | 0 % de perte |
| EF2 | h11→h21, h11→h23, h22→h12 (locataires différents) | 100 % de perte (isolé) |
| ENF5 | ping 1500 o non fragmentable, en L2VNI et en L3VNI | 0 % de perte |
| EF3 | chaque leaf reçoit les 16 routes type 5 (sous-réseaux de tous les leaf) | OK sur les 4 leaf |

Plan de contrôle vu de leaf1 : 16 routes type 2 (MAC et MAC+IP des 8 hôtes), 16 type 3 (4 VTEP × 4 L2VNI), 16 type 5 (4 leaf × 2 VRF × 2 sous-réseaux), et 16 type 5 sur chacun des 4 leaf. Dans VRF-T1, h13 apparaît en /32 via 10.0.0.13 sur `vlan4001` : le paquet est routé sur leaf1, transporté dans le L3VNI 50001, puis routé de nouveau sur leaf3.

## Résultats S6 (architecture B, comparaison avec A)

Dossiers : `mesures/mobilite_20261128_155933`, `mesures/ls_20261128_150723` (débit, liens, MAC), `mesures/pannes_20261128_160019`, et pour A `mesures/run_20261128_155050`, `mesures/mac_l2_20261128_154737`. Les 90 pings bruts des pannes (12 Mo) ne sont pas versionnés : `pannes.csv` contient la coupure de chaque flux à chaque essai, et `bash scripts/pannes_ls.sh` les régénère.

Méthode : pings horodatés (`ping -D`), 100 par seconde en B et 5 par seconde en A. Une coupure est l'écart entre deux réponses consécutives : au-delà de 50 ms en B, de 0,5 s en A. Chaque panne dure 15 s, 3 essais par scénario, 5 flux mesurés en même temps (h11→h12, h11→h14, h21→h22, h21→h24, h12→h13). ECMP répartit ces flux différemment, donc un flux qui ne passe pas par l'élément en panne ne voit rien.

### Mobilité de h11, leaf1 → leaf3 → leaf1 (EF4)

| Étape | VTEP qui annonce h11 (vu de leaf2) | Séquence MAC mobility | MAC de passerelle vue par h11 |
|---|---|---|---|
| h11 sur leaf1 | 10.0.0.11 | 0 | 02:00:00:00:00:01 |
| h11 déplacé sur leaf3 | 10.0.0.13 | 1 | 02:00:00:00:00:01 |
| h11 revenu sur leaf1 | 10.0.0.11 | 2 | 02:00:00:00:00:01 |

Coupure : 0,13 s pour h12 (même sous-réseau), 0 pour h13 (routé), dans les deux sens. IP, MAC et passerelle restent les mêmes, et le ping de la passerelle ne perd rien après le déplacement.

### Pannes dans B

| Scénario | BFD | Flux touchés | Coupure | Coupure au rétablissement |
|---|---|---|---|---|
| Lien leaf1–spine1 coupé (interface down) | oui | 6 / 15 | 0,12 à 0,14 s | 0 |
| Lien leaf1–spine1 silencieux (reste up, ne transmet plus) | oui | 8 / 15 | 0,09 à 0,65 s | 0 |
| idem | **non** | 9 / 15 | 6,7 à 9,1 s | 0 |
| spine1 entièrement silencieux | oui | 11 / 15 | 0,09 à 0,93 s | 0 |
| idem | **non** | 12 / 15 | 6,0 à 9,5 s | 0 |
| leaf4 silencieux : flux des autres leaf | oui | 0 / 9 | 0 | 0 |
| leaf4 silencieux : hôtes de leaf4 (h14, h24) | oui | 6 / 6 | 17,4 à 18,3 s (15 s de panne + 2,4 à 3,3 s de reconvergence) | — |

- Avec BFD (100 ms × 3), une panne invisible pour l'interface est détectée en ~0,3 s. La coupure reste sous la seconde (ENF2), contre 6 à 9,5 s sans BFD : c'est le hold timer BGP de 9 s du profil `datacenter`.
- La panne de spine est appliquée lien par lien, à raison de 8 commandes de ~0,1 s : elle s'installe sur près d'une seconde, d'où la dispersion de 0,09 à 0,93 s.
- La panne d'un leaf reste confinée (ENF4) : seuls ses propres hôtes, raccordés à lui seul, sont coupés.
- Rétablir un lien ou un spine ne coupe rien : la session BGP revient et ECMP rajoute le chemin.

### Comparaison A / B

| Indicateur | A : 3 niveaux, L2 + STP | B : leaf-spine VXLAN / EVPN |
|---|---|---|
| Liens inter-commutateurs actifs (ENF1) | 7 sur 13 (6 bloqués par STP) | 8 sur 8 |
| Chemins utilisés entre deux hôtes éloignés | 1 (acc1–agg1–acc4) | 2 en parallèle (via spine1 et spine2), ~2,5 Go sur chacun |
| Débit, 1 flux | 957 Mbit/s | 926 Mbit/s (−3 % : 50 o d'en-tête VXLAN pour 1500 o) |
| Débit, 4 flux | 956 Mbit/s | 1,85 Gbit/s |
| Coupure après panne d'un lien montant | 30,3 à 30,9 s | 0,12 à 0,14 s (franche), 0,09 à 0,65 s (silencieuse, BFD) |
| Coupure quand on rebranche ce lien | 29,0 à 30,8 s | 0 |
| Panne d'un commutateur d'accès / d'un leaf | ses hôtes sont isolés (attendu, non mesuré) | ses hôtes sont isolés, rien d'autre n'est touché (mesuré) |
| MAC apprises sur le cœur / les spines | 6 sur chaque cœur | 0 (les spines ne font que router) |
| MAC apprises sur l'accès / les leaf | 8 à 9 | 14 (MAC des 8 hôtes, apprises par EVPN, et router-MAC des autres leaf) |
| Mobilité d'un hôte | — | 0,13 s, IP et passerelle inchangées |
| Tempête de diffusion (S4) | 100 % de perte dans tout le domaine L2 | non mesurée dans B |

Dans ce petit lab, chaque leaf porte les 4 VNI : EVPN ne réduit donc pas le nombre de MAC sur les leaf. Le gain est ailleurs : les MAC sont apprises par BGP et non par inondation, et le cœur de la fabrique (les spines) n'en porte aucune.
