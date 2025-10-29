#!/usr/bin/env bash
# Fedora Server single-USB headless installer builder
# - Downloads latest Fedora Server ISO
# - Lets you pick the USB device
# - Writes the ISO and creates an OEMDRV partition on the same stick
# - Generates a Kickstart with safe disk selection modes
# - SSH login via key only; sudo requires the password you set here

# ensure bash
if [ -z "${BASH_VERSION:-}" ]; then
  exec bash "$0" "$@"
fi


set -euo pipefail

# ---------- UI helpers ----------
if test -t 1; then
  RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BLUE=$'\033[34m'; MAG=$'\033[35m'; CYAN=$'\033[36m'; BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAG=""; CYAN=""; BOLD=""; DIM=""; RESET=""
fi

banner() {
  printf "\n${MAG}${BOLD}================  Fedora Server USB Builder  ================${RESET}\n"
  printf "${CYAN}${BOLD}Headless Kickstart • Single USB • Safe disk targeting${RESET}\n\n"
}

info() { printf "${BLUE}${BOLD}🔹 %s${RESET}\n" "$1"; }
ok()   { printf "${GREEN}${BOLD}✅ %s${RESET}\n" "$1"; }
warn() { printf "${YELLOW}${BOLD}⚠️  %s${RESET}\n" "$1"; }
err()  { printf "${RED}${BOLD}❌ %s${RESET}\n" "$1"; }

hide_cursor() { tput civis 2>/dev/null || true; }
show_cursor() { tput cnorm 2>/dev/null || true; }

spin() {
  local pid="$1" msg="$2"
  local frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏) i=0
  hide_cursor
  while kill -0 "$pid" 2>/dev/null; do
    printf "\r${DIM}%s %s${RESET}" "$msg" "${frames[i++ % ${#frames[@]}]}"
    sleep 0.1
  done
  printf "\r"
  show_cursor
}
run_spin() { local msg="$1"; shift; ( "$@" ) & local pid=$!; spin "$pid" "$msg"; wait "$pid"; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Missing command: $1"; exit 1; }; }
need_one_of() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 && return 0; done; err "Missing one of: $*"; exit 1; }
bytes_h() { awk -v b="$1" 'function p(x){printf "%.2f", x} b<1024{print b " B"; exit} b<1048576{p(b/1024); print " KiB"; exit} b<1073741824{p(b/1048576); print " MiB"; exit} {p(b/1073741824); print " GiB"}'; }

# ---------- checks ----------
banner
if [[ $EUID -ne 0 ]]; then err "Run as root"; exit 1; fi
need_cmd curl; need_cmd lsblk; need_cmd awk; need_cmd sed; need_cmd grep; need_cmd sha256sum
need_cmd blockdev; need_cmd dd; need_cmd openssl
need_one_of sgdisk parted
need_one_of mkfs.vfat mkfs.fat
need_cmd udevadm; need_cmd partprobe

WORK="${TMPDIR:-/tmp}/fedora-usb.$$"
mkdir -p "$WORK"
cleanup() { show_cursor; rm -rf "$WORK"; }
trap cleanup EXIT

# ---------- discover latest Fedora Server ----------
info "Discovering latest Fedora Server release 🔎"
BASE_INDEX="https://dl.fedoraproject.org/pub/fedora/linux/releases/"
LATEST_VER="$(curl -fsSL "$BASE_INDEX" | grep -Eo '>[0-9]+/' | tr -cd '0-9\n' | sort -nr | head -n1)"
[[ -n "${LATEST_VER:-}" ]] || { err "Could not detect latest Fedora version"; exit 1; }
ISO_DIR="https://dl.fedoraproject.org/pub/fedora/linux/releases/${LATEST_VER}/Server/x86_64/iso"
INDEX_HTML="$(curl -fsSL "$ISO_DIR/")"
ISO_NAME="$(printf "%s" "$INDEX_HTML" | grep -Eo 'Fedora-Server-(dvd|netinst)-x86_64-[^"]+\.iso' | grep -E '^Fedora-Server-dvd-x86_64' | head -n1)"
[[ -n "${ISO_NAME:-}" ]] || ISO_NAME="$(printf "%s" "$INDEX_HTML" | grep -Eo 'Fedora-Server-(dvd|netinst)-x86_64-[^"]+\.iso' | head -n1)"
CHECKSUM_NAME="$(printf "%s" "$INDEX_HTML" | grep -Eo 'Fedora-Server-[^"]+-x86_64-CHECKSUM' | head -n1)"
[[ -n "${ISO_NAME:-}" && -n "${CHECKSUM_NAME:-}" ]] || { err "Could not locate ISO or CHECKSUM in $ISO_DIR"; exit 1; }
ok "Latest Fedora Server: ${LATEST_VER}"
info "ISO: ${ISO_NAME}"

