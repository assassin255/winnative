#!/usr/bin/env bash
set -euo pipefail

APP_NAME="tinyinstaller-ref"
DEFAULT_IMAGE_URL="https://archive.org/download/win_20260312/win.img"
DEFAULT_IMAGE_NAME="win.img"
DEFAULT_DOWNLOAD_DIR="/var/tmp"
STATE_FILE="/var/tmp/tinyinstaller-ref.state"
LOG_FILE="/var/tmp/tinyinstaller-ref.log"
APPLY=0
REBOOT=0
WIPEFS=1
LIST_ONLY=0
PLAN_ONLY=0
MENU=0
AUTO=0
FORCE=0
ASSUME_YES=0
TARGET=""
IMAGE_PATH=""
IMAGE_URL="$DEFAULT_IMAGE_URL"
IMAGE_LABEL="Windows 11 LTSB"
DOWNLOAD_DIR="$DEFAULT_DOWNLOAD_DIR"

WINDOWS_11_URL="https://archive.org/download/win_20260312/win.img"
WINDOWS_10_LTSC_2023_URL="https://archive.org/download/win_20260215/win.img"

RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
BLUE=$'\033[34m'
MAGENTA=$'\033[35m'
CYAN=$'\033[36m'
WHITE=$'\033[37m'

c() {
  printf '%b%s%b' "$1" "$2" "$RESET"
}

set_image_profile() {
  case "$1" in
    1|win11|windows11|11)
      IMAGE_URL="$WINDOWS_11_URL"
      IMAGE_LABEL="Windows 11 LTSB"
      ;;
    2|win10|windows10|ltsc2023|2023)
      IMAGE_URL="$WINDOWS_10_LTSC_2023_URL"
      IMAGE_LABEL="Windows 10 LTSC 2023"
      ;;
    *)
      fail "unknown Windows image profile: $1"
      ;;
  esac
}

choose_windows_image() {
  echo
  echo "$(c "$MAGENTA" "[select Windows image]")"
  echo "  $(c "$YELLOW" "1)") $(c "$WHITE" "Windows 11 LTSB")"
  echo "  $(c "$YELLOW" "2)") $(c "$WHITE" "Windows 10 LTSC 2023")"
  read -rp "$(c "$GREEN" "Choose [1-2, Enter=1]: ")" img_choice
  img_choice="${img_choice:-1}"
  set_image_profile "$img_choice"
  log "selected image: $IMAGE_LABEL"
  log "selected url: $IMAGE_URL"
}

log() { printf '[%s] %s\n' "$APP_NAME" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '[%s] WARN: %s\n' "$APP_NAME" "$*" | tee -a "$LOG_FILE" >&2; }
fail() { printf '[%s] ERROR: %s\n' "$APP_NAME" "$*" | tee -a "$LOG_FILE" >&2; exit 1; }

need_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || fail "run as root"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "missing command: $1"
}

human_bytes() {
  awk -v b="$1" 'BEGIN {
    split("B KiB MiB GiB TiB PiB", u, " ")
    i=1
    while (b >= 1024 && i < 6) { b/=1024; i++ }
    printf "%.1f %s", b, u[i]
  }'
}

show_banner() {
  cat <<EOF
$(c "$MAGENTA" "${BOLD}╔════════════════════════════════════════════════════════════╗")
$(c "$MAGENTA" "${BOLD}║") $(c "$CYAN" "TinyInstaller reference tool")$(printf '%*s' 29)$(c "$MAGENTA" "${BOLD}║")
$(c "$MAGENTA" "${BOLD}╠════════════════════════════════════════════════════════════╣")
$(c "$MAGENTA" "${BOLD}║") $(c "$BLUE" "image:") $(c "$WHITE" "$IMAGE_URL")$(printf '%*s' 6)$(c "$MAGENTA" "${BOLD}║")
$(c "$MAGENTA" "${BOLD}║") $(c "$BLUE" "mode:")  $(if [[ $APPLY -eq 1 ]]; then c "$GREEN" "apply"; else c "$YELLOW" "dry-run"; fi)$(printf '%*s' 32)$(c "$MAGENTA" "${BOLD}║")
$(c "$MAGENTA" "${BOLD}╚════════════════════════════════════════════════════════════╝")
EOF
}

show_state() {
  [[ -f "$STATE_FILE" ]] && { printf '%s\n' "[state]"; cat "$STATE_FILE"; } || true
}

