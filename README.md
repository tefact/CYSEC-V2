# 🚀 Panduan Deployment Otomatis — Static Website ke Proxmox LXC (GitOps Pipeline)

Repo ini adalah pipeline CI/CD lengkap yang menggabungkan **Terraform** (Infrastructure as Code) dan **GitHub Actions** (rsync deployment) untuk men-deploy website statis ke dua LXC container Active-Active di Proxmox — tanpa intervensi manual setelah setup awal selesai.

---

## 🏗️ Arsitektur

```
                     ┌──────────────────────┐
                     │   Cloudflare Edge    │
                     │  (Auto Load Balance  │
                     │   & Failover)        │
                     └──────────┬───────────┘
                                │
         ┌──────────────────────┴──────────────────────┐
         │ (Tunnel Conn 1)                             │ (Tunnel Conn 2)
         ▼                                             ▼
┌──────────────────┐                          ┌──────────────────┐
│     CT web1      │                          │     CT web2      │
│   10.10.10.111   │                          │   10.10.10.112   │
│   (node1)        │                          │   (node2)        │
│  [cloudflared]   │                          │  [cloudflared]   │
│  [nginx → :80]   │                          │  [nginx → :80]   │
└──────────────────┘                          └──────────────────┘
         ▲                                             ▲
         │              ┌──────────────┐               │
         └──────────────│ Self-Hosted  │───────────────┘
                        │   Runner     │
                        │ 10.10.10.100 │
                        └──────┬───────┘
                               │
                        ┌──────┴───────┐
                        │    GitHub    │
                        │  Repository  │
                        └──────────────┘
```

**Alur kerja setelah setup selesai:**
1. `git push` ke branch `main`
2. GitHub Actions trigger self-hosted runner
3. **Job 1 (Terraform):** Buat CT + inject `cloudflared` dengan token tunnel (auto-HA!)
4. **Job 2 (Rsync):** Deploy file website ke kedua CT secara paralel
5. Cloudflare Edge deteksi 2 tunnel connections → auto load balance + failover!

---

## 📋 Prasyarat (Prerequisites)

Minimal yang harus sudah ada sebelum memulai:

- ✅ **Proxmox VE** terinstall dengan minimal 1 node (idealnya 2: `node1` & `node2`)
- ✅ **Akun GitHub** dengan repository yang berisi kode website
- ✅ **Koneksi internet** di node Proxmox (untuk download template & GitHub runner)
- ✅ **Proxmox API Token** sudah dibuat (dijelaskan di Step 3)

> 💡 **Catatan:** CT web target (web1 & web2) TIDAK perlu dibuat manual — Terraform akan membuatnya otomatis di Step 4!

---

## 🏃 Step 1: Siapkan Mesin Runner (Jembatan Utama)

> ⚠️ **TANPA RUNNER, SELURUH PIPELINE INI TIDAK AKAN JALAN.**
>
> Self-hosted runner adalah "jembatan" antara GitHub Cloud dan jaringan lokal Proxmox. GitHub tidak bisa langsung menembak IP private 10.10.10.x — runner lah yang menerima instruksi dari GitHub lalu mengeksekusinya di jaringan lokal.

### 1.0 — Pilih Lokasi Runner

| Opsi | Deskripsi | Verdict |
|------|-----------|---------|
| **🅰️ CT Dedicated (REKOMENDASI)** | Buat LXC khusus `github-runner` | ✅ **Best Practice** — isolasi sempurna |
| 🅱️ Host Proxmox langsung | Install di node1/node2 | ❌ **DOSA BESAR** — hypervisor bukan tempat app! |
| 🅲️ Nebeng di CT web | Install di web1/web2 | ❌ **Anti-pattern** — rsync ke localhost? Aneh. |

#### 🅰️ Opsi A — CT Dedicated (WAJIB Pilih Ini!)

**Mengapa?** Konsep *Isolation of Blast Radius*:
- Jika runner dieksploitasi → yang hancur cuma CT runner. Web server & hypervisor aman.
- Resource terkunci — runner tidak merebut RAM/CPU web server.
- Clean separation sesuai standar industri.

> 💡 **Asas Kemalasan Hakiki:** Daripada buat CT Runner manual lewat GUI, kamu juga bisa definisikan mesin `github-runner` ini di file `main.tf` Terraform sekalian! Tapi untuk bootstrap awal, kita perlu minimal 1 runner manual dulu agar Terraform bisa dijalankan.

