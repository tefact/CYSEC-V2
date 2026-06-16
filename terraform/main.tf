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

  # ── Host-Based Provisioning: SSH ke Proxmox host → pct exec ke dalam CT ──
  # Bypass 403 hookscript & "no route to host" — bulletproof edition!
  provisioner "remote-exec" {
    inline = [
      # 1. Tunggu CT benar-benar running
      "until pct status 111 | grep -q 'running'; do sleep 2; done",

      # 2. Tunggu jaringan siap (ping Cloudflare DNS)
      "echo '⏳ Menunggu koneksi internet di dalam CT...'",
      "until pct exec 111 -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; do sleep 2; done",
      "echo '✅ Internet ready! Mulai instalasi...'",

      # 3. Install semua paket sekaligus (openssh DULUAN supaya sshd_config ada)
      "pct exec 111 -- apk update",
      "pct exec 111 -- apk add --no-cache openssh curl libc6-compat rsync",

      # 4. Konfigurasi SSH (file sekarang dijamin ada)
      "pct exec 111 -- sh -c 'sed -i \"s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/\" /etc/ssh/sshd_config'",
      "pct exec 111 -- sh -c 'sed -i \"s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/\" /etc/ssh/sshd_config'",
      "pct exec 111 -- rc-update add sshd default",
      "pct exec 111 -- rc-service sshd start",
      "sleep 3",

      # 5. Install Cloudflare Tunnel (Distributed Replica)
      "pct exec 111 -- curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
      "pct exec 111 -- chmod +x /usr/local/bin/cloudflared",
      "pct exec 111 -- cloudflared service install ${var.cf_tunnel_token}",
      "pct exec 111 -- sh -c 'rc-update add cloudflared default && rc-service cloudflared start'"
    ]
  }

  # SSH ke Proxmox host, BUKAN ke CT langsung
  connection {
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
    host        = var.proxmox_node1_host
    timeout     = "5m"
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

  # ── Host-Based Provisioning: SSH ke Proxmox host → pct exec ke dalam CT ──
  provisioner "remote-exec" {
    inline = [
      # 1. Tunggu CT benar-benar running
      "until pct status 112 | grep -q 'running'; do sleep 2; done",

      # 2. Tunggu jaringan siap (ping Cloudflare DNS)
      "echo '⏳ Menunggu koneksi internet di dalam CT...'",
      "until pct exec 112 -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; do sleep 2; done",
      "echo '✅ Internet ready! Mulai instalasi...'",

      # 3. Install semua paket sekaligus (openssh DULUAN supaya sshd_config ada)
      "pct exec 112 -- apk update",
      "pct exec 112 -- apk add --no-cache openssh curl libc6-compat rsync",

      # 4. Konfigurasi SSH (file sekarang dijamin ada)
      "pct exec 112 -- sh -c 'sed -i \"s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/\" /etc/ssh/sshd_config'",
      "pct exec 112 -- sh -c 'sed -i \"s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/\" /etc/ssh/sshd_config'",
      "pct exec 112 -- rc-update add sshd default",
      "pct exec 112 -- rc-service sshd start",
      "sleep 3",

      # 5. Install Cloudflare Tunnel (Distributed Replica)
      "pct exec 112 -- curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
      "pct exec 112 -- chmod +x /usr/local/bin/cloudflared",
      "pct exec 112 -- cloudflared service install ${var.cf_tunnel_token}",
      "pct exec 112 -- sh -c 'rc-update add cloudflared default && rc-service cloudflared start'"
    ]
  }

  # SSH ke Proxmox host node2, BUKAN ke CT langsung
  connection {
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
    host        = var.proxmox_node2_host
    timeout     = "5m"
  }
}
