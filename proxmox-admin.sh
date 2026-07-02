#!/usr/bin/env bash
#
# proxmox-admin.sh — Boîte à outils d'administration/nettoyage d'un nœud
# Proxmox VE, pilotée par menu.
#
#   1. Nettoyage des VM (et LXC) — arrêt + destruction.
#   2. Désinstallation des clients mesh VPN : NetBird, ZeroTier, Tailscale.
#   3. Mise à jour complète du système (APT).
#   4. Réinitialisation des cartes réseau (la 1ère reste en 172.16.0.254).
#
# ATTENTION : opérations DESTRUCTIVES et IRRÉVERSIBLES. Le mode dry-run
# (simulation) est activable depuis le menu — utilisez-le d'abord.
#
# À exécuter en root DIRECTEMENT sur le nœud Proxmox VE.
#
# ---------------------------------------------------------------------------
# INSTALLATION RAPIDE (copier-coller, en root sur le nœud)
# ---------------------------------------------------------------------------
# URL brute du script (dépôt public GitHub).
#
#   Menu interactif — recommandé (garde le clavier actif) :
#     bash <(curl -fsSL https://raw.githubusercontent.com/hervef13300/cleanproxmox/main/proxmox-admin.sh)
#
#   Ou télécharger puis exécuter :
#     curl -fsSL https://raw.githubusercontent.com/hervef13300/cleanproxmox/main/proxmox-admin.sh -o /tmp/proxmox-admin.sh && bash /tmp/proxmox-admin.sh
#
#   Simulation d'abord (aucune modification) :
#     curl -fsSL https://raw.githubusercontent.com/hervef13300/cleanproxmox/main/proxmox-admin.sh -o /tmp/proxmox-admin.sh && bash /tmp/proxmox-admin.sh --dry-run
#
# NB : « curl <URL> | bash » NE fonctionne PAS ici (le menu a besoin du
#      clavier sur stdin) — utilisez bien l'une des formes ci-dessus.
# ---------------------------------------------------------------------------
set -uo pipefail

# ===========================================================================
# Paramètres réseau (adaptez si besoin AVANT d'utiliser l'option 4)
# ===========================================================================
MGMT_IP="172.16.0.254"     # IP conservée sur la 1ère carte (pont vmbr0)
MGMT_CIDR="24"             # Masque en notation CIDR
MGMT_GW="172.16.0.1"       # Passerelle par défaut
MGMT_BRIDGE="vmbr0"        # Nom du pont de gestion Proxmox

# ===========================================================================
# État global
# ===========================================================================
DRY_RUN=0                  # 1 = simulation : rien n'est réellement exécuté

# ---------------------------------------------------------------------------
# Utilitaires
# ---------------------------------------------------------------------------
have() { command -v "$1" >/dev/null 2>&1; }
pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed"; }

# Exécute une commande, ou l'affiche seulement en mode dry-run.
run() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        echo "  -> $*"
        "$@"
    fi
}

# Comme run, mais n'interrompt jamais (best-effort : service déjà arrêté, etc.).
run_soft() {
    if [[ $DRY_RUN -eq 1 ]]; then
        echo "  [dry-run] $*"
    else
        echo "  -> $*"
        "$@" || echo "     (ignoré : code de sortie $?)"
    fi
}

pause() { read -r -p "  (Entrée pour revenir au menu) " _; }

confirm() {
    # confirm "message" "MOT" -> renvoie 0 si l'utilisateur tape MOT exactement.
    local msg="$1" word="$2" reply
    read -r -p "$msg Tapez '$word' : " reply
    [[ "$reply" == "$word" ]]
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Erreur : ce script doit être exécuté en root sur le nœud Proxmox." >&2
        exit 1
    fi
}

