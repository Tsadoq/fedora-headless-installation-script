# Fedora Server USB Builder

[![Made with Bash](https://img.shields.io/badge/Made%20with-Bash-4EAA25?logo=gnu-bash\&logoColor=white)](https://www.gnu.org/software/bash/)
[![Linux only](https://img.shields.io/badge/Platform-Linux-blue?logo=linux\&logoColor=white)](#-requirements)
[![Headless Ready](https://img.shields.io/badge/Headless-Ready-success)](#-what-you-get)
[![Secure Boot OK](https://img.shields.io/badge/Secure%20Boot-OK-brightgreen)](#-faq)
[![PRs Welcome](https://img.shields.io/badge/PRs-welcome-purple)](../../pulls)
[![Fedora Server](https://img.shields.io/badge/Target-Fedora%20Server-orange?logo=fedora\&logoColor=white)](https://getfedora.org/)

Single USB. Headless install. Safe disk targeting.
Key-only SSH login, sudo with a password you set.

> This repo contains a Bash script that creates a bootable Fedora Server installer on a single USB stick and adds an OEMDRV partition on the same stick with an auto-generated Kickstart. Install Fedora Server on a headless box without a screen or keyboard.

---

## 🔗 Table of contents

* [What you get](#-what-you-get)
* [Read this first](#️-read-this-first)
* [Requirements](#-requirements)
* [Quick start](#-quick-start)
* [How it works](#-how-it-works)
* [Security model](#-security-model)
* [Network options](#-network-options)
* [Target disk modes](#-target-disk-modes)
* [Verify the USB](#-verify-the-usb)
* [Install on the server](#-install-on-the-server)
* [Troubleshooting](#-troubleshooting)
* [FAQ](#-faq)
* [License](#-license)

---

## ✨ What you get

* Latest Fedora Server ISO, downloaded and SHA256-verified
* One USB with two areas

  ```
  [USB]
   ├─ Fedora Server installer (ISO image area)
   └─ OEMDRV (FAT32) → /ks.cfg
  ```
* Kickstart that:

  * runs text mode install
  * configures network via DHCP or static IPv4
  * creates an admin user in wheel
  * enforces SSH key-only login
  * requires a password for sudo
  * locks root login
  * optionally disables audio and USB video drivers
  * installs minimal packages: minimal environment, sudo, openssh-server, chrony
* Safe target disk modes:

  1. Auto single internal disk: proceed only if exactly one internal non-USB disk is present
  2. All internal disks: wipe every internal non-USB disk
  3. Manual: you name one device, for example `nvme0n1` or `sda`

---

## ⚠️ Read this first

* The script erases the selected USB device
* The generated Kickstart erases server disks per the mode you choose
* Use on Linux with root privileges
* Works under Bash only; the script re-execs itself under Bash if started from zsh or others

---

## ✅ Requirements

Linux machine with:

* `bash`, `dd`, `lsblk`, `blockdev`, `partprobe`, `udevadm`
* `curl`, `sha256sum`, `openssl`
* `sgdisk` or `parted`
* `mkfs.vfat` or `mkfs.fat`

Install hints

```bash
# Fedora / RHEL
sudo dnf install -y curl coreutils util-linux dosfstools gdisk parted openssl

# Ubuntu / Debian
sudo apt update
sudo apt install -y curl coreutils util-linux dosfstools gdisk parted openssl
```

---

## 🚀 Quick start

```bash
git clone git@github.com:Tsadoq/fedora-headless-installation-script.git
cd fedora-headless-installation-script
chmod +x make-fedora-server-usb.sh
sudo bash ./make-fedora-server-usb.sh
```

or directly:

```bash
curl -fsSL https://raw.githubusercontent.com/Tsadoq/fedora-headless-installation-script/main/make-fedora-server-usb.sh | sudo bash
```

You will be prompted to:

* pick the USB device to wipe
* choose target disk mode for the server
* set hostname
* pick DHCP or enter static IPv4 details
* choose the admin username
* select the path to your SSH public key file, for example `~/.ssh/id_ed25519.pub`
* set a local password for that user for sudo
* choose final action: poweroff or reboot
* optionally disable audio and USB video modules on the server

The script prints a `ks.cfg` preview, unmounts OEMDRV, and you are done.

---

## 🧠 How it works

* Writes the Fedora Server ISO raw to the USB
* Creates a second FAT32 partition labeled `OEMDRV` on the same stick
* Puts `ks.cfg` at the root of OEMDRV
* Anaconda auto-loads `/ks.cfg` from any device labeled `OEMDRV`
* `%pre` script chooses server disks per your selected mode and emits

  ```
  ignoredisk --only-use=<list>
  clearpart --all --initlabel
  autopart --type=btrfs
  ```
* Main Kickstart installs a minimal system, creates your admin, sets up SSH and sudo, and optionally blacklists A/V modules

---

## 🔐 Security model

* SSH logins: key only
  `PasswordAuthentication no`, `PubkeyAuthentication yes`
* Root SSH: disabled
  `PermitRootLogin no`
* Sudo: required, uses the password you set during USB creation
  User is in `wheel`
* Root account: locked
  `rootpw --lock`

Result: you log in with your SSH key, then use `sudo` with your password.

---

## 🖧 Network options

* DHCP: simplest for first boot and discovery
* Static IPv4: the script writes IP, netmask, gateway, DNS in Kickstart

Tip: if you use DHCP, create a reservation in your router for stable addressing.

---

## 🧩 Target disk modes

* Auto single internal disk
  Installs only if exactly one internal non-USB disk exists. Otherwise aborts to avoid nuking the wrong box.

* All internal disks
  Restricts the installer to all internal non-USB disks and wipes them.

* Manual device name
  Restricts the installer to the device you name, for example `nvme0n1`.

Internals: candidates are derived from sysfs and udev, excluding removable and USB bus disks, then fed to `ignoredisk --only-use`.

---

## 🔍 Verify the USB

After the script finishes:

```bash
# See partitions and labels
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT /dev/sdX

# Inspect ks.cfg
sudo mount /dev/sdX2 /mnt
sed -n '1,120p' /mnt/ks.cfg
sudo umount /mnt
```

You should see a FAT32 partition labeled `OEMDRV` containing `/ks.cfg`.

---

## 🖥️ Install on the server

1. Plug the USB stick
2. Power on and boot from USB
3. The installer runs unattended and then performs your chosen final action

   * If `poweroff`: remove the USB when it shuts down, then power on
   * If `reboot`: remove the USB as soon as the system reboots into the installed OS

SSH in

```bash
ssh <user>@<server-ip>
sudo -v
```

---

## 🛠️ Troubleshooting

* OEMDRV not detected
  Confirm the partition label is exactly `OEMDRV` and `ks.cfg` is at OEMDRV’s root

* Boots the wrong device
  Fix firmware boot order so USB is first. After install, remove the stick

* No network after install
  If static, recheck IP, netmask, gateway, DNS. If DHCP, confirm a lease was handed out

* Sudo fails
  Use the password you set during USB creation

* Missing tools
  Install the dependencies listed in Requirements

---

## ❓ FAQ

**Can I run this from macOS or Windows**
No. Use a Linux machine with raw block device access.

**Does it support Secure Boot**
Yes. Fedora Server supports Secure Boot. Leave it enabled.

**Bash or zsh**
Bash only. The script includes a self-reexec snippet to force Bash even if launched from zsh.

**Encryption**
Not included. Headless LUKS requires extra components such as Tang or TPM2 network unlock. Add only if you understand the trade-offs.

**Netinst vs DVD ISO**
The script prefers the DVD image when available and falls back to netinst.

## 🙌 Contributing

Issues and PRs are welcome. If you add new options, keep safety first, preserve headless defaults, and document behavior clearly.