load_state_target() {
  [[ -f "$STATE_FILE" ]] || return 1
  local saved
  saved="$(sed -n 's/.*"target":"\([^"]*\)".*/\1/p' "$STATE_FILE" | head -n 1)"
  [[ -n "$saved" ]] || return 1
  [[ -b "$saved" ]] || return 1
  TARGET="$saved"
  log "restored target from state: $TARGET"
}

restore_target_if_possible() {
  [[ -n "$TARGET" ]] && return 0
  load_state_target || true
}

env_check() {
  local sys os
  os="$(uname -s 2>/dev/null || true)"
  [[ "$os" == "Linux" ]] || fail "Linux only"
  if [[ -e /.dockerenv || -e /.containerenv || -f /run/.containerenv ]]; then
    warn "running inside a container"
  fi
  if command -v hostnamectl >/dev/null 2>&1; then
    sys="$(hostnamectl 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')"
    log "system: $sys"
  fi
}

usage() {
  cat <<EOF
Usage: $APP_NAME [options]

Options:
  --auto                 Auto-pick a disk, use the default image, and write it
  --menu                 Interactive menu
  --list-devices         Show candidate disks
  --plan                 Download/check image and show what would happen
  --url <url>            Image URL
  --image <path>         Local raw image path
  --download-dir <dir>   Download location
  --target <device>      Target block device, e.g. /dev/sda
  --apply                Actually write image to target
  --no-wipefs            Skip wipefs before writing
  --reboot               Reboot after a successful write
  --force                Allow mounted target devices
  --help                 Show help

Defaults:
  URL:          $DEFAULT_IMAGE_URL
  download dir:  $DEFAULT_DOWNLOAD_DIR
EOF
}

list_devices() {
  printf '%b\n' "$(c "$CYAN" "[available disks]")"
  local listed=0
  if command -v lsblk >/dev/null 2>&1; then
    if lsblk -dpno NAME,SIZE,MODEL,TRAN,TYPE,MOUNTPOINTS 2>/dev/null | awk '
      $5 == "disk" {
        printf "  %-14s %-10s %-24s %-8s %s\n", $1, $2, $3, $4, $6
        listed=1
      }
      END { exit listed ? 0 : 1 }
    '; then
      return 0
    fi
  fi
  awk '
    NR > 2 && $4 ~ /^(sd|vd|xvd|nvme|mmcblk|hd)/ {
      print $4
    }' /proc/partitions 2>/dev/null | while read -r dev; do
    [[ -b "/dev/$dev" ]] || continue
    printf '  %-14s %-10s %-24s %-8s %s\n' "/dev/$dev" "?" "?" "?" "?"
    listed=1
  done
  [[ $listed -eq 1 ]] || warn "no disks found"
}

auto_pick_target() {
  local candidates=()
  local line dev size mount rm

  if command -v lsblk >/dev/null 2>&1; then
    while IFS=$'\t' read -r dev size mount rm; do
      [[ -n "$dev" ]] || continue
      candidates+=("$size:$dev")
    done < <(lsblk -dpno NAME,SIZE,TYPE,MOUNTPOINTS,RM 2>/dev/null | awk '
      $3 == "disk" && $4 == "" && $5 == 0 {print $1 "\t" $2 "\t" $4 "\t" $5}
    ')
    if [[ ${#candidates[@]} -eq 0 ]]; then
      while IFS=$'\t' read -r dev size mount rm; do
        [[ -n "$dev" ]] || continue
        candidates+=("$size:$dev")
      done < <(lsblk -dpno NAME,SIZE,TYPE,MOUNTPOINTS,RM 2>/dev/null | awk '
        $3 == "disk" && $5 == 0 {print $1 "\t" $2 "\t" $4 "\t" $5}
      ')
    fi
  fi

  if [[ ${#candidates[@]} -eq 0 ]]; then
    while read -r major minor blocks name; do
      [[ "$name" =~ ^(sd|vd|xvd|nvme|mmcblk|hd) ]] || continue
      [[ -b "/dev/$name" ]] || continue
      candidates+=("$blocks:/dev/$name")
    done < <(awk 'NR > 2 {print $1, $2, $3, $4}' /proc/partitions 2>/dev/null || true)
  fi

  [[ ${#candidates[@]} -gt 0 ]] || fail "could not auto-select a disk"
  IFS=$'\n' candidates=($(printf '%s\n' "${candidates[@]}" | sort -t: -k1,1n))
  TARGET="${candidates[-1]#*:}"
  [[ -b "$TARGET" ]] || fail "auto-selected target is invalid"
  log "auto-selected target: $TARGET"
}

ensure_target_safe() {
  local target="$1"
  [[ -b "$target" ]] || fail "target is not a block device: $target"
  if lsblk -nrpo NAME,TYPE,MOUNTPOINTS "$target" | awk '$2 != "disk" && $3 != "" {found=1} END {exit !found}'; then
    if [[ $FORCE -ne 1 ]]; then
      fail "target appears mounted; use --force only if you really mean it"
    fi
    warn "forcing write to mounted target"
  fi
}

download_image() {
  local url="$1"
  local out="$2"
  mkdir -p "$(dirname "$out")"
  log "downloading image to $out"
  if command -v aria2c >/dev/null 2>&1; then
    aria2c -x16 -s16 --continue --file-allocation=none "$url" -o "$out"
  else
    curl -fL --retry 3 --retry-delay 2 -o "$out" "$url"
  fi
}

resolve_image() {
  if [[ -n "$IMAGE_PATH" ]]; then
    [[ -f "$IMAGE_PATH" ]] || fail "missing image file: $IMAGE_PATH"
    return 0
  fi
  mkdir -p "$DOWNLOAD_DIR"
  IMAGE_PATH="$DOWNLOAD_DIR/$DEFAULT_IMAGE_NAME"
  if [[ ! -f "$IMAGE_PATH" ]]; then
    download_image "$IMAGE_URL" "$IMAGE_PATH"
  else
    log "reusing existing image: $IMAGE_PATH"
  fi
}

plan() {
  local size_bytes device_bytes
  resolve_image
  log "image:  $IMAGE_PATH"
  [[ -n "$TARGET" ]] && log "target: $TARGET" || log "target: <none>"
  if [[ -f "$IMAGE_PATH" ]]; then
    size_bytes=$(stat -c '%s' "$IMAGE_PATH")
    log "image size: $(human_bytes "$size_bytes") (${size_bytes} bytes)"
  fi
  if [[ -n "$TARGET" && -b "$TARGET" ]]; then
    device_bytes=$(blockdev --getsize64 "$TARGET")
    log "device size: $(human_bytes "$device_bytes") (${device_bytes} bytes)"
  fi
  log "wipefs: $([[ $WIPEFS -eq 1 ]] && echo yes || echo no)"
  log "reboot: $([[ $REBOOT -eq 1 ]] && echo yes || echo no)"
  printf '%b\n' "$(c "$CYAN" "[steps]")"
  printf '%b\n' "  $(c "$YELLOW" "1.") check system"
  printf '%b\n' "  $(c "$YELLOW" "2.") list disks"
  printf '%b\n' "  $(c "$YELLOW" "3.") validate image and target"
  printf '%b\n' "  $(c "$YELLOW" "4.") ask for confirmation"
  printf '%b\n' "  $(c "$YELLOW" "5.") write image"
  printf '%b\n' "  $(c "$YELLOW" "6.") sync and reboot if requested"
  show_state
}

rescan_partitions() {
  local target="$1"
  if command -v partprobe >/dev/null 2>&1; then
    partprobe "$target" || true
  elif command -v partx >/dev/null 2>&1; then
    partx -u "$target" || true
  else
    warn "no partition rescan tool available"
  fi
}

write_image() {
  local image="$1"
  local target="$2"
  local size_bytes device_bytes

  ensure_target_safe "$target"
  [[ -f "$image" ]] || fail "missing image file: $image"

  size_bytes=$(stat -c '%s' "$image")
  device_bytes=$(blockdev --getsize64 "$target")
  log "image size: $(human_bytes "$size_bytes")"
  log "device size: $(human_bytes "$device_bytes")"

  if (( device_bytes < size_bytes )); then
    fail "target is smaller than the image"
  fi

  lsblk "$target" || true
  echo
  if [[ $ASSUME_YES -eq 1 ]]; then
    log "auto-confirm enabled"
  else
    warn "this will destroy all data on $target"
    warn "type WIPE to continue"
    read -r confirm
    [[ "$confirm" == "WIPE" ]] || fail "aborted"
  fi

  printf '{"image":"%s","target":"%s","when":"%s"}\n' "$image" "$target" "$(date -Iseconds)" > "$STATE_FILE"
  sync
  if [[ $WIPEFS -eq 1 ]]; then
    log "wipefs -a $target"
    wipefs -a "$target" || true
  fi
  log "writing image"
  dd if="$image" of="$target" bs=64M status=progress conv=fsync
  sync
  rescan_partitions "$target"
  udevadm settle || true
  sync
  log "write complete"
}

interactive_menu() {
  while true; do
    show_banner
    echo
    echo "$(c "$MAGENTA" "1)") $(c "$WHITE" "list disks")"
    echo "$(c "$MAGENTA" "2)") $(c "$WHITE" "plan")"
    echo "$(c "$MAGENTA" "3)") $(c "$WHITE" "write image")"
    echo "$(c "$MAGENTA" "4)") $(c "$WHITE" "exit")"
    read -rp "$(c "$GREEN" "Select [1-4]: ")" choice
    case "$choice" in
      1) list_devices ;;
      2) plan ;;
      3)
        resolve_image
        [[ -n "$TARGET" ]] || read -rp "$(c "$GREEN" "Target device (/dev/sdX): ")" TARGET
        write_image "$IMAGE_PATH" "$TARGET"
        if [[ $REBOOT -eq 1 ]]; then
          log "rebooting"
          reboot
        fi
        ;;
      4) exit 0 ;;
      *) warn "invalid selection" ;;
    esac
  done
}

guided_full_run() {
  ASSUME_YES=1
  REBOOT=1
  show_banner
  choose_windows_image
  restore_target_if_possible
  if [[ -z "$TARGET" ]]; then
    auto_pick_target
  fi
  show_banner
  log "guided target: $TARGET"
  log "guided image:  $IMAGE_LABEL"
  resolve_image
  plan
  write_image "$IMAGE_PATH" "$TARGET"
  log "rebooting"
  reboot
}

main() {
  local had_args=0
  if [[ $# -gt 0 ]]; then
    had_args=1
  fi
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --auto) AUTO=1; shift ;;
      --menu) MENU=1; shift ;;
      --list-devices) LIST_ONLY=1; shift ;;
      --plan) PLAN_ONLY=1; shift ;;
      --url) IMAGE_URL="${2:-}"; shift 2 ;;
      --image) IMAGE_PATH="${2:-}"; shift 2 ;;
      --download-dir) DOWNLOAD_DIR="${2:-}"; shift 2 ;;
      --target) TARGET="${2:-}"; shift 2 ;;
      --apply) APPLY=1; shift ;;
      --no-wipefs) WIPEFS=0; shift ;;
      --reboot) REBOOT=1; shift ;;
      --force) FORCE=1; shift ;;
      --help) usage; exit 0 ;;
      *) fail "unknown argument: $1" ;;
    esac
  done

  if [[ $AUTO -eq 1 ]]; then
    LIST_ONLY=0
    PLAN_ONLY=0
    MENU=0
    APPLY=1
    if [[ -z "$TARGET" ]]; then
      FORCE=0
    fi
  fi

  need_root
  for c in lsblk blkid dd udevadm sync blockdev stat awk sed; do
    need_cmd "$c"
  done
  env_check
  show_banner

  restore_target_if_possible

  if [[ $AUTO -eq 1 && -z "$TARGET" ]]; then
    auto_pick_target
  fi

  if [[ $LIST_ONLY -eq 1 ]]; then
    list_devices
    exit 0
  fi

  if [[ $MENU -eq 1 ]]; then
    interactive_menu
    exit 0
  fi

  if [[ $had_args -eq 0 ]]; then
    guided_full_run
    exit 0
  fi

  resolve_image

  if [[ $PLAN_ONLY -eq 1 || -z "$TARGET" ]]; then
    plan
    if [[ -z "$TARGET" ]]; then
      list_devices
    fi
    if [[ $AUTO -eq 1 && -z "$TARGET" ]]; then
      fail "auto mode could not select a target"
    fi
    exit 0
  fi

  if [[ $APPLY -ne 1 ]]; then
    plan
    log "dry-run only; rerun with --apply to write"
    exit 0
  fi

  write_image "$IMAGE_PATH" "$TARGET"

  if [[ $REBOOT -eq 1 ]]; then
    log "rebooting"
    reboot
  fi
}

main "$@"