# ===========================================================================
# 1. Nettoyage des VM / LXC
# ===========================================================================
action_nettoyage_vm() {
    echo
    echo "### Nettoyage des VM / LXC ###"
    if ! have qm; then
        echo "Commande 'qm' introuvable — ce n'est pas un hôte Proxmox VE."
        return
    fi

    local inc_lxc purge tmo excl reply
    read -r -p "Traiter aussi les conteneurs LXC ? [o/N] : " reply
    [[ "$reply" =~ ^[oOyY]$ ]] && inc_lxc=1 || inc_lxc=0
    read -r -p "Ajouter --purge (supprime backups/jobs liés) ? [o/N] : " reply
    [[ "$reply" =~ ^[oOyY]$ ]] && purge=1 || purge=0
    read -r -p "Délai avant arrêt forcé (secondes) [60] : " tmo
    [[ -z "$tmo" ]] && tmo=60
    read -r -p "VMID/CTID à EXCLURE (séparés par espace, vide = aucune) : " excl

    local -a EXCLUDES=(); [[ -n "$excl" ]] && read -r -a EXCLUDES <<< "$excl"
    local -a PURGE_FLAG=(); [[ $purge -eq 1 ]] && PURGE_FLAG=(--purge)

    is_excluded() {
        local id="$1" ex
        for ex in "${EXCLUDES[@]:-}"; do [[ "$id" == "$ex" ]] && return 0; done
        return 1
    }

    local -a VMIDS CT_IDS
    mapfile -t VMIDS < <(qm list 2>/dev/null | awk 'NR>1 {print $1}')
    CT_IDS=()
    if [[ $inc_lxc -eq 1 ]] && have pct; then
        mapfile -t CT_IDS < <(pct list 2>/dev/null | awk 'NR>1 {print $1}')
    fi

    if [[ ${#VMIDS[@]} -eq 0 && ${#CT_IDS[@]} -eq 0 ]]; then
        echo "Aucune VM ni conteneur trouvé. Rien à faire."
        return
    fi

    echo "----------------------------------------------------------------"
    echo "VM détectées : ${VMIDS[*]:-aucune}"
    [[ $inc_lxc -eq 1 ]] && echo "LXC détectés : ${CT_IDS[*]:-aucun}"
    echo "Exclusions   : ${EXCLUDES[*]:-aucune}"
    echo "Purge        : $([[ $purge -eq 1 ]] && echo oui || echo non)"
    echo "Mode         : $([[ $DRY_RUN -eq 1 ]] && echo 'DRY-RUN' || echo 'RÉEL — DESTRUCTIF')"
    echo "----------------------------------------------------------------"

    if [[ $DRY_RUN -eq 0 ]]; then
        confirm "SUPPRESSION DÉFINITIVE des VM/LXC ci-dessus ?" "SUPPRIMER" || { echo "Annulé."; return; }
    fi

    local id status
    for id in "${VMIDS[@]}"; do
        if is_excluded "$id"; then echo "VM $id : exclue, ignorée."; continue; fi
        echo "VM $id : arrêt puis destruction..."
        status=$(qm status "$id" 2>/dev/null | awk '{print $2}')
        if [[ "$status" == "running" ]]; then
            run_soft qm shutdown "$id" --timeout "$tmo" --forceStop 1 \
                || run_soft qm stop "$id"
        fi
        run_soft qm destroy "$id" "${PURGE_FLAG[@]}" --destroy-unreferenced-disks 1
    done

    for id in "${CT_IDS[@]:-}"; do
        [[ -z "$id" ]] && continue
        if is_excluded "$id"; then echo "CT $id : exclu, ignoré."; continue; fi
        echo "CT $id : arrêt puis destruction..."
        status=$(pct status "$id" 2>/dev/null | awk '{print $2}')
        if [[ "$status" == "running" ]]; then
            run_soft pct shutdown "$id" --forceStop 1 || run_soft pct stop "$id"
        fi
        run_soft pct destroy "$id" "${PURGE_FLAG[@]}"
    done
    echo "Nettoyage VM/LXC terminé.$([[ $DRY_RUN -eq 1 ]] && echo ' (simulation)')"
}

# ===========================================================================
# 2. Désinstallation des VPN mesh
# ===========================================================================
remove_pkg() {
    local pkg="$1" purge="$2"
    if pkg_installed "$pkg"; then
        if [[ $purge -eq 1 ]]; then run apt-get purge -y "$pkg"
        else run apt-get remove -y "$pkg"; fi
    else
        echo "  paquet '$pkg' non installé, ignoré."
    fi
}
purge_path() { local p="$1" purge="$2"; [[ $purge -eq 0 ]] && return 0; [[ -e "$p" ]] && run rm -rf "$p"; }

action_desinstall_vpn() {
    echo
    echo "### Désinstallation NetBird / ZeroTier / Tailscale ###"
    if ! have apt-get; then echo "'apt-get' introuvable (Debian/Ubuntu requis)."; return; fi
    export DEBIAN_FRONTEND=noninteractive

    local purge reply
    read -r -p "Supprimer aussi la config/état résiduels (purge) ? [o/N] : " reply
    [[ "$reply" =~ ^[oOyY]$ ]] && purge=1 || purge=0

    if [[ $DRY_RUN -eq 0 ]]; then
        confirm "Désinstaller les 3 clients VPN ?" "OUI" || { echo "Annulé."; return; }
    fi

    echo "--- NetBird ---"
    if have netbird; then
        run_soft netbird down
        run_soft netbird service stop
        run_soft netbird service uninstall
    fi
    run_soft systemctl stop netbird
    remove_pkg netbird "$purge"
    remove_pkg netbird-ui "$purge"
    purge_path /etc/netbird "$purge"
    purge_path /var/lib/netbird "$purge"

    echo "--- ZeroTier ---"
    if have zerotier-cli; then
        local nets nw
        nets=$(zerotier-cli -j listnetworks 2>/dev/null \
                 | grep -o '"nwid":[[:space:]]*"[0-9a-f]*"' \
                 | grep -o '[0-9a-f]\{16\}' || true)
        for nw in $nets; do run_soft zerotier-cli leave "$nw"; done
    fi
    run_soft systemctl stop zerotier-one
    run_soft systemctl disable zerotier-one
    remove_pkg zerotier-one "$purge"
    purge_path /var/lib/zerotier-one "$purge"

    echo "--- Tailscale ---"
    if have tailscale; then
        run_soft tailscale down
        run_soft tailscale logout
    fi
    run_soft systemctl stop tailscaled
    run_soft systemctl disable tailscaled
    remove_pkg tailscale "$purge"
    purge_path /var/lib/tailscale "$purge"
    purge_path /etc/default/tailscaled "$purge"

    [[ $DRY_RUN -eq 0 ]] && systemctl daemon-reload 2>/dev/null
    echo "Désinstallation VPN terminée.$([[ $DRY_RUN -eq 1 ]] && echo ' (simulation)')"
}

# ===========================================================================
# 3. Mise à jour du système
# ===========================================================================
action_maj_systeme() {
    echo
    echo "### Mise à jour du système (APT) ###"
    if ! have apt-get; then echo "'apt-get' introuvable (Debian/Ubuntu requis)."; return; fi
    export DEBIAN_FRONTEND=noninteractive
    run apt-get update
    run apt-get -y full-upgrade
    run apt-get -y autoremove --purge
    run apt-get -y autoclean
    echo "Mise à jour terminée.$([[ $DRY_RUN -eq 1 ]] && echo ' (simulation)')"
    echo "Note : redémarrez si le noyau a été mis à jour."
}

# ===========================================================================
# 4. Réinitialisation des cartes réseau
# ===========================================================================
detect_nics() {
    # Cartes physiques uniquement (présence d'un lien 'device'), triées.
    local d n
    for d in /sys/class/net/*; do
        n=$(basename "$d")
        [[ -e "$d/device" ]] && echo "$n"
    done | sort
}

action_reset_reseau() {
    echo
    echo "### Réinitialisation des cartes réseau ###"
    local iface_file="/etc/network/interfaces"
    if [[ ! -f "$iface_file" ]]; then
        echo "Fichier $iface_file introuvable — hôte non Debian/Proxmox ?"
        return
    fi

    local -a NICS
    mapfile -t NICS < <(detect_nics)
    if [[ ${#NICS[@]} -eq 0 ]]; then
        echo "Aucune carte réseau physique détectée."
        return
    fi

    local first="${NICS[0]}"
    local -a others=("${NICS[@]:1}")

    echo "Cartes physiques détectées : ${NICS[*]}"
    echo "  1ère carte (conservée)   : $first  ->  $MGMT_BRIDGE = $MGMT_IP/$MGMT_CIDR (gw $MGMT_GW)"
    echo "  Cartes réinitialisées    : ${others[*]:-aucune}"
    echo "----------------------------------------------------------------"

    # Construction de la nouvelle configuration.
    local newcfg
    newcfg=$(cat <<EOF
# Généré par proxmox-admin.sh — $(date '+%Y-%m-%d %H:%M:%S')
# Sauvegarde de l'ancienne config : ${iface_file}.bak.*

auto lo
iface lo inet loopback

# Première carte : rattachée au pont de gestion.
auto $first
iface $first inet manual

auto $MGMT_BRIDGE
iface $MGMT_BRIDGE inet static
	address $MGMT_IP/$MGMT_CIDR
	gateway $MGMT_GW
	bridge-ports $first
	bridge-stp off
	bridge-fd 0
EOF
)
    # Autres cartes : réinitialisées (non configurées).
    local nic
    for nic in "${others[@]:-}"; do
        [[ -z "$nic" ]] && continue
        newcfg+=$'\n\n'"# Carte réinitialisée (non configurée)."$'\n'"iface $nic inet manual"
    done

    echo "Nouvelle configuration proposée :"
    echo "----------------------------------------------------------------"
    printf '%s\n' "$newcfg"
    echo "----------------------------------------------------------------"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[dry-run] Aucune écriture. (Sauvegarde + remplacement non effectués.)"
        return
    fi

    confirm "ÉCRASER $iface_file avec la config ci-dessus ?" "RESEAU" \
        || { echo "Annulé — rien modifié."; return; }

    local backup="${iface_file}.bak.$(date '+%Y%m%d-%H%M%S')"
    cp -a "$iface_file" "$backup"
    echo "  -> sauvegarde : $backup"
    printf '%s\n' "$newcfg" > "$iface_file"
    echo "  -> $iface_file mis à jour."

    echo
    echo "ATTENTION : appliquer maintenant peut couper une session SSH distante."
    local reply
    read -r -p "Appliquer immédiatement (ifreload -a) ? [o/N] : " reply
    if [[ "$reply" =~ ^[oOyY]$ ]]; then
        if have ifreload; then run_soft ifreload -a
        else run_soft systemctl restart networking; fi
        echo "Config réseau appliquée."
    else
        echo "Non appliqué. Vérifiez le fichier puis lancez :  ifreload -a"
        echo "En cas de problème, restaurez :  cp $backup $iface_file && ifreload -a"
    fi
}

# ===========================================================================
# 6. Tout exécuter
# ===========================================================================
action_tout() {
    echo
    echo ">>> Exécution de TOUTES les opérations (dans l'ordre) <<<"
    action_nettoyage_vm
    action_desinstall_vpn
    action_maj_systeme
    action_reset_reseau
}

# ===========================================================================
# Menu principal
# ===========================================================================
require_root

# Option CLI : --dry-run active la simulation dès le démarrage.
[[ "${1:-}" == "--dry-run" || "${1:-}" == "-n" ]] && DRY_RUN=1

while true; do
    echo
    echo "================================================================"
    echo " ADMIN PROXMOX — $(hostname)    [Mode : $([[ $DRY_RUN -eq 1 ]] && echo 'SIMULATION (dry-run)' || echo 'RÉEL')]"
    echo "================================================================"
    echo "  1) Basculer le mode simulation (dry-run) ON/OFF"
    echo "  2) Nettoyer les VM / LXC (arrêt + destruction)"
    echo "  3) Désinstaller NetBird / ZeroTier / Tailscale"
    echo "  4) Mettre à jour le système (apt full-upgrade)"
    echo "  5) Réinitialiser les cartes réseau (1ère = $MGMT_IP)"
    echo "  6) TOUT exécuter (2 -> 3 -> 4 -> 5)"
    echo "  0) Quitter"
    echo "----------------------------------------------------------------"
    read -r -p "Votre choix : " choix
    case "$choix" in
        1) DRY_RUN=$((1 - DRY_RUN)); echo "Mode simulation : $([[ $DRY_RUN -eq 1 ]] && echo ON || echo OFF)." ;;
        2) action_nettoyage_vm; pause ;;
        3) action_desinstall_vpn; pause ;;
        4) action_maj_systeme; pause ;;
        5) action_reset_reseau; pause ;;
        6) action_tout; pause ;;
        0|q|Q) echo "Au revoir."; exit 0 ;;
        *) echo "Choix invalide." ;;
    esac
done