**Buat CT via Proxmox GUI:**

| Parameter | Value |
|-----------|-------|
| CT ID | 100 |
| Hostname | `github-runner` |
| Template | **Debian 13** atau **Ubuntu 24.04** |
| CPU | 1-2 cores |
| RAM | 1024 MB (cukup!) |
| Disk | 10 GB |
| Network | Bridge `vmbr0`, IP: `10.10.10.100/24`, GW: `10.10.10.1` |

> ⚠️ **JANGAN pakai Alpine Linux untuk runner!** GitHub Actions Runner butuh **glibc**. Alpine pakai **musl libc** yang tidak kompatibel — binary runner akan crash saat startup.

#### 🚫 Mengapa Opsi B = Dosa Besar?

Menginstall aplikasi pihak ketiga langsung di host Proxmox itu **TABU**:
- Jika runner dieksploitasi → penyerang dapat akses **root ke hypervisor fisik**
- Bisa menghapus SELURUH VM dan CT dalam satu detik
- Melanggar prinsip: *"Hypervisor hanya untuk hypervisor"*

#### 🚫 Mengapa Opsi C = Anti-Pattern?

- Runner di web1 melakukan rsync ke... dirinya sendiri (localhost)? Absurd.
- Proses runner makan resource web server — user bisa kena lag saat deploy
- Tidak mencerminkan arsitektur deployment skala besar di industri

### 1.1 — Persiapan Mesin Runner

Setelah CT `github-runner` dibuat dan jalan, SSH ke dalamnya:

```bash
ssh root@10.10.10.100
```

Install semua dependensi:

```bash
# Update system
apt update && apt upgrade -y

# Install dependensi yang dibutuhkan runner + workflow
apt install -y sudo curl tar git rsync openssh-client sudo
```

Buat user khusus (JANGAN jalankan runner sebagai root!):

```bash
# Buat user runner
useradd -m -s /bin/bash runner

# Tambahkan ke grup sudo
usermod -aG sudo runner

# Agar runner bisa jalankan sudo tanpa password di workflow otomatis
echo "runner ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

# Pindah ke user runner
su - runner
```

### 1.2 — Download & Install GitHub Actions Runner

**Ambil registration token dari GitHub:**
1. Ke repository → **Settings** → **Actions** → **Runners**
2. Klik **New self-hosted runner**
3. Pilih **Linux** → **x64**
4. Copy token yang muncul

**Install runner (jalankan sebagai user `runner`):**

```bash
# Buat direktori dan download
mkdir ~/actions-runner && cd ~/actions-runner
curl -o actions-runner-linux-x64-2.321.0.tar.gz -L \
  https://github.com/actions/runner/releases/download/v2.321.0/actions-runner-linux-x64-2.321.0.tar.gz
tar xzf ./actions-runner-linux-x64-2.321.0.tar.gz

# Konfigurasi — ganti URL dan TOKEN sesuai milikmu
./config.sh --url https://github.com/USERNAME/NAMA-REPO --token TOKEN_DARI_GITHUB
```

Saat ditanya interaktif:
```
Enter the name of the runner group: [tekan Enter untuk default]
Enter the name of runner: [tekan Enter atau ketik "proxmox-runner"]
Enter any additional labels: [tekan Enter]
Enter the name of work folder: [tekan Enter untuk default "_work"]
```

### 1.3 — Install Sebagai Service (Auto-Start)

```bash
# Kembali ke root untuk install service
exit  # kembali ke root

cd /home/runner/actions-runner
sudo ./svc.sh install runner
sudo ./svc.sh start
```

Verifikasi:
```bash
sudo ./svc.sh status
```

Cek di GitHub: **Settings → Actions → Runners** — runner harus berstatus **🟢 Idle**.

### 1.4 — Verifikasi Konektivitas Jaringan Runner

Sebelum lanjut, pastikan CT runner sudah bisa "melihat" jaringan lokal Proxmox (minimal bisa ping gateway atau host Proxmox):

```bash
# Test ping ke Gateway
ping -c 3 10.10.10.1

# Test ping ke IP Host Proxmox (node1)
ping -c 3 10.10.10.201
```