# ---------- download ----------
info "Downloading ISO 📦"
curl -fL --progress-bar -o "$WORK/$ISO_NAME" "$ISO_DIR/$ISO_NAME"
ok "ISO downloaded"
info "Fetching checksum"
curl -fL --progress-bar -o "$WORK/$CHECKSUM_NAME" "$ISO_DIR/$CHECKSUM_NAME"

info "Verifying checksum 🧪"
EXPECTED_SHA="$(grep -F "$ISO_NAME" "$WORK/$CHECKSUM_NAME" | sed -E 's/.*= ([0-9a-fA-F]{64}).*/\1/' || true)"
if [[ -n "${EXPECTED_SHA:-}" ]]; then
  ACTUAL_SHA="$(sha256sum "$WORK/$ISO_NAME" | awk '{print $1}')"
  [[ "$EXPECTED_SHA" == "$ACTUAL_SHA" ]] || { err "Checksum mismatch"; exit 1; }
  ok "Checksum OK"
else
  warn "Could not parse checksum file. Continuing."
fi

# ---------- pick USB ----------
printf "\n${BOLD}Select the USB device to write (this will be ERASED) 💿${RESET}\n"
lsblk -dpno NAME,SIZE,MODEL,TRAN,RM | awk 'BEGIN{printf "\n%-22s %-8s %-24s %-6s %-2s\n","DEVICE","SIZE","MODEL","BUS","RM"}{printf "%-22s %-8s %-24s %-6s %-2s\n",$1,$2,$3,$4,$5}'
read -r -p "$(printf "${YELLOW}${BOLD}Type the device path (eg. /dev/sdX or /dev/nvme1n1): ${RESET}")" DEV
[[ -b "${DEV:-}" ]] || { err "Invalid block device"; exit 1; }

# refuse mounted or root device
if mount | awk '{print $1}' | grep -qx "$DEV"; then err "Device appears mounted. Unmount first."; exit 1; fi
ROOT_DEV="$(findmnt -no SOURCE / | sed 's/[0-9]*$//')"
[[ "$DEV" != "$ROOT_DEV" ]] || { err "Refusing to write to root device $DEV"; exit 1; }

# ---------- capacity check BEFORE writing ----------
ISO_SIZE="$(stat -c %s "$WORK/$ISO_NAME")"
OEMDRV_MIN=$((128 * 1024 * 1024)) # 128 MiB headroom
DEV_SIZE="$(blockdev --getsize64 "$DEV" 2>/dev/null || lsblk -bdno SIZE "$DEV")"

printf "\n${BOLD}Capacity check${RESET}\n"
echo "  Device size: $(bytes_h "$DEV_SIZE")"
echo "  ISO size   : $(bytes_h "$ISO_SIZE")"
echo "  Headroom   : $(bytes_h "$OEMDRV_MIN")  (for OEMDRV partition)"
NEEDED=$((ISO_SIZE + OEMDRV_MIN))
if (( DEV_SIZE < NEEDED )); then err "USB too small. Need at least $(bytes_h "$NEEDED")."; exit 1; fi
ok "USB capacity looks good"

read -r -p "$(printf "${RED}${BOLD}This will ERASE all data on $DEV. Type YES to continue: ${RESET}")" CONFIRM
[[ "$CONFIRM" == "YES" ]] || { err "Aborted"; exit 1; }

# ---------- target disk mode ----------
printf "\n${BOLD}Target disk mode on the SERVER (where Fedora will be installed) 🖥️${RESET}\n"
echo "  1) Auto single internal disk (safe). Use exactly one internal non-USB disk, else abort."
echo "  2) All internal disks. Wipe every internal non-USB disk."
echo "  3) Manual device name. You will enter one like nvme0n1 or sda."
read -r -p "$(printf "${BOLD}Choose 1/2/3 [1]: ${RESET}")" MODESEL
MODESEL="${MODESEL:-1}"

KS_MODE="AUTO_SINGLE"
KS_MANUAL_DEV=""
case "$MODESEL" in
  1) KS_MODE="AUTO_SINGLE" ;;
  2) KS_MODE="ALL_INTERNAL" ;;
  3) KS_MODE="MANUAL"; read -r -p "$(printf "${BOLD}Enter server device name (no /dev/), eg. nvme0n1: ${RESET}")" KS_MANUAL_DEV ;;
  *) KS_MODE="AUTO_SINGLE" ;;
