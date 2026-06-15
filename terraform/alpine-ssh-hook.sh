#!/bin/sh
# =============================================================================
# 🔧 Proxmox LXC Hook Script — Alpine SSH Bootstrap
# =============================================================================
# Dipanggil otomatis oleh Proxmox setiap kali ada event pada CT.
# Script ini menyalakan SSH (sshd) di Alpine container yang secara default
# menonaktifkannya — supaya Terraform remote-exec bisa langsung masuk.
#
# File ini di-upload OTOMATIS oleh Terraform sebagai snippet ke Proxmox.
# Tidak perlu pasang manual! (File ini hanya referensi.)
#
# Prasyarat di Proxmox (sekali saja, per node):
#   mkdir -p /var/lib/vz/snippets
#   pvesm set local --content iso,backup,vztmpl,snippets
#
# API Token harus dari user root@pam dengan --privsep=0:
#   pveum user token add root@pam terraform --privsep=0
# =============================================================================

VMID=$1
PHASE=$2

case "$PHASE" in
  post-start)
    # Tunggu CT benar-benar siap (Alpine init butuh beberapa detik)
    for i in 1 2 3 4 5 6 7 8 9 10; do
      pct exec "$VMID" -- test -f /etc/alpine-release 2>/dev/null && break
      sleep 2
    done

    # Enable & start SSH di Alpine
    pct exec "$VMID" -- sh -c '
      if [ -f /etc/alpine-release ]; then
        if [ -f /etc/ssh/sshd_config ]; then
          sed -i "s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/" /etc/ssh/sshd_config
          sed -i "s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
        fi
        rc-service sshd start
        # Tunggu sshd benar-benar listen
        for i in 1 2 3 4 5; do
          nc -z localhost 22 2>/dev/null && break
          sleep 1
        done
      fi
    '
    ;;
esac
