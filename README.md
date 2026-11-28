# Réseau de datacenter : migration d'un L2 étendu + STP vers une fabrique leaf-spine VXLAN / BGP EVPN

Projet 7 du module Réseaux IP (RT3, groupe 12). Le datacenter héberge les serveurs de deux locataires. On déploie d'abord son réseau existant, on mesure ses limites, puis on le migre vers une fabrique moderne et on compare les deux sur les mêmes indicateurs.

- **Architecture A (existant)** : trois niveaux cœur / agrégation / accès, VLAN étendus, STP.
- **Architecture B (cible)** : fabrique leaf-spine, underlay eBGP + ECMP, overlay VXLAN piloté par BGP EVPN, passerelle anycast, multi-locataires (VRF / L3VNI) et BFD.

La conception complète (exigences, plans d'adressage, modélisation des flux) est dans [conception.pdf](conception.pdf).

## Sommaire

- [Les deux architectures](#les-deux-architectures)
- [Plan d'adressage](#plan-dadressage)
- [Contenu du dépôt](#contenu-du-dépôt)
- [Lancer les labs](#lancer-les-labs)
- [Avancement, de S1 à S6](#avancement-de-s1-à-s6)
- [Résultats](#résultats)
- [Choix de mise en œuvre et écarts à la conception](#choix-de-mise-en-œuvre-et-écarts-à-la-conception)
- [Reste à faire](#reste-à-faire)

## Les deux architectures

Les deux labs tournent sous Containerlab : chaque commutateur, routeur ou serveur est un conteneur Linux.

### A : trois niveaux, L2 + STP

```
          core1 ──── core2            racine STP : core1 (4096), secours : core2 (8192)
           │  ╲      ╱  │
          agg1 ────── agg2            passerelles des VLAN, un VRF par locataire
         ╱ │  ╲    ╱  │ ╲
     acc1 acc2  acc3  acc4            chaque accès est relié aux deux agg
      │ │  │ │   │ │   │ │
     h11 h21 ...          h24          8 serveurs, 2 par accès
```

- 8 commutateurs = ponts Linux avec STP et VLAN (10, 11, 20, 21) en trunk sur les 13 liens inter-commutateurs.
- STP bloque 6 liens sur 13 pour couper les boucles.

### B : leaf-spine VXLAN / BGP EVPN

```
        spine1 (AS 65000)   spine2 (AS 65000)        routage IP uniquement
          │ │ │ │             │ │ │ │
        leaf1   leaf2   leaf3   leaf4                AS 65001 à 65004, VTEP
         │ │     │ │     │ │     │ │
        h11 h21 h12 h22 h13 h23 h14 h24              les mêmes serveurs qu'en A
```

- spines et leaf = conteneurs FRRouting (zebra, bgpd, bfdd).
- Chaque leaf est relié aux deux spines : 8 liens, tous actifs grâce à ECMP.
- Les leaf portent les VXLAN, les VRF et la passerelle anycast ; les spines ne voient que de l'IP.

## Plan d'adressage

Le détail est dans [conception.pdf](conception.pdf), sections 4.1 à 4.4.

**Serveurs** (identiques en A et en B, exigence EF5) :

| Conteneur | Serveur | Locataire | Segment | IP | A | B |
|---|---|---|---|---|---|---|
| client1 | h11 | 1 | 1a (VLAN 10) | 192.168.10.11 | acc1 | leaf1 |
| client3 | h12 | 1 | 1a (VLAN 10) | 192.168.10.12 | acc2 | leaf2 |
| client5 | h13 | 1 | 1b (VLAN 11) | 192.168.11.13 | acc3 | leaf3 |
| client7 | h14 | 1 | 1b (VLAN 11) | 192.168.11.14 | acc4 | leaf4 |
| client2 | h21 | 2 | 2a (VLAN 20) | 192.168.20.21 | acc1 | leaf1 |
| client4 | h22 | 2 | 2a (VLAN 20) | 192.168.20.22 | acc2 | leaf2 |
| client6 | h23 | 2 | 2b (VLAN 21) | 192.168.21.23 | acc3 | leaf3 |
| client8 | h24 | 2 | 2b (VLAN 21) | 192.168.21.24 | acc4 | leaf4 |

Chaque serveur passe par la passerelle `.1` de son sous-réseau pour joindre les autres sous-réseaux ; `eth0` reste le réseau de gestion de Containerlab.

**Overlay de B** :

| Locataire | VRF | L3VNI | Segments (VLAN → L2VNI) |
|---|---|---|---|
| 1 | VRF-T1 | 50001 | 10 → 10010, 11 → 10011 |
| 2 | VRF-T2 | 50002 | 20 → 10020, 21 → 10021 |

Passerelle anycast `.1` avec la MAC `02:00:00:00:00:01` sur tous les leaf. Route targets `65000:<VNI>`.

**Underlay de B** : loopbacks `10.0.0.1-2` (spines) et `10.0.0.11-14` (leaf), liens /31 `10.1.1.0/24` (spine1) et `10.1.2.0/24` (spine2), MTU 9000.

## Contenu du dépôt

```
conception.pdf                 conception (S1)
l2.clab.yml, l2.sh             architecture A : topologie, puis configuration des ponts, VLAN, passerelles et serveurs
leaf_spine.clab.yml            architecture B : topologie
leaf_spine.sh                  architecture B : ponts, VXLAN, VRF, passerelles anycast, serveurs
configs/                       architecture B : configuration FRR de chaque spine et leaf
scripts/
  mesures_l2.sh                S3  : débit, utilisation des liens, convergence STP (A)
  tempete_l2.sh                S4  : tempête de diffusion (A)
  verif_evpn.sh                S5  : vérification de B (EF1, EF2, EF3, MTU, routes EVPN)
  mobilite_ls.sh               S6  : déplacement d'un serveur entre deux leaf (B)
  mesures_ls.sh                S6  : débit, liens et MAC de B, mêmes flux qu'en S3
  pannes_ls.sh                 S6  : pannes de lien, de spine et de leaf, avec et sans BFD (B)
  mac_l2.sh                    S6  : MAC apprises sur A, pour la comparaison
mesures/                       résultats des scripts (un dossier par lancement, horodaté)
```

## Lancer les labs

**Prérequis** : un hôte Linux avec Docker et [Containerlab](https://containerlab.dev), les modules noyau `bridge`, `8021q`, `vxlan` et `vrf`, et les images `ghcr.io/srl-labs/network-multitool` et `quay.io/frrouting/frr:10.2.1`. Selon l'installation de Containerlab, ses commandes demandent `sudo`.

Toutes les commandes se lancent depuis la racine du dépôt. Les deux labs utilisent les mêmes noms de serveurs : en déployer un seul à la fois.

```bash
# Architecture A
containerlab deploy -t l2.clab.yml
bash l2.sh                          # ~1 min (attente de STP) ; RATE= bash l2.sh pour ne pas limiter les liens
bash scripts/mesures_l2.sh          # S3, ~8 min
bash scripts/tempete_l2.sh          # S4, ~2 min
bash scripts/mac_l2.sh              # S6
containerlab destroy -t l2.clab.yml

# Architecture B
containerlab deploy -t leaf_spine.clab.yml
bash leaf_spine.sh
bash scripts/verif_evpn.sh          # S5, doit afficher 15 / 15
bash scripts/mobilite_ls.sh         # S6 (pas plus de 2 lancements en 3 min, voir plus bas)
bash scripts/mesures_ls.sh          # S6, ~2 min
bash scripts/pannes_ls.sh           # S6, ~15 min
containerlab destroy -t leaf_spine.clab.yml
```

Chaque script écrit ses résultats dans un nouveau dossier `mesures/<nom>_<date>_<heure>/`. Les sorties de `verif_evpn.sh` (`mesures/evpn_*`) et les pings bruts de `pannes_ls.sh` ne sont pas versionnés : ils se régénèrent en relançant le script.

## Avancement, de S1 à S6

| Semaine | Objectif du cahier des charges | Réalisé |
|---|---|---|
| **S1** | Conception des deux architectures, plans d'adressage underlay / overlay et VNI | [conception.pdf](conception.pdf) : exigences, architectures A et B, adressage, modélisation des flux et des pannes |
| **S2** | Déploiement de A avec STP et des serveurs des locataires | `l2.clab.yml`, `l2.sh` : 8 ponts Linux avec STP, 4 VLAN, passerelles par VRF sur les agrégations, 8 serveurs ; liens inter-commutateurs bridés à 1 Gbit/s |
| **S3** | Mesures de référence : débit, convergence STP, utilisation des liens | `scripts/mesures_l2.sh` → `mesures/run_20261128_155050` |
| **S4** | Boucle / tempête de diffusion et limites | `scripts/tempete_l2.sh` → `mesures/tempete_20261128_141736` |
| **S5** | Migration : underlay eBGP + ECMP, VXLAN / EVPN (L2VNI), puis L3VNI et passerelle anycast | `leaf_spine.clab.yml`, `leaf_spine.sh`, `configs/` ; vérifié par `scripts/verif_evpn.sh` (15 / 15) |
| **S6** | Mobilité d'un serveur, pannes de spine et de leaf, BFD, comparaison avec l'état initial | `scripts/mobilite_ls.sh`, `pannes_ls.sh`, `mesures_ls.sh`, `mac_l2.sh` → `mesures/mobilite_*`, `pannes_*`, `ls_*`, `mac_l2_*` |
| S7 | Analyse Wireshark de l'encapsulation VXLAN et des routes EVPN, MTU | à faire |
| S8 | Rapport, démonstration d'une panne sans interruption notable | à faire |

## Résultats

### Comparaison A / B

| Indicateur | A : 3 niveaux, L2 + STP | B : leaf-spine VXLAN / EVPN |
|---|---|---|
| Liens inter-commutateurs actifs (ENF1) | 7 sur 13 (6 bloqués par STP) | 8 sur 8 |
| Chemins utilisés entre deux serveurs éloignés | 1 | 2 en parallèle, ~2,5 Go sur chacun |
| Débit, 1 flux | 957 Mbit/s | 926 Mbit/s (−3 % : 50 o d'en-tête VXLAN pour 1500 o) |
| Débit, 4 flux | 956 Mbit/s | 1,85 Gbit/s |
| Coupure à la panne d'un lien montant (ENF2) | 30,3 à 30,9 s | 0,12 à 0,14 s (lien coupé), 0,09 à 0,65 s (lien silencieux, BFD) |
| Coupure quand on rebranche ce lien | 29,0 à 30,8 s | 0 |
| Panne d'un commutateur d'accès / d'un leaf (ENF4) | ses serveurs sont isolés (attendu, non mesuré) | ses serveurs sont isolés, rien d'autre n'est touché (mesuré) |
| MAC apprises sur le cœur / les spines | 6 sur chaque cœur | 0 |
| MAC apprises sur l'accès / les leaf | 8 à 9 | 14 (8 serveurs appris par EVPN, et router-MAC des autres leaf) |
| Mobilité d'un serveur (EF4) | — | 0,13 s, IP et passerelle inchangées |
| Tempête de diffusion | 100 % de perte dans tout le domaine L2 | non mesurée |

Chaque leaf porte les 4 VNI dans ce petit lab : EVPN ne réduit donc pas le nombre de MAC sur les leaf. Le gain est ailleurs : les MAC sont apprises par BGP et non par inondation, et le cœur de la fabrique n'en porte aucune.

### A : référence (S3, S4)

| Indicateur | Valeur |
|---|---|
| Liens bloqués par STP | 6 sur 13 |
| Liens traversés par un flux acc1 → acc4 | 2 sur 13 (acc1–agg1, agg1–acc4 ; cœurs inutilisés) |
| Débit acc1 → acc4, 1 flux / 4 flux | 957 / 956 Mbit/s |
| Coupure à la panne du lien actif de acc1 | 30,4 / 30,3 / 30,9 s |
| Coupure au rétablissement de ce lien | 29,0 / 30,5 / 30,8 s |
| Tempête (STP coupé) : paquets/s sur un lien du cœur | ~27 500 |
| Tempête : CPU de l'hôte en traitement de paquets (softirq) | 6,3 % (≈ 1 cœur sur 16) |
| Tempête : perte ping / débit iperf | 70 à 100 % / 0 |
| Tempête : ports où la MAC de h11 est vue sur core1 | 3 (table MAC instable) |

Les deux coupures valent 2 × forward delay (2 × 15 s) : en STP 802.1D, le port qui prend le relais passe par les états listening puis learning avant de transmettre. Rebrancher le lien coupe donc aussi le trafic.

### B : vérification (S5)

| Exigence | Test | Résultat |
|---|---|---|
| Underlay | 2 sessions eBGP + BFD par leaf, 2 next-hops vers chaque loopback | OK (ECMP) |
| EF1 | h11→h12, h21→h22, h13→h14 (même sous-réseau, leaf différents, L2VNI) | 0 % de perte |
| EF3 | h11→h13, h12→h14, h21→h24 (sous-réseaux différents, L3VNI) | 0 % de perte |
| EF2 | h11→h21, h11→h23, h22→h12 (locataires différents) | 100 % de perte : isolés |
| ENF5 | paquet de 1500 o non fragmentable, en L2VNI et en L3VNI | 0 % de perte |
| EF3 | chaque leaf reçoit les 16 routes type 5 | OK sur les 4 leaf |

Vu de leaf1 : 16 routes type 2 (MAC et MAC+IP des 8 serveurs), 16 type 3 (4 VTEP × 4 L2VNI), 16 type 5 (4 leaf × 2 VRF × 2 sous-réseaux). Le routage entre sous-réseaux est symétrique : un paquet de h11 vers h13 est routé sur leaf1, transporté dans le L3VNI 50001, puis routé de nouveau sur leaf3.

### B : mobilité (S6, EF4)

h11 passe de leaf1 à leaf3 par un second câble, puis revient, en gardant sa MAC et son IP.

| Étape | VTEP qui annonce h11 | Séquence MAC mobility | Passerelle vue par h11 |
|---|---|---|---|
| h11 sur leaf1 | 10.0.0.11 | 0 | 02:00:00:00:00:01 |
| h11 déplacé sur leaf3 | 10.0.0.13 | 1 | 02:00:00:00:00:01 |
| h11 revenu sur leaf1 | 10.0.0.11 | 2 | 02:00:00:00:00:01 |

Coupure de 0,13 s pour h12 (même sous-réseau), 0 pour h13 (routé), dans les deux sens.

### B : pannes (S6)

Chaque panne dure 15 s, 3 essais par scénario, 5 flux mesurés en même temps. ECMP les répartit sur des chemins différents : un flux qui ne passe pas par l'élément en panne ne voit rien.

| Scénario | BFD | Flux touchés | Coupure | Au rétablissement |
|---|---|---|---|---|
| Lien leaf1–spine1 coupé (interface down) | oui | 6 / 15 | 0,12 à 0,14 s | 0 |
| Lien leaf1–spine1 silencieux (reste up, ne transmet plus) | oui | 8 / 15 | 0,09 à 0,65 s | 0 |
| idem | **non** | 9 / 15 | 6,7 à 9,1 s | 0 |
| spine1 entièrement silencieux | oui | 11 / 15 | 0,09 à 0,93 s | 0 |
| idem | **non** | 12 / 15 | 6,0 à 9,5 s | 0 |
| leaf4 silencieux : flux des autres leaf | oui | 0 / 9 | 0 | 0 |
| leaf4 silencieux : serveurs de leaf4 | oui | 6 / 6 | 17,4 à 18,3 s (15 s de panne + 2,4 à 3,3 s de reconvergence) | — |

- BFD (100 ms × 3) détecte une panne invisible pour l'interface en ~0,3 s : la coupure reste sous la seconde, contre 6 à 9,5 s sans BFD (hold timer BGP de 9 s).
- La panne de spine est provoquée lien par lien, en ~0,1 s par commande : elle s'installe sur près d'une seconde, d'où la dispersion des valeurs.
- Rétablir un lien ou un spine ne coupe rien : la session BGP revient et ECMP rajoute le chemin.

### Méthode de mesure

- Coupures : pings horodatés (`ping -D`), 100 par seconde en B et 5 par seconde en A. Une coupure est l'écart entre deux réponses consécutives (plus de 50 ms en B, plus de 0,5 s en A). Compter les pings perdus et les multiplier par l'intervalle sous-estime les coupures, car ping ne tient pas son rythme dans un conteneur ; la durée est bornée par `timeout`, car `ping -w` s'arrête à la première erreur ICMP.
- Débit : `iperf3` entre serveurs, 1, 4 ou 8 flux.
- Utilisation des liens : octets émis par chaque interface pendant 20 s de trafic.
- Panne silencieuse : un filtre `tc` jette tout le trafic entrant, des deux côtés du lien, alors que l'interface reste up.
- CPU de la tempête : lu dans `/proc/stat` de l'hôte, car le pont Linux commute dans le noyau, hors des conteneurs (`docker stats` affiche 0 %).

## Choix de mise en œuvre et écarts à la conception

**Écarts à la conception**
- **STP et non RSTP** : le pont du noyau Linux ne fait que du 802.1D. RSTP convergerait en quelques secondes, toujours loin de BFD.
- **Passerelle de type VRRP sans protocole VRRP** : agg1 porte l'IP virtuelle `.1` (et `.2`), agg2 porte `.3`. L'image n'a pas de démon VRRP, donc `.1` ne bascule pas automatiquement vers agg2.
- **Liens bridés à 1 Gbit/s** (`tc tbf`) entre commutateurs, en A comme en B : sans plafond, un seul lien virtuel dépasse 20 Gbit/s et l'apport d'ECMP n'apparaît pas dans le débit.
- **Plan de ports de B complété** par un câble `client1:eth2 – leaf3:eth5` (VLAN 10), inactif côté serveur, pour déplacer h11 sans changer sa MAC ni son IP.

**Choix pour B, non détaillés dans la conception**
- Un seul pont `br0` par leaf, avec VLAN, et un périphérique VXLAN par VNI rattaché à son VLAN.
- Chaque L3VNI utilise un VLAN interne (4001 pour VRF-T1, 4002 pour VRF-T2) ; son interface, rangée dans le VRF, porte la router-MAC EVPN propre au leaf.
- Sur les spines, `attribute-unchanged next-hop` en EVPN : le next-hop reste le VTEP du leaf d'origine.
- Hachage ECMP sur les ports (`fib_multipath_hash_policy=1`) : le port UDP source VXLAN varie selon le flux transporté.

**Problèmes rencontrés et corrigés dans B**
- **Routes type 5 manquantes** : le profil FRR `datacenter` active `deterministic-med`, et un leaf configuré après les autres préférait une route importée à son propre sous-réseau. Corrigé par `no bgp deterministic-med` dans les VRF.
- **ECMP inopérant sur le trafic routé** : le pilote VXLAN de Linux met en cache, par CPU, la route vers chaque VTEP, et tous les flux d'un même CPU prenaient le même spine (923 Mbit/s avec 8 flux). Les paquets sont marqués à la sortie des interfaces VXLAN (`tc ... skbedit mark 1`), ce qui contourne ce cache (1,85 Gbit/s).
- **Trafic routé coupé après la mobilité** : l'ancien leaf gardait une entrée ARP locale vers le serveur déplacé. Corrigé par `arp_accept=1` sur les passerelles : l'ARP gratuit du serveur crée tout de suite son entrée sur le nouveau leaf.
- **Mobilité limitée par FRR** : une MAC qui change de leaf plus de 5 fois en 180 s est gelée (détection de doublon). `mobilite_ls.sh` fait 2 déplacements : ne pas le relancer plus de 2 fois en 3 minutes.

## Reste à faire

- **S7** : analyse Wireshark de l'encapsulation VXLAN et des routes EVPN (types 2, 3 et 5), vérification de la MTU.
- **S8** : rapport et démonstration d'une panne sans interruption notable.
- Supervision Prometheus / Grafana (outil imposé par le cahier des charges).
- Tempête de diffusion dans B, pour compléter la comparaison avec A (conception, section 5.6).
- Bascule automatique de la passerelle dans A (démon VRRP).