> 💡 **Catatan untuk Jalur Terraform (Opsi A):** Kamu **BELUM** bisa ping ke `10.10.10.111` atau `10.10.10.112` sekarang — kontainernya memang belum dibuat! Yang penting di tahap ini: pastikan runner sudah tersambung ke jaringan lokal dan bisa mengakses internet (untuk download GitHub runner package).
>
> Setelah Step 5 (git push) berhasil dan Terraform membuat kedua CT, barulah kamu bisa verifikasi koneksi penuh:
> ```bash
> ping -c 3 10.10.10.111   # web1
> ping -c 3 10.10.10.112   # web2
> ```

---

## 🔑 Step 2: Generate SSH Key Pair (di Mesin Runner)

SSH key ini dipakai untuk autentikasi tanpa password antara runner → kedua CT web. Algoritma **ed25519** lebih aman dan key-nya lebih pendek dari RSA.

### Jalankan sebagai user `runner` di CT github-runner:

```bash
su - runner
ssh-keygen -t ed25519 -C "github-deploy-key" -f ~/.ssh/id_ed25519
```

### Contoh output:

```
Generating public/private ed25519 key pair.
Enter passphrase (empty for no passphrase):   ← Tekan Enter (kosongkan!)
Enter same passphrase again:                   ← Tekan Enter lagi
Your identification has been saved in /home/runner/.ssh/id_ed25519
Your public key has been saved in /home/runner/.ssh/id_ed25519.pub
The key fingerprint is:
SHA256:AbCdEfGhIjKlMnOpQrStUvWxYz1234567890 github-deploy-key
```

### Hasil: 2 file tercipta

| File | Isinya | Kemana perginya? |
|------|--------|-----------------|
| `~/.ssh/id_ed25519` | **Private Key** 🔒 | → GitHub Secret `DEPLOY_KEY` |
| `~/.ssh/id_ed25519.pub` | **Public Key** 🔑 | → GitHub Secret `DEPLOY_PUBLIC_KEY` + ditanam di CT target |

### ⚠️ PERINGATAN — Private Key = Kunci Rumah!

- ❌ JANGAN commit ke repository
- ❌ JANGAN kirim lewat chat/email
- ❌ JANGAN paste di tempat publik
- ✅ HANYA simpan di GitHub Secrets (terenkripsi)

---

## 🔐 Step 3: Pasang Semua Secrets di GitHub (Satu Kali, Tuntas!)

> 💡 **Kita selesaikan SEMUA konfigurasi GitHub Secrets di sini, supaya tidak bolak-balik.**

### 3.1 — Buka halaman Secrets:

1. Ke repository di GitHub
2. **Settings** → **Secrets and variables** → **Actions**
3. Klik **New repository secret**

### 3.2 — Daftar SEMUA Secrets yang Dibutuhkan:

| # | Secret Name | Cara Mendapatkan Value-nya | Contoh Value |
|---|---|---|---|
| 1 | `DEPLOY_USER` | Username SSH ke CT target | `root` |
| 2 | `DEPLOY_KEY` | `cat ~/.ssh/id_ed25519` (dari Step 2) | `-----BEGIN OPENSSH PRIVATE KEY-----` ... `-----END OPENSSH PRIVATE KEY-----` |
| 3 | `DEPLOY_PUBLIC_KEY` | `cat ~/.ssh/id_ed25519.pub` (dari Step 2) | `ssh-ed25519 AAAAC3Nz... github-deploy-key` |
| 4 | `PVE_API_TOKEN` | Dari Proxmox Web UI (lihat di bawah) | `root@pam!terraform=a1b2c3d4-e5f6-...` |
| 5 | `CF_TUNNEL_TOKEN` | Cloudflare Zero Trust Dashboard → Tunnels → Create → copy token | `eyJhIjoiNjk2MT...` (token panjang) |

### 3.3 — Cara Buat Proxmox API Token (`PVE_API_TOKEN`):

