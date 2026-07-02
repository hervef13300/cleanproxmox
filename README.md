# cleanproxmox

Boîte à outils d'administration et de **nettoyage d'un nœud Proxmox VE**, pilotée par un menu unique (`proxmox-admin.sh`).

> ⚠️ **Opérations DESTRUCTIVES et IRRÉVERSIBLES.** À exécuter en **root**, **directement sur le nœud Proxmox**. Utilisez toujours le **mode simulation (dry-run)** avant une exécution réelle.

---

## Fonctionnalités

Le script propose un menu avec les actions suivantes :

| # | Action | Détail |
|---|--------|--------|
| 1 | Basculer le mode simulation | Active/désactive le **dry-run** (affiche sans exécuter). |
| 2 | Nettoyer les VM / LXC | Arrête puis **détruit** les VM (`qm`) et, en option, les conteneurs LXC (`pct`). Exclusions et `--purge` possibles. |
| 3 | Désinstaller les VPN mesh | Retire proprement **NetBird**, **ZeroTier** et **Tailscale** (déconnexion → arrêt service → suppression paquet → purge config). |
| 4 | Mettre à jour le système | `apt update` + `full-upgrade` + `autoremove --purge` + `autoclean`. |
| 5 | Réinitialiser les cartes réseau | Remet à zéro toutes les cartes physiques **sauf la première**, qui reste sur le pont `vmbr0` en **172.16.0.254/24**. |
| 6 | TOUT exécuter | Enchaîne 2 → 3 → 4 → 5. |
| 0 | Quitter | |

---

## Utilisation rapide

À lancer **en root** sur le nœud Proxmox.

**Menu interactif (recommandé)** — garde le clavier actif :

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/hervef13300/cleanproxmox/main/proxmox-admin.sh)
```

**Simulation d'abord (aucune modification)** :

```bash
curl -fsSL https://raw.githubusercontent.com/hervef13300/cleanproxmox/main/proxmox-admin.sh -o /tmp/proxmox-admin.sh
bash /tmp/proxmox-admin.sh --dry-run
```

**Installation locale** :

```bash
git clone https://github.com/hervef13300/cleanproxmox.git
cd cleanproxmox
chmod +x proxmox-admin.sh
./proxmox-admin.sh            # mode réel
./proxmox-admin.sh --dry-run  # simulation
```

> ❌ **N'utilisez pas** `curl <URL> | bash` : le menu a besoin du clavier sur `stdin`, que le pipe remplace par le flux de `curl`. Utilisez `bash <(curl ...)` ou téléchargez d'abord le fichier.

---

## Sécurités intégrées

- **Mode dry-run** global (option 1 du menu, ou argument `--dry-run` / `-n` au lancement) : toutes les commandes sont affichées mais **rien n'est exécuté**.
- **Confirmations par mot-clé** distinctes selon la gravité :
  - `SUPPRIMER` → destruction des VM/LXC
  - `OUI` → désinstallation des VPN
  - `RESEAU` → écrasement de la configuration réseau
- **Opérations best-effort** : un service déjà arrêté ou un paquet absent n'interrompt pas le script.
- **Vérification root** et présence des commandes (`qm`, `apt-get`) avant d'agir.

---

## Réinitialisation réseau (option 5) — détails

- Détecte les **cartes physiques** via `/sys/class/net/*/device` (ignore ponts, bonds, tap, veth), triées par nom.
- La **première carte** est rattachée au pont de gestion **`vmbr0`** avec l'IP statique conservée.
- Les **autres cartes** sont réinitialisées (`iface X inet manual`, non configurées).
- L'ancien `/etc/network/interfaces` est **sauvegardé** dans `interfaces.bak.<date>` avant écrasement.
- La configuration **n'est pas appliquée automatiquement** (pour ne pas couper une session SSH distante) : le script propose ensuite `ifreload -a`, et rappelle la commande de restauration.

### Paramètres à vérifier avant usage

En tête de `proxmox-admin.sh` :

```bash
MGMT_IP="172.16.0.254"   # IP conservée sur la 1ère carte (pont vmbr0)
MGMT_CIDR="24"           # Masque CIDR (24 = 255.255.255.0)
MGMT_GW="172.16.0.1"     # Passerelle par défaut
MGMT_BRIDGE="vmbr0"      # Nom du pont de gestion Proxmox
```

Restauration manuelle en cas de problème :

```bash
cp /etc/network/interfaces.bak.<date> /etc/network/interfaces && ifreload -a
```

---

## Prérequis

- Nœud **Proxmox VE** (Debian) — commandes `qm`, `pct`, `apt-get`.
- Exécution en **root**.
- Un **redémarrage** est conseillé si le noyau a été mis à jour (option 4).

---

## Licence

Usage interne / pédagogique (SIO SISR). À adapter à votre environnement avant toute exécution en production.
