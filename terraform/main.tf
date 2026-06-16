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

      # 2. Tunggu jaringan siap (bounded: maks 10 x 3s = 30s, lalu fail fast)
      "echo '⏳ Memeriksa koneksi internet di dalam CT...'",
      "CONNECTED=0; for i in $(seq 1 10); do if lxc-attach -n 111 -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then CONNECTED=1; break; fi; sleep 2; done",
      "[ $CONNECTED -eq 1 ] || { echo '❌ CT tidak punya akses internet!'; exit 99; }",

      # 3. FIX: Inisialisasi OpenRC supaya rc-service/rc-update tidak crash 'softlevel not set'
      "lxc-attach -n 111 -- sh -c 'mkdir -p /run/openrc && touch /run/openrc/softlevel'",

      # 4. Install paket dasar (openssh DULUAN supaya sshd_config ada)
      "lxc-attach -n 111 -- apk update || true",
      "lxc-attach -n 111 -- apk add --no-cache openssh curl libc6-compat rsync openrc",

      # 5. Konfigurasi & start SSH
      "lxc-attach -n 111 -- sh -c 'sed -i \"s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/\" /etc/ssh/sshd_config'",
      "lxc-attach -n 111 -- sh -c 'sed -i \"s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/\" /etc/ssh/sshd_config'",
      "lxc-attach -n 111 -- rc-update add sshd default || true",
      "lxc-attach -n 111 -- rc-service sshd restart || true",

      # 6. Download cloudflared binary
      "lxc-attach -n 111 -- curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
      "lxc-attach -n 111 -- chmod +x /usr/local/bin/cloudflared",

      # 7. Buat OpenRC init script di HOST dulu (hindari escaping issues di lxc-attach)
      "echo '#!/sbin/openrc-run' > /tmp/cf_init_111",
      "echo 'name=\"cloudflared\"' >> /tmp/cf_init_111",
      "echo 'description=\"Cloudflare Tunnel\"' >> /tmp/cf_init_111",
      "echo 'command=\"/usr/local/bin/cloudflared\"' >> /tmp/cf_init_111",
      "echo 'command_args=\"tunnel --no-autoupdate run --token ${var.cf_tunnel_token}\"' >> /tmp/cf_init_111",
      "echo 'command_background=\"true\"' >> /tmp/cf_init_111",
      "echo 'pidfile=\"/run/cloudflared.pid\"' >> /tmp/cf_init_111",
      "echo 'depend() {' >> /tmp/cf_init_111",
      "echo '    need net' >> /tmp/cf_init_111",
      "echo '}' >> /tmp/cf_init_111",

      # 8. Push init script dari host ke dalam CT via pct push
      "pct push 111 /tmp/cf_init_111 /etc/init.d/cloudflared",
      "rm -f /tmp/cf_init_111",

      # 9. Start cloudflared service
      "lxc-attach -n 111 -- chmod +x /etc/init.d/cloudflared",
      "lxc-attach -n 111 -- rc-update add cloudflared default || true",
      "lxc-attach -n 111 -- rc-service cloudflared restart || true"
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

      # 2. Tunggu jaringan siap (bounded: maks 10 x 3s = 30s, lalu fail fast)
      "echo '⏳ Memeriksa koneksi internet di dalam CT...'",
      "CONNECTED=0; for i in $(seq 1 10); do if lxc-attach -n 112 -- ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then CONNECTED=1; break; fi; sleep 2; done",
      "[ $CONNECTED -eq 1 ] || { echo '❌ CT tidak punya akses internet!'; exit 99; }",

      # 3. FIX: Inisialisasi OpenRC supaya rc-service/rc-update tidak crash 'softlevel not set'
      "lxc-attach -n 112 -- sh -c 'mkdir -p /run/openrc && touch /run/openrc/softlevel'",

      # 4. Install paket dasar (openssh DULUAN supaya sshd_config ada)
      "lxc-attach -n 112 -- apk update || true",
      "lxc-attach -n 112 -- apk add --no-cache openssh curl libc6-compat rsync openrc",

      # 5. Konfigurasi & start SSH
      "lxc-attach -n 112 -- sh -c 'sed -i \"s/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/\" /etc/ssh/sshd_config'",
      "lxc-attach -n 112 -- sh -c 'sed -i \"s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/\" /etc/ssh/sshd_config'",
      "lxc-attach -n 112 -- rc-update add sshd default || true",
      "lxc-attach -n 112 -- rc-service sshd restart || true",

      # 6. Download cloudflared binary
      "lxc-attach -n 112 -- curl -L --output /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64",
      "lxc-attach -n 112 -- chmod +x /usr/local/bin/cloudflared",

      # 7. Buat OpenRC init script di HOST dulu (hindari escaping issues di lxc-attach)
      "echo '#!/sbin/openrc-run' > /tmp/cf_init_112",
      "echo 'name=\"cloudflared\"' >> /tmp/cf_init_112",
      "echo 'description=\"Cloudflare Tunnel\"' >> /tmp/cf_init_112",
      "echo 'command=\"/usr/local/bin/cloudflared\"' >> /tmp/cf_init_112",
      "echo 'command_args=\"tunnel --no-autoupdate run --token ${var.cf_tunnel_token}\"' >> /tmp/cf_init_112",
      "echo 'command_background=\"true\"' >> /tmp/cf_init_112",
      "echo 'pidfile=\"/run/cloudflared.pid\"' >> /tmp/cf_init_112",
      "echo 'depend() {' >> /tmp/cf_init_112",
      "echo '    need net' >> /tmp/cf_init_112",
      "echo '}' >> /tmp/cf_init_112",

      # 8. Push init script dari host ke dalam CT via pct push
      "pct push 112 /tmp/cf_init_112 /etc/init.d/cloudflared",
      "rm -f /tmp/cf_init_112",

      # 9. Start cloudflared service
      "lxc-attach -n 112 -- chmod +x /etc/init.d/cloudflared",
      "lxc-attach -n 112 -- rc-update add cloudflared default || true",
      "lxc-attach -n 112 -- rc-service cloudflared restart || true"
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