esac

# ---------- Kickstart inputs ----------
printf "\n${BOLD}Kickstart options ✍️${RESET}\n"
read -r -p "Language [en_US.UTF-8]: " KS_LANG; KS_LANG="${KS_LANG:-en_US.UTF-8}"
read -r -p "Keyboard [it]: " KS_KBD; KS_KBD="${KS_KBD:-it}"
read -r -p "Timezone [Europe/Rome]: " KS_TZ; KS_TZ="${KS_TZ:-Europe/Rome}"
read -r -p "Hostname [m920q]: " KS_HOST; KS_HOST="${KS_HOST:-m920q}"

read -r -p "Use DHCP networking? [y/N]: " KS_DHCP; KS_DHCP="${KS_DHCP:-N}"
if [[ "$KS_DHCP" =~ ^[Yy]$ ]]; then
  KS_NET="network --bootproto=dhcp --device=link --activate --hostname=${KS_HOST}"
else
  read -r -p "Static IP eg. 192.168.1.20: " KS_IP
  read -r -p "Netmask eg. 255.255.255.0: " KS_MASK
  read -r -p "Gateway eg. 192.168.1.1: " KS_GW
  read -r -p "DNS servers space separated [1.1.1.1 9.9.9.9]: " KS_DNS; KS_DNS="${KS_DNS:-1.1.1.1 9.9.9.9}"
  KS_NET="network --bootproto=static --ip=${KS_IP} --netmask=${KS_MASK} --gateway=${KS_GW} --nameserver=\"${KS_DNS}\" --device=link --activate --hostname=${KS_HOST}"
fi

read -r -p "Admin username [admin]: " KS_USER; KS_USER="${KS_USER:-admin}"

# SSH pubkey path
read -r -p "Path to SSH public key file [~/.ssh/id_ed25519.pub]: " KS_SSHKEY_PATH
KS_SSHKEY_PATH="${KS_SSHKEY_PATH:-$HOME/.ssh/id_ed25519.pub}"
[[ -f "$KS_SSHKEY_PATH" ]] || { err "Key file not found: $KS_SSHKEY_PATH"; exit 1; }
KS_SSHKEY_CONTENT="$(<"$KS_SSHKEY_PATH")"
grep -Eq '^ssh-(ed25519|rsa|ecdsa) ' <<<"$KS_SSHKEY_CONTENT" || { err "Not a valid SSH public key file"; exit 1; }

# Force a password for sudo (hashed, never enable SSH password auth)
while :; do
  read -r -s -p "Set local password for ${KS_USER} (for sudo): " PASS1; echo
  read -r -s -p "Confirm password: " PASS2; echo
  [[ -n "$PASS1" && "$PASS1" == "$PASS2" ]] && break
  warn "Passwords did not match or were empty. Try again."
done
KS_PWHASH="$(openssl passwd -6 -salt "$(openssl rand -hex 6)" "$PASS1")"

read -r -p "Disable audio and USB video drivers in %post? [Y/n]: " KS_AV; KS_AV="${KS_AV:-Y}"
read -r -p "Final action poweroff or reboot [poweroff]: " KS_END; KS_END="${KS_END:-poweroff}"
[[ "$KS_END" == "poweroff" || "$KS_END" == "reboot" ]] || KS_END="poweroff"

printf "\n${BOLD}Summary${RESET}\n"
echo "  Fedora Server version : $LATEST_VER"
echo "  USB device            : $DEV"
echo "  Device size           : $(bytes_h "$DEV_SIZE")"
echo "  ISO size              : $(bytes_h "$ISO_SIZE")"
echo "  Required headroom     : $(bytes_h "$OEMDRV_MIN")"
echo "  Target mode           : $KS_MODE ${KS_MANUAL_DEV:+($KS_MANUAL_DEV)}"
echo "  Hostname              : $KS_HOST"
echo "  Network               : ${KS_NET}"
echo "  User                  : $KS_USER"
echo "  SSH key file          : $KS_SSHKEY_PATH"
echo "  A/V disable           : $( [[ "$KS_AV" =~ ^[Yy]$ ]] && echo yes || echo no )"
echo "  Final action          : $KS_END"
read -r -p "$(printf "${YELLOW}${BOLD}Type I UNDERSTAND to write the USB: ${RESET}")" ACK
[[ "$ACK" == "I UNDERSTAND" ]] || { err "Aborted"; exit 1; }

