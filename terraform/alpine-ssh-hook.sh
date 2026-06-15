#!/bin/sh
# =============================================================================
# 🔧 Proxmox LXC Hook Script — Alpine SSH Bootstrap
# =============================================================================
# Dipanggil otomatis oleh Proxmox setiap kali ada event pada CT.
# Script ini menyalakan SSH (sshd) di Alpine container yang secara default
# menonaktifkannya — supaya Terraform remote-exec bisa langsung masuk.
#
# Cara pasang (sekali saja, di Proxmox host):
#   mkdir -p /var/lib/vz/snippets
#   cp alpine-ssh-hook.sh /var/lib/vz/snippets/
#   chmod +x /var/lib/vz/snippets/alpine-ssh-hook.sh
# =============================================================================

VMID=$1
PHASE=$2

case "$PHASE" in
  post-start)
    # Cek apakah ini Alpine (punya /etc/alpine-release)
    pct exec "$VMID" -- sh -c '
      if [ -f /etc/alpine-release ]; then
        if [ -f /etc/ssh/sshd_config ]; then
          sed -i "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
          sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
        fi
        rc-service sshd start
      fi
    ' 2>/dev/null
    ;;
esac