1. Login ke **Proxmox Web UI** (https://10.10.10.201:8006)
2. **Datacenter** → **Permissions** → **API Tokens**
3. Klik **Add**
4. User: `root@pam`, Token ID: `terraform`
5. **UNCHECK** "Privilege Separation"
6. Klik **Add** → **COPY token yang muncul SEGERA** (hanya muncul sekali!)

```
Format yang muncul:
root@pam!terraform=a1b2c3d4-e5f6-7890-abcd-ef1234567890
└─────────────────┘ └──────────────────────────────────┘
   Token ID              Token Secret (HANYA MUNCUL SEKALI!)
```

> ⚠️ **PENTING:** Copy **SELURUH string lengkap** termasuk `root@pam!terraform=` di depannya!
> Yang dimasukkan ke Secret itu **BUKAN** cuma UUID-nya (`a1b2c3d4-...`), tapi **LENGKAP** dari awal sampai akhir!

### 3.4 — Cara Paste `DEPLOY_KEY` (Private Key):

```bash
# Di mesin runner:
cat ~/.ssh/id_ed25519
```

Output:
```
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
QyNTUxOQAAACBHp1mVRv7lBn3JmI6Q0fTqoQAAAED1Y2F1bS1yc2Etc2lnbmF0dXJl...
-----END OPENSSH PRIVATE KEY-----
```

> Copy **SELURUH isi** dari `-----BEGIN...` sampai `-----END...-----` (termasuk baris BEGIN dan END). Jangan sampai kepotong!

### 3.5 — Cara Paste `DEPLOY_PUBLIC_KEY`:

```bash
cat ~/.ssh/id_ed25519.pub
```

Output (satu baris):
```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbCdEfGhIjKlMnOpQrStUvWxYz github-deploy-key
```

> Copy **seluruh baris** itu. Terraform akan menanamnya otomatis ke CT baru saat provisioning — jadi CT langsung bisa di-SSH tanpa setup manual!

### ✅ Checklist Secrets (Pastikan 5/5 terisi!):

```
☐ DEPLOY_USER       → root
☐ DEPLOY_KEY        → (isi private key lengkap)
☐ DEPLOY_PUBLIC_KEY → (isi public key satu baris)
☐ PVE_API_TOKEN     → root@pam!terraform=xxxxx...
☐ CF_TUNNEL_TOKEN   → (token dari Cloudflare Dashboard)
```

---

## 🏗️ Step 4: Provisioning Infrastruktur (Pilih Jalan Ninjamu!)

Sebelum file website bisa di-deploy, kita butuh dua LXC Container (`web1` & `web2`) sebagai server target.

### 🅰️ Opsi A: Jalur Otomatis dengan Terraform (SANGAT DIREKOMENDASIKAN)

> **Kamu tidak perlu buka GUI Proxmox. Kamu tidak perlu SSH manual. Kamu tidak perlu `nano` apapun.**

Cukup pastikan file `terraform/variables.tf` sudah sesuai spesifikasi keinginanmu. Saat kamu melakukan `git push` di Step 5 nanti, GitHub Actions akan menyuruh Terraform untuk:

1. ✅ Membuat CT `web1` di node1 (IP: 10.10.10.111)
2. ✅ Membuat CT `web2` di node2 (IP: 10.10.10.112)
3. ✅ Menanam `DEPLOY_PUBLIC_KEY` secara otomatis ke kedua CT
4. ✅ Set CPU, RAM, disk sesuai `variables.tf`
5. ✅ Start kedua CT
6. ✅ **Install `cloudflared` + inject tunnel token → True HA otomatis!**

**Kamu langsung skip ke Step 5. Tidak ada kerja manual!** 🎉

#### 📁 Struktur Direktori Terraform:

```
terraform/
├── main.tf                      ← Provider + resource CT web1 & web2
├── variables.tf                 ← Spesifikasi (CPU, RAM, disk, IP, template)
├── outputs.tf                   ← Output IP & hostname setelah apply
├── download-template.tf.example ← (Opsional) Rename ke .tf jika mau auto-download template
└── .gitignore                   ← Exclude .terraform/, *.tfstate
```

#### ⚙️ Kustomisasi Spesifikasi CT:

Edit `terraform/variables.tf`:

```hcl
variable "ct_cpu_cores" {
  default = 1      # Ubah sesuai keinginan
}

variable "ct_memory" {
  default = 256   # Dalam MB
}

variable "ct_disk_size" {
  default = 2     # Dalam GB
}

variable "ct_os_template" {
  default = "local:vztmpl/alpine_3.23_amd64_default.tar.xz"
}
```

#### ♻️ Idempotensi — Aman Push Berkali-kali!

- Push pertama: Terraform buat CT dari nol
- Push kedua, ketiga, dst: Terraform cek → "udah sesuai" → **skip**
- CT hanya di-recreate jika kamu ubah konfigurasi di `main.tf`

---

### 🅱️ Opsi B: Jalur Manual (Jika Kamu Kurang Kerjaan)

> ⚠️ Pilih ini HANYA jika CT web sudah dibuat sebelumnya atau kamu tidak ingin pakai Terraform.

Jika memilih jalur manual, kamu harus:

**B.1 — Buat CT manual via GUI Proxmox:**
- Buat `web1` di node1: IP 10.10.10.111/24, GW 10.10.10.1
- Buat `web2` di node2: IP 10.10.10.112/24, GW 10.10.10.1
- Install nginx + rsync di kedua CT: `apk add nginx rsync openssh`

**B.2 — Tanam Public Key MANUAL ke kedua CT:**

SSH ke web1:
```bash
ssh root@10.10.10.111

# Buat folder .ssh
mkdir -p ~/.ssh && chmod 700 ~/.ssh

# Paste public key dari runner (isi cat ~/.ssh/id_ed25519.pub)
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... github-deploy-key" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

Ulangi untuk web2:
```bash
ssh root@10.10.10.112
mkdir -p ~/.ssh && chmod 700 ~/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5... github-deploy-key" >> ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

**B.3 — Test koneksi dari runner:**
```bash
# Di mesin runner:
ssh -i ~/.ssh/id_ed25519 root@10.10.10.111 "echo 'web1 OK!'"
ssh -i ~/.ssh/id_ed25519 root@10.10.10.112 "echo 'web2 OK!'"
```

Kalau langsung masuk tanpa password → berhasil! 🎉

---

## 🚀 Step 5: Push Kode & Deploy Otomatis!

Semua setup sudah selesai. Sekarang tinggal push!

### 5.1 — Push ke main:

```bash
git add .
git commit -m "🚀 first automated deploy"
git push origin main
```

### 5.2 — Apa yang terjadi di belakang layar:

```
Push ke main
    │
    ▼
┌─────────────────────────────┐
│  🏗️ Job 1: provision        │
│  Terraform Init + Apply     │  ← Buat/pastikan CT ada (idempoten)
│  working-dir: terraform/    │
└──────────────┬──────────────┘
               │ (lanjut jika sukses)
               ▼
┌─────────────────────────────┐
│  🚀 Job 2: deploy           │
│  rsync paralel ke:          │
│  • 10.10.10.111 (web1)      │  ← Deploy file website
│  • 10.10.10.112 (web2)      │
│  --exclude '.git*/.github*' │
└─────────────────────────────┘
```

### 5.3 — Monitor di GitHub:

1. Ke tab **Actions** di repository
2. Klik workflow run yang muncul
3. Log sukses kira-kira gini:

```
=========================================
🔄 Mulai deploy paralel ke kedua CT...
   → CT web1: 10.10.10.111
   → CT web2: 10.10.10.112
=========================================
⏳ Menunggu rsync selesai...
✅ Sukses deploy ke CT web1
✅ Sukses deploy ke CT web2
🎉 Kedua deploy sukses!
```

### 5.4 — Verifikasi:

Buka browser → akses website. Refresh beberapa kali untuk memastikan kedua CT serve konten yang sama (Cloudflare auto load balance melalui tunnel).

---

## ☁️ Cloudflare Tunnel: Setup di Dashboard

Setelah pipeline berhasil jalan dan kedua CT memiliki `cloudflared` yang aktif, konfigurasi di sisi Cloudflare:

### Di Cloudflare Zero Trust Dashboard:

1. Ke **Networks** → **Tunnels**
2. Kamu akan melihat tunnel kamu dengan status **2 Connections** (healthy) ✅
3. Klik tunnel → **Public Hostname** → **Add**
4. Konfigurasi:
   - **Subdomain:** `www` (atau sesuai domain kamu)
   - **Domain:** `domainmu.com`
   - **Type:** `HTTP`
   - **URL:** `localhost:80`

> 💡 Karena `cloudflared` jalan **di dalam** masing-masing CT, `localhost:80` merujuk ke Nginx internal CT itu sendiri. Tidak perlu IP private!

### Hasil di Dashboard:

```
Tunnel: "web-ha"
Status: ✅ Healthy
Connections: 2 (10.10.10.111, 10.10.10.112)
```

Jika salah satu CT mati → Cloudflare otomatis failover ke CT yang masih hidup dalam hitungan milidetik. **Zero local SPOF!**

---

## 🔧 Troubleshooting

### ❌ `Job is waiting to be picked up by a runner...`

**Penyebab:** Runner mati atau service berhenti.

**Solusi:**
```bash
# SSH ke CT runner
ssh root@10.10.10.100

# Cek status
sudo systemctl status actions.runner.*

# Restart jika mati
cd /home/runner/actions-runner
sudo ./svc.sh stop
sudo ./svc.sh start
```

Cek di GitHub **Settings → Actions → Runners** — harus **🟢 Idle**, bukan 🔴 Offline.

### ❌ `Permission denied (publickey)`

**Penyebab:** Key belum ditanam di CT target, atau username salah.

**Solusi:**
```bash
# Cek authorized_keys di CT target
ssh root@10.10.10.111 "cat ~/.ssh/authorized_keys"

# Fix permission
ssh root@10.10.10.111 "chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys"

# Pastikan DEPLOY_USER di Secrets match (harus "root")
```

### ❌ `Host key verification failed`

**Penyebab:** Fingerprint host belum di-known_hosts.

**Solusi:** Workflow sudah pakai `-o StrictHostKeyChecking=no`, jadi jarang terjadi. Kalau masih:
```bash
ssh-keyscan -H 10.10.10.111 >> ~/.ssh/known_hosts
ssh-keyscan -H 10.10.10.112 >> ~/.ssh/known_hosts
```

### ❌ `rsync: command not found`

**Penyebab:** rsync belum terinstall di CT target.

**Solusi:**
```bash
# Untuk Alpine Linux:
ssh root@10.10.10.111 "apk add rsync"
ssh root@10.10.10.112 "apk add rsync"

# Untuk Debian/Ubuntu:
ssh root@10.10.10.111 "apt install -y rsync"
ssh root@10.10.10.112 "apt install -y rsync"
```

### ❌ Terraform error: `401 Unauthorized`

**Penyebab:** `PVE_API_TOKEN` salah format atau expired.

**Solusi:** Pastikan value di Secret adalah **LENGKAP**: `root@pam!terraform=uuid-value-here` (termasuk bagian depannya!). Bukan cuma UUID.

### ❌ Cloudflare Tunnel `0 Connections`

**Penyebab:** `cloudflared` service mati di kedua CT.

**Solusi:**
```bash
# Cek status di masing-masing CT
ssh root@10.10.10.111 "rc-service cloudflared status"
ssh root@10.10.10.112 "rc-service cloudflared status"

# Restart jika mati
ssh root@10.10.10.111 "rc-service cloudflared restart"
ssh root@10.10.10.112 "rc-service cloudflared restart"
```

> Jika masih gagal, cek apakah `libc6-compat` terinstall: `apk add libc6-compat`

---

## 📁 Struktur File Workflow

```
.github/workflows/deploy.yml
│
├── Trigger: push ke branch main
├── Concurrency: cancel deploy lama kalau ada push baru
│
├── 🏗️ Job 1: provision (Terraform)
│   ├── 📥 Checkout repository
│   ├── 🏗️ Setup Terraform (hashicorp/setup-terraform@v3)
│   ├── 📦 Terraform Init (working-dir: terraform/)
│   └── 🚀 Terraform Apply -auto-approve
│       └── Env: TF_VAR_proxmox_api_token, TF_VAR_ssh_public_key
│
└── 🚀 Job 2: deploy (needs: provision)
    ├── 📥 Checkout repository
    ├── 🔑 Setup SSH key (DEPLOY_KEY → /tmp/deploy_ssh_key)
    ├── 🚀 Rsync paralel ke web1 & web2
    │   ├── --exclude '.git*' dan '.github*'
    │   ├── rsync -avz --delete ke 10.10.10.111 (background)
    │   ├── rsync -avz --delete ke 10.10.10.112 (background)
    │   └── wait + validasi exit code
    ├── 🔒 Fix permissions (www-data, 755/644)
    └── 🧹 Cleanup SSH key (always run)
```

---

## 🛡️ Catatan Keamanan

- 🔒 **JANGAN pernah commit private key ke repo.** Git history permanen — walau dihapus, tetap ada.
- 🔑 **GitHub Secrets terenkripsi** — tidak bisa dibaca setelah disimpan, bahkan oleh admin.
- 🏠 **Runner di LAN** — tidak perlu expose SSH ke internet. Semua traffic internal.
- 🧱 **Isolasi blast radius** — runner di CT dedicated, jika diexploit tidak menyebar ke web server atau hypervisor.
- 👤 **Pertimbangkan user deploy khusus** (bukan root) dengan akses terbatas ke `/var/www/html/` saja.
- 🔄 **Rotasi key berkala** — generate ulang + update Secrets jika ada indikasi kebocoran.

---

## 📝 Lisensi

Repo ini milik pribadi. Deploy dengan hati-hati. Kalau ada pertanyaan, buka issue! 😄
