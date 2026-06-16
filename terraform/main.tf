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

  # ── Host-Based Provisioning: SSH ke Proxmox host → lxc-attach ke dalam CT ──
  # lxc-attach bypass bug Perl pct exec yang hang 100% CPU di Alpine unprivileged.
  provisioner "remote-exec" {
    inline = [
      # 1. Tunggu CT benar-benar running
      "until pct status 111 | grep -q 'running'; do sleep 2; done",

      # 2. Tunggu jaringan siap (bounded: maks 15 x 3s = 45s, lalu fail fast)
      "echo '⏳ Menunggu koneksi internet di dalam CT (maks 45s)...'",
      "CONNECTED=0; for i in $(seq 1 15); do if lxc-attach -n 111 -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then CONNECTED=1; break; fi; echo \"  attempt $$i/15...\"; sleep 3; done",
      "[ $CONNECTED -eq 1 ] && echo '✅ Internet ready!' || { echo '❌ CT tidak punya akses internet!'; exit 1; }",

      # 3. Install semua paket (openssh DULUAN supaya sshd_config ada)
      "lxc-attach -n 111 -- apk update",
      "lxc-attach -n 111 -- apk add --no-cache openssh curl libc6-compat rsync openrc",

      # 4. Konfigurasi & start SSH (file dijamin ada setelah apk add openssh)
      "lxc-attach -n 111 -- sh -c 'sed -i \"s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/\" /etc/ssh/sshd_config'",
      "lxc-attach -n 111 -- sh -c 'sed -i \"s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/\" /etc/ssh/sshd_config'",
      "lxc-attach -n 111 -- rc-update add sshd default",
      "lxc-attach -n 111 -- rc-service sshd start",
      "sleep 3",

      # 5. Download & install Cloudflare Tunnel
      "lxc-attach -n 111 -- curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
      "lxc-attach -n 111 -- chmod +x /usr/local/bin/cloudflared",

      # 6. Buat OpenRC init script untuk cloudflared (Alpine tidak pakai systemd)
      "lxc-attach -n 111 -- sh -c 'cat > /etc/init.d/cloudflared << INITEOF\n#!/sbin/openrc-run\nname=\"cloudflared\"\ndescription=\"Cloudflare Tunnel\"\ncommand=\"/usr/local/bin/cloudflared\"\ncommand_args=\"tunnel --no-autoupdate run --token ${var.cf_tunnel_token}\"\ncommand_background=\"true\"\npidfile=\"/run/cloudflared.pid\"\ndepend() { need net; }\nINITEOF'",
      "lxc-attach -n 111 -- chmod +x /etc/init.d/cloudflared",
      "lxc-attach -n 111 -- rc-update add cloudflared default",
      "lxc-attach -n 111 -- rc-service cloudflared start"
    ]
  }

  # SSH ke Proxmox host, BUKAN ke CT langsung
  connection {
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
    host        = var.proxmox_node1_host
    timeout     = "10m"
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

  # ── Host-Based Provisioning: SSH ke Proxmox host → lxc-attach ke dalam CT ──
  provisioner "remote-exec" {
    inline = [
      # 1. Tunggu CT benar-benar running
      "until pct status 112 | grep -q 'running'; do sleep 2; done",

      # 2. Tunggu jaringan siap (bounded: maks 15 x 3s = 45s, lalu fail fast)
      "echo '⏳ Menunggu koneksi internet di dalam CT (maks 45s)...'",
      "CONNECTED=0; for i in $(seq 1 15); do if lxc-attach -n 112 -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then CONNECTED=1; break; fi; echo \"  attempt $$i/15...\"; sleep 3; done",
      "[ $CONNECTED -eq 1 ] && echo '✅ Internet ready!' || { echo '❌ CT tidak punya akses internet!'; exit 1; }",

      # 3. Install semua paket (openssh DULUAN supaya sshd_config ada)
      "lxc-attach -n 112 -- apk update",
      "lxc-attach -n 112 -- apk add --no-cache openssh curl libc6-compat rsync openrc",

      # 4. Konfigurasi & start SSH (file dijamin ada setelah apk add openssh)
      "lxc-attach -n 112 -- sh -c 'sed -i \"s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/\" /etc/ssh/sshd_config'",
      "lxc-attach -n 112 -- sh -c 'sed -i \"s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/\" /etc/ssh/sshd_config'",
      "lxc-attach -n 112 -- rc-update add sshd default",
      "lxc-attach -n 112 -- rc-service sshd start",
      "sleep 3",

      # 5. Download & install Cloudflare Tunnel
      "lxc-attach -n 112 -- curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
      "lxc-attach -n 112 -- chmod +x /usr/local/bin/cloudflared",

      # 6. Buat OpenRC init script untuk cloudflared (Alpine tidak pakai systemd)
      "lxc-attach -n 112 -- sh -c 'cat > /etc/init.d/cloudflared << INITEOF\n#!/sbin/openrc-run\nname=\"cloudflared\"\ndescription=\"Cloudflare Tunnel\"\ncommand=\"/usr/local/bin/cloudflared\"\ncommand_args=\"tunnel --no-autoupdate run --token ${var.cf_tunnel_token}\"\ncommand_background=\"true\"\npidfile=\"/run/cloudflared.pid\"\ndepend() { need net; }\nINITEOF'",
      "lxc-attach -n 112 -- chmod +x /etc/init.d/cloudflared",
      "lxc-attach -n 112 -- rc-update add cloudflared default",
      "lxc-attach -n 112 -- rc-service cloudflared start"
    ]
  }

  # SSH ke Proxmox host node2, BUKAN ke CT langsung
  connection {
    type        = "ssh"
    user        = "root"
    private_key = var.ssh_private_key
    host        = var.proxmox_node2_host
    timeout     = "10m"
  }
}