# ---------- write ISO ----------
info "Writing ISO to $DEV 💾"
wipefs -a "$DEV" >/dev/null 2>&1 || true
dd if="$WORK/$ISO_NAME" of="$DEV" bs=4M oflag=sync status=progress
run_spin "Syncing partition table" partprobe "$DEV"
udevadm settle

# ---------- create OEMDRV partition ----------
info "Creating OEMDRV partition in remaining free space 🧩"
FREE_BYTES="$(parted -m -s "$DEV" unit B print free | awk -F: '/free/ {gsub("B","",$4); sz=$4} END{print sz+0}')"
if [[ -z "$FREE_BYTES" || "$FREE_BYTES" -lt $OEMDRV_MIN ]]; then err "After writing the ISO, less than $(bytes_h "$OEMDRV_MIN") free remains. Use a larger USB."; exit 1; fi

before_parts="$(lsblk -lnpo NAME "$DEV")"
if command -v sgdisk >/dev/null 2>&1; then
  run_spin "Adding partition" sgdisk -N 0 -t 0:0700 -c 0:"OEMDRV" "$DEV"
else
  mapfile -t free_lines < <(parted -m -s "$DEV" unit MiB print free | grep ':free:')
  last_free="${free_lines[-1]}"
  start_mib="$(awk -F: '{print $2}' <<<"$last_free")"
  end_mib="$(awk -F: '{print $3}' <<<"$last_free")"
  run_spin "Adding partition" parted -s "$DEV" mkpart primary fat32 "$start_mib" "$end_mib"
fi
run_spin "Refreshing kernel view" partprobe "$DEV"
udevadm settle

after_parts="$(lsblk -lnpo NAME "$DEV")"
NEW_PART="$(comm -13 <(echo "$before_parts" | sort) <(echo "$after_parts" | sort) | tail -n1)"
[[ -b "${NEW_PART:-}" ]] || { err "Failed to detect new OEMDRV partition"; exit 1; }

if command -v mkfs.vfat >/dev/null 2>&1; then
  run_spin "Formatting ${NEW_PART} as FAT32 (OEMDRV)" mkfs.vfat -F 32 -n OEMDRV "$NEW_PART"
else
  run_spin "Formatting ${NEW_PART} as FAT32 (OEMDRV)" mkfs.fat -F 32 -n OEMDRV "$NEW_PART"
fi
udevadm settle

MNT="/mnt/oemdrv.$$"
mkdir -p "$MNT"
run_spin "Mounting OEMDRV" mount "$NEW_PART" "$MNT"

# ---------- build Kickstart ----------
info "Generating Kickstart ks.cfg ✍️"
KS_FILE="$MNT/ks.cfg"

cat > "$KS_FILE" <<KSHEAD
# Auto generated Kickstart for Fedora Server $LATEST_VER
cdrom
text
lang $KS_LANG
keyboard $KS_KBD
timezone $KS_TZ --utc
$KS_NET
rootpw --lock
user --name=$KS_USER --groups=wheel --homedir=/home/$KS_USER --iscrypted --password '$KS_PWHASH'
firewall --enabled --service=ssh
selinux --enforcing
services --enabled=sshd,chronyd,sudo
bootloader --timeout=1
zerombr

%pre --erroronfail --log=/tmp/ks-pre.log
set -euo pipefail
MODE="$KS_MODE"
MANUAL_DEV="$KS_MANUAL_DEV"

is_candidate() {
  local dev="\$1"
  [[ -b "/dev/\$dev" ]] || return 1
  [[ "\$dev" =~ ^(loop|ram) ]] && return 1
  local sys="/sys/block/\$dev"
  local rem=0
  [[ -f "\$sys/removable" ]] && read -r rem < "\$sys/removable" || true
  [[ "\$rem" -eq 1 ]] && return 1
  local bus
  bus="\$(udevadm info --query=property --name=/dev/\$dev | awk -F= '/^ID_BUS=/{print \$2}')"
  [[ "\$bus" == "usb" ]] && return 1
  echo "\$dev"
}

mapfile -t CANDS < <(lsblk -dnpo NAME,TYPE | awk '\$2=="disk"{gsub("/dev/","",\$1);print \$1}' | while read d; do is_candidate "\$d"; done)

