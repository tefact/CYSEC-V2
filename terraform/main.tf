# https://registry.terraform.io/providers/bpg/proxmox/0.60.0
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = ">= 0.60.0"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = true

  # SSH dibutuhkan untuk upload file (snippet/hook script) ke Proxmox node.
  ssh {
    agent    = false
    username = "root"
    private_key = var.ssh_private_key
  }
}

# ==========================================
# 📄 Hook Script — Alpine SSH Bootstrap
# ==========================================
# Upload snippet ke Proxmox storage supaya bisa dipakai sebagai hook_script.
# Hook ini jalan otomatis tiap CT start: nyalakan sshd di Alpine.
resource "proxmox_virtual_environment_file" "alpine_ssh_hook" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "node1"

  file_mode = "0700"

  source_raw {
    data      = <<-HOOK
      #!/bin/sh
      VMID=$1
      PHASE=$2
      case "$PHASE" in
        post-start)
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
    HOOK
    file_name = "alpine-ssh-hook.sh"
  }
}

# ==========================================
# 🌐 LXC 1 — CT web1 (Node: node1)
# ==========================================
resource "proxmox_virtual_environment_container" "web1" {
  node_name    = "node1"
  vm_id        = 111
  unprivileged = true
  started      = true

  description = "CT web1 - Active-Active Edge Node (node1)"

  initialization {
    hostname = "web1"

    ip_config {
      ipv4 {
        address = "10.10.10.111/24"
        gateway = "10.10.10.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  cpu {
    cores = var.ct_cpu_cores
  }

  memory {
    dedicated = var.ct_memory
  }

  disk {
    datastore_id = "local-lvm"
    size         = var.ct_disk_size
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = var.ct_os_template
    type             = "alpine"
  }

  features {
    nesting = true
  }

  # ── Hook Script: nyalakan SSH otomatis saat CT start ──
  hook_script_file_id = proxmox_virtual_environment_file.alpine_ssh_hook.id

  # ── Cloudflare Tunnel Auto-Install (Distributed Replica) ──
  provisioner "remote-exec" {
    inline = [
      "apk update && apk add curl openrc libc6-compat",
      "curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
      "chmod +x /usr/local/bin/cloudflared",
      "cloudflared service install ${var.cf_tunnel_token}",
      "rc-update add cloudflared default",
      "rc-service cloudflared start"
    ]
  }

  connection {
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
    host        = "10.10.10.111"
    timeout     = "2m"
  }
}

# ==========================================
# 🌐 LXC 2 — CT web2 (Node: node2)
# ==========================================
resource "proxmox_virtual_environment_container" "web2" {
  node_name    = "node2"
  vm_id        = 112
  unprivileged = true
  started      = true

  description = "CT web2 - Active-Active Edge Node (node2)"

  initialization {
    hostname = "web2"

    ip_config {
      ipv4 {
        address = "10.10.10.112/24"
        gateway = "10.10.10.1"
      }
    }

    user_account {
      keys = [var.ssh_public_key]
    }
  }

  cpu {
    cores = var.ct_cpu_cores
  }

  memory {
    dedicated = var.ct_memory
  }

  disk {
    datastore_id = "local-lvm"
    size         = var.ct_disk_size
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  operating_system {
    template_file_id = var.ct_os_template
    type             = "alpine"
  }

  features {
    nesting = true
  }

  # ── Hook Script: nyalakan SSH otomatis saat CT start ──
  hook_script_file_id = proxmox_virtual_environment_file.alpine_ssh_hook.id

  # ── Cloudflare Tunnel Auto-Install (Distributed Replica) ──
  provisioner "remote-exec" {
    inline = [
      "apk update && apk add curl openrc libc6-compat",
      "curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
      "chmod +x /usr/local/bin/cloudflared",
      "cloudflared service install ${var.cf_tunnel_token}",
      "rc-update add cloudflared default",
      "rc-service cloudflared start"
    ]
  }

  connection {
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
    host        = "10.10.10.112"
    timeout     = "2m"
  }
}