case "\$MODE" in
  AUTO_SINGLE)
    if [[ "\${#CANDS[@]}" -ne 1 ]]; then
      echo "AUTO_SINGLE found \${#CANDS[@]} internal disks: \${CANDS[*]}" > /dev/tty3
      exit 1
    fi
    echo "ignoredisk --only-use=\${CANDS[0]}" > /tmp/target.ks
    echo "clearpart --all --initlabel" >> /tmp/target.ks
    ;;
  ALL_INTERNAL)
    if [[ "\${#CANDS[@]}" -lt 1 ]]; then
      echo "No internal disks detected" > /dev/tty3
      exit 1
    fi
    list=\$(IFS=,; echo "\${CANDS[*]}")
    echo "ignoredisk --only-use=\$list" > /tmp/target.ks
    echo "clearpart --all --initlabel" >> /tmp/target.ks
    ;;
  MANUAL)
    if [[ -z "\$MANUAL_DEV" ]]; then
      echo "Manual mode without device" > /dev/tty3
      exit 1
    fi
    echo "ignoredisk --only-use=\$MANUAL_DEV" > /tmp/target.ks
    echo "clearpart --all --initlabel" >> /tmp/target.ks
    ;;
  *)
    echo "Unknown MODE \$MODE" > /dev/tty3
    exit 1
    ;;
esac
echo "autopart --type=btrfs" >> /tmp/target.ks
%end

%include /tmp/target.ks

$KS_END

%packages
@^minimal-environment
sudo
openssh-server
chrony
%end

%post --log=/root/ks-post.log --erroronfail
set -e
user_home="/home/$KS_USER"
mkdir -p "\$user_home/.ssh"
chmod 700 "\$user_home/.ssh"

# authorized_keys and SSH hardening: key-only login, no root ssh
cat > "\$user_home/.ssh/authorized_keys" <<'EOFKEY'
$KS_SSHKEY_CONTENT
EOFKEY
chmod 600 "\$user_home/.ssh/authorized_keys"
chown -R $KS_USER:$KS_USER "\$user_home/.ssh"
sed -ri 's/^(#\s*)?PasswordAuthentication\s+.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -ri 's/^(#\s*)?KbdInteractiveAuthentication\s+.*/KbdInteractiveAuthentication no/' /etc/ssh/sshd_config
sed -ri 's/^(#\s*)?ChallengeResponseAuthentication\s+.*/ChallengeResponseAuthentication no/' /etc/ssh/sshd_config
sed -ri 's/^(#\s*)?PubkeyAuthentication\s+.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -ri 's/^(#\s*)?PermitRootLogin\s+.*/PermitRootLogin no/' /etc/ssh/sshd_config

# optional: disable audio and USB video capture
KSHEAD

if [[ "$KS_AV" =~ ^[Yy]$ ]]; then
  cat >> "$KS_FILE" <<'KSAV'
cat >/etc/modprobe.d/disable-sound.conf <<'EOF1'
blacklist snd_hda_intel
blacklist snd_hda_codec_hdmi
blacklist snd_hda_codec
blacklist snd_hda_core
blacklist snd_pcm
blacklist snd_timer
blacklist snd
blacklist soundcore
EOF1
cat >/etc/modprobe.d/disable-video-capture.conf <<'EOF2'
blacklist uvcvideo
blacklist videodev
EOF2
dracut --force
KSAV
fi

cat >> "$KS_FILE" <<'KSEND'
%end
KSEND

sync

# ---------- verify and unmount ----------
info "Verifying OEMDRV label and ks.cfg ✅"
LBL="$(lsblk -no LABEL "$NEW_PART" || true)"
[[ "$LBL" == "OEMDRV" ]] || { err "Partition label is not OEMDRV"; umount "$MNT" || true; exit 1; }
[[ -s "$KS_FILE" ]] || { err "ks.cfg missing or empty"; umount "$MNT" || true; exit 1; }

printf "\n${DIM}Preview of ks.cfg (first 120 lines, password hash redacted):${RESET}\n"
echo "------------------------------------------------------------"
sed -e "s/--password '[^']*'/--password '<redacted>'/" -n '1,120p' "$KS_FILE" || true
echo "------------------------------------------------------------"

run_spin "Unmounting OEMDRV" umount "$MNT"
sync; udevadm settle

printf "\n${GREEN}${BOLD}🚀 All set!${RESET}\n"
echo " - USB now contains:"
echo "   • Fedora Server ${LATEST_VER} installer"
echo "   • OEMDRV partition with ks.cfg at the root"
echo
echo "Install on the headless server:"
echo "  1. Plug this single USB"
echo "  2. Power on and boot from USB"
echo "  3. Installer runs unattended and then ${KS_END}"
echo
ok "If it ever reboots back to the installer, remove the USB and power on again."
