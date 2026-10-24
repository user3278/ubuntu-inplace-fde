#!/usr/bin/env bash
# fde-encrypt.sh - add full disk encryption (LUKS2) to an existing Ubuntu
# install in place, keeping all data. /boot moves to a new small unencrypted
# partition at the end of the disk.
#
# Run it from an Ubuntu live USB, not from the installed system:
#   sudo bash fde-encrypt.sh --disk /dev/nvme0n1 --check   # checks only, changes nothing
#   sudo bash fde-encrypt.sh --disk /dev/nvme0n1           # does it (asks you to type ENCRYPT)
# After rebooting into the encrypted system:
#   sudo bash fde-encrypt.sh --verify                      # confirms the boot setup
#
# Safe to re-run: if it stops part way (error, power cut, Ctrl+C), run the same
# command again and it carries on from where it got to.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage:
  sudo bash fde-encrypt.sh --disk DEVICE [--check] [--uuid UUID] [--boot-size MIB]
  sudo bash fde-encrypt.sh --verify

  --disk DEVICE     the whole disk Ubuntu is on, e.g. /dev/nvme0n1 or /dev/sda
  --check           show the checks and the plan, change nothing
  --uuid UUID       extra safety: refuse unless the root filesystem has this UUID
                    (find it beforehand on the installed system: findmnt -no UUID /)
  --boot-size MIB   size of the new /boot partition (default 2048)
  --verify          on the encrypted system after rebooting: check the boot setup
EOF
}

ORIG_ARGS=("$@")
DISK=${FDE_DISK:-}
EXPECT_UUID=${FDE_EXPECT_UUID:-}
BOOT_SIZE_MIB=${FDE_BOOT_SIZE_MIB:-2048}
MODE=run
while (( $# )); do
    case $1 in
        --disk|--uuid|--boot-size)
            [[ $# -ge 2 ]] || { echo "Missing value for $1"; usage; exit 2; }
            case $1 in
                --disk) DISK=$2 ;;
                --uuid) EXPECT_UUID=$2 ;;
                --boot-size) BOOT_SIZE_MIB=$2 ;;
            esac
            shift ;;
        --check)  MODE=check ;;
        --verify) MODE=verify ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 2 ;;
    esac
    shift
done

HEADER_MIB=32            # room given up at the front for the LUKS2 header
MAPPER=${FDE_MAPPER:-cryptroot}   # FDE_MAPPER: testing only
BOOT_LABEL=FDEBOOT
TARGET=/mnt/fde-target
WORK=/mnt/fde-work
LOG=/tmp/fde-encrypt.log
LINUX_FS_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4

# Testing hooks only - leave unset for real use.
SKIP_CHROOT=${FDE_SKIP_CHROOT:-0}
KEYFILE=${FDE_KEYFILE:-}
ASSUME_YES=${FDE_YES:-0}

say()  { echo; echo "==> $*"; }
warn() { echo "WARNING: $*" >&2; }
die()  { echo; echo "ERROR: $*" >&2; echo "Stopped. Log: $LOG" >&2; exit 1; }

# Match text without "cmd | grep -q": grep -q quits early, the writer gets
# SIGPIPE, and with pipefail a successful match then counts as a failure.
contains() { grep -q -- "$1" <<<"$2"; }

part() {  # partition N of disk: /dev/nvme0n1 -> /dev/nvme0n1p2, /dev/sda -> /dev/sda2
    if [[ $1 =~ [0-9]$ ]]; then echo "${1}p$2"; else echo "$1$2"; fi
}

mapper_is_ours() {  # is /dev/mapper/$MAPPER open on $ROOT (and not something else)?
    local st
    st=$(cryptsetup status "$MAPPER" 2>/dev/null) || return 1
    [[ $(awk '$1=="device:"{print $2}' <<<"$st") == "$ROOT" ]]
}

cleanup() {
    umount -R "$TARGET" 2>/dev/null || true
    umount "$WORK/old" "$WORK/new" "$WORK/esp" 2>/dev/null || true
    if mapper_is_ours; then cryptsetup close "$MAPPER" 2>/dev/null || true; fi
}

fs_bytes() {   # size of the ext4 filesystem on $1, in bytes
    dumpe2fs -h "$1" 2>/dev/null |
        awk -F: '/^Block count/{c=$2} /^Block size/{s=$2} END{printf "%d\n", c*s}'
}

part_sectors() {  # start or size of partition $1 ("start"/"size"), in device sectors
    local n; n=$(basename "$1")
    echo $(( $(cat "/sys/class/block/$n/$2") * 512 / SS ))
}

fsck_ok() {  # e2fsck exit 0 = clean, 1 = fixed; anything else is a problem
    local rc=0
    e2fsck -f -y "$1" || rc=$?
    (( rc <= 1 )) || die "filesystem check of $1 failed (e2fsck exit $rc)"
}

on_battery() {
    local p has_batt=0
    for p in /sys/class/power_supply/*; do
        [[ -e $p/type ]] || continue
        [[ $(cat "$p/scope" 2>/dev/null) == Device ]] && continue   # mouse/keyboard batteries
        case $(cat "$p/type") in
            Mains) [[ $(cat "$p/online" 2>/dev/null) == 1 ]] && return 1 ;;
            Battery) has_batt=1 ;;
        esac
    done
    (( has_batt ))
}

is_luks() { cryptsetup isLuks "$1" 2>/dev/null; }
reencrypt_pending() { contains online-reencrypt "$(cryptsetup luksDump "$1" 2>/dev/null)"; }

verify_boot() {  # $1 = root of the installed system, $2 = root fs UUID, $3 = /boot UUID
    local t=$1 fs_uuid=$2 boot_uuid=$3 ok=1 img name listing
    say "Verifying boot setup"
    if awk -v m="$MAPPER" '$1==m{f=1} END{exit !f}' "$t/etc/crypttab" 2>/dev/null; then
        echo "  ok: /etc/crypttab unlocks $MAPPER at startup"
    else
        echo "  PROBLEM: no $MAPPER entry in /etc/crypttab"; ok=0
    fi
    for img in "$t"/boot/initrd.img-*; do
        [[ -L $img || ! -e $img ]] && continue
        name=$(basename "$img")
        # Run inside the installed system: the live USB may lack its decompressors.
        listing=$(chroot "$t" lsinitramfs "/boot/$name" 2>/dev/null || true)
        if contains 'cryptroot/crypttab' "$listing"; then
            echo "  ok: $name can unlock the disk"
        else
            echo "  PROBLEM: $name has no unlock support"; ok=0
        fi
    done
    # Ubuntu's GRUB passes the filesystem UUID (root=UUID=...); the initramfs
    # unlocks the disk first, then finds that filesystem inside it.
    if grep -Eq "root=(UUID=$fs_uuid|/dev/mapper/$MAPPER)( |$)" "$t/boot/grub/grub.cfg" 2>/dev/null; then
        echo "  ok: GRUB starts Linux from the encrypted root filesystem"
    else
        echo "  PROBLEM: GRUB config does not point at the root filesystem ($fs_uuid)"; ok=0
    fi
    if grep -qs -- "$boot_uuid" "$t"/boot/efi/EFI/*/grub.cfg; then
        echo "  ok: the EFI loader finds the /boot partition"
    else
        echo "  PROBLEM: EFI grub.cfg does not reference /boot ($boot_uuid)"; ok=0
    fi
    (( ok ))
}

# ---------------------------------------------------------------- checks ----

[[ $EUID -eq 0 ]] || die "run with sudo"

if [[ $MODE == verify ]]; then
    ROOT_SRC=$(findmnt -no SOURCE /)
    [[ $ROOT_SRC == /dev/mapper/* ]] || die "/ is not on an encrypted volume - run --verify after rebooting into the encrypted system"
    MAPPER=$(basename "$ROOT_SRC")
    BOOT_UUID=$(findmnt -no UUID /boot || true)
    [[ -n $BOOT_UUID ]] || die "/boot is not a separate partition"
    if verify_boot / "$(findmnt -no UUID /)" "$BOOT_UUID"; then
        echo; echo "All good."
        exit 0
    fi
    die "boot setup has problems (see above)"
fi

[[ -n $DISK ]] || { echo "Missing --disk."; echo; usage; echo; lsblk -dno NAME,SIZE,MODEL -e7,11 | sed 's#^#  /dev/#'; exit 2; }
[[ -b $DISK ]] || die "$DISK not found"
case $(lsblk -dno TYPE "$DISK") in
    disk|loop) ;;
    *) die "$DISK is not a whole disk (give e.g. /dev/nvme0n1, not a partition)" ;;
esac
[[ $BOOT_SIZE_MIB =~ ^[0-9]+$ ]] && (( BOOT_SIZE_MIB >= 512 )) || die "--boot-size must be a number of MiB, at least 512"

# Keep the computer from sleeping while this runs.
if [[ $MODE == run && -z ${FDE_NO_SLEEP:-} ]] && command -v systemd-inhibit >/dev/null; then
    export FDE_NO_SLEEP=1
    exec systemd-inhibit --what=sleep:idle --who=fde-encrypt --why="Encrypting disk" \
        bash "$0" "${ORIG_ARGS[@]}"
fi

for c in cryptsetup sfdisk e2fsck resize2fs dumpe2fs mkfs.ext4 blkid blockdev partprobe udevadm lsblk findmnt; do
    command -v "$c" >/dev/null || die "missing command: $c"
done

exec > >(tee -a "$LOG") 2>&1
echo "---- fde-encrypt.sh ${ORIG_ARGS[*]} - $(date) ----"

ESP=$(part "$DISK" 1)
ROOT=$(part "$DISK" 2)
BOOT=$(part "$DISK" 3)

MOUNTS=$(lsblk -nro MOUNTPOINTS "$DISK")
if contains '^/$' "$MOUNTS"; then
    die "you're running from the system on $DISK. Boot an Ubuntu live USB and run this there."
fi

trap cleanup EXIT
cleanup   # tidy up anything left mounted/open by an earlier interrupted run

MOUNTS=$(lsblk -nro MOUNTPOINTS "$DISK")
if [[ -n ${MOUNTS//[[:space:]]/} ]]; then
    lsblk -o NAME,MOUNTPOINTS "$DISK"
    die "something on $DISK is mounted. Unmount it (or click eject next to it in Files) and re-run."
fi

if [[ $MODE == run && $SKIP_CHROOT == 0 && ! -d /sys/firmware/efi ]]; then
    die "the live USB was started in legacy (BIOS) mode. Restart and pick the USB's UEFI entry in the boot menu."
fi

SS=$(blockdev --getss "$DISK")
MIB=$(( 1048576 / SS ))
NPARTS=$(lsblk -nro TYPE "$DISK" | grep -c '^part$' || true)
[[ -b $ESP && $(blkid -s TYPE -o value "$ESP" 2>/dev/null) == vfat ]] ||
    die "$ESP is not an EFI system partition (vfat) - this script expects partition 1 = EFI, partition 2 = Ubuntu"

OS_NAME="(encrypted - can't look inside yet)"
if is_luks "$ROOT"; then
    if reencrypt_pending "$ROOT"; then STATE=resume; else STATE=encrypted; fi
    [[ $NPARTS -eq 3 && $(blkid -s LABEL -o value "$BOOT" 2>/dev/null) == "$BOOT_LABEL" ]] ||
        die "$ROOT is LUKS but the $BOOT_LABEL /boot partition is missing - not a state this script made"
else
    [[ $(blkid -s TYPE -o value "$ROOT" 2>/dev/null) == ext4 ]] || die "$ROOT is not ext4"
    FS_UUID=$(blkid -s UUID -o value "$ROOT")
    if [[ -n $EXPECT_UUID && $FS_UUID != "$EXPECT_UUID" ]]; then
        die "$ROOT has UUID $FS_UUID, expected $EXPECT_UUID - wrong disk?"
    fi
    if [[ $NPARTS -eq 2 ]]; then
        STATE=fresh
    elif [[ $NPARTS -eq 3 && $(blkid -s LABEL -o value "$BOOT" 2>/dev/null) == "$BOOT_LABEL" ]]; then
        STATE=partitioned
    else
        die "unexpected partition layout on $DISK (expected 2 partitions: EFI + Ubuntu)"
    fi

    # Look inside: is this an Ubuntu-style install this script can handle?
    mkdir -p "$WORK/old"
    mount -o ro "$ROOT" "$WORK/old"
    OS_NAME=$( . "$WORK/old/etc/os-release" 2>/dev/null && echo "${PRETTY_NAME:-unknown}" || echo unknown)
    OS_HOST=$(cat "$WORK/old/etc/hostname" 2>/dev/null || echo unknown)
    OS_NAME="$OS_NAME (hostname: $OS_HOST)"
    problems=""
    [[ -d $WORK/old/boot/grub ]]            || problems+=" no /boot/grub;"
    [[ -d $WORK/old/etc/initramfs-tools ]]  || problems+=" no initramfs-tools;"
    [[ -e $WORK/old/usr/sbin/grub-install ]] || problems+=" no grub-install;"
    if [[ $STATE == fresh ]] && awk '$1 !~ /^#/ && $2=="/boot"{f=1} END{exit !f}' "$WORK/old/etc/fstab"; then
        problems+=" /etc/fstab already mounts a separate /boot;"
    fi
    umount "$WORK/old"
    [[ -z $problems ]] || die "$ROOT doesn't look like an install this script supports:$problems"
fi

if [[ $STATE == fresh ]]; then
    P2_START=$(part_sectors "$ROOT" start)
    P2_OLD=$(part_sectors "$ROOT" size)
    P2_NEW=$(( (P2_OLD - (BOOT_SIZE_MIB + 1) * MIB) / MIB * MIB ))   # MiB aligned
    P3_START=$(( P2_START + P2_NEW ))
    FS_TARGET=$(( P2_NEW * SS - HEADER_MIB * 1048576 ))
    FS_NOW=$(fs_bytes "$ROOT")
    # p2 must be the last partition
    ESP_END=$(( $(part_sectors "$ESP" start) + $(part_sectors "$ESP" size) ))
    (( ESP_END <= P2_START )) || die "$ROOT is not the last partition on $DISK"
    BLK=$(dumpe2fs -h "$ROOT" 2>/dev/null | awk -F: '/^Block size/{print $2+0}')
    FS_MIN=$(( $(resize2fs -P "$ROOT" 2>/dev/null | awk -F: '/minimum size/{print $2+0}') * BLK ))
    (( FS_MIN > 0 )) || die "could not work out how far $ROOT can shrink"
    (( FS_MIN < FS_TARGET )) ||
        die "$ROOT is too full to shrink by $(( BOOT_SIZE_MIB + HEADER_MIB )) MiB - free up some space first"
fi

echo
echo "Disk:   $DISK $(lsblk -dno MODEL "$DISK" | xargs)"
echo "System: $OS_NAME"
lsblk -o NAME,SIZE,FSTYPE,LABEL "$DISK"
echo
echo "State: $STATE"
case $STATE in
    fresh)
        echo "Plan:"
        echo "  1. check the filesystem on $ROOT"
        echo "  2. shrink it from $(( FS_NOW / 1048576 )) MiB to $(( FS_TARGET / 1048576 )) MiB"
        echo "  3. shrink $ROOT and create $BOOT ($BOOT_SIZE_MIB MiB, ext4, label $BOOT_LABEL)"
        echo "  4. copy /boot onto $BOOT"
        echo "  5. encrypt $ROOT in place with LUKS2 (you set the passphrase; roughly an hour per TB)"
        echo "  6. grow the filesystem back, set up crypttab/fstab, rebuild initramfs + GRUB" ;;
    partitioned) echo "Plan: partitions already done - copy /boot, encrypt, then set up boot" ;;
    resume)      echo "Plan: resume the interrupted encryption, then set up boot" ;;
    encrypted)   echo "Plan: encryption done - (re)do the boot setup (crypttab, fstab, initramfs, GRUB)" ;;
esac

if [[ $MODE == check ]]; then
    echo; echo "Check only - nothing changed. Run without --check to go ahead."
    exit 0
fi

on_battery && { warn "running on battery. Plug in the charger first."; (( ASSUME_YES )) || exit 1; }

if [[ $STATE == fresh || $STATE == partitioned ]] && (( ! ASSUME_YES )); then
    echo
    echo "This will encrypt $ROOT: $OS_NAME"
    echo "Have you backed up your files? A power cut during encryption can usually be"
    echo "resumed by re-running this script, but a backup is your safety net."
    read -rp "Type ENCRYPT to continue: " ans
    [[ $ans == ENCRYPT ]] || die "cancelled"
fi

mkdir -p "$WORK/old" "$WORK/new" "$WORK/esp" "$TARGET"

# ----------------------------------------------------- shrink + partition ----

if [[ $STATE == fresh ]]; then
    say "Saving a copy of the partition table to the EFI partition"
    mount "$ESP" "$WORK/esp"
    mkdir -p "$WORK/esp/fde-backup"
    sfdisk -d "$DISK" > "$WORK/esp/fde-backup/partition-table-$(date +%Y%m%d-%H%M%S).sfdisk"
    umount "$WORK/esp"

    say "Checking filesystem on $ROOT (can take a few minutes)"
    fsck_ok "$ROOT"

    say "Shrinking filesystem to $(( FS_TARGET / 1048576 )) MiB"
    if (( FS_NOW > FS_TARGET )); then
        resize2fs "$ROOT" "$(( FS_TARGET / 1024 ))K" || die "shrinking the filesystem failed"
    fi
    (( $(fs_bytes "$ROOT") <= FS_TARGET )) || die "filesystem did not shrink as expected"

    say "Shrinking partition $ROOT and creating $BOOT"
    echo "size=$P2_NEW" | sfdisk --wipe never --wipe-partitions never -N 2 "$DISK"
    echo "start=$P3_START, type=$LINUX_FS_GUID" | sfdisk --wipe never --wipe-partitions never --append "$DISK"
    partprobe "$DISK" || true
    udevadm settle
    [[ -b $BOOT ]] || die "$BOOT did not appear"
    (( $(part_sectors "$ROOT" start) == P2_START && $(part_sectors "$ROOT" size) == P2_NEW )) ||
        die "partition $ROOT does not have the expected start/size"
    umount "$BOOT" 2>/dev/null || true   # in case the desktop auto-mounted it
    mkfs.ext4 -F -q -L "$BOOT_LABEL" "$BOOT"
    STATE=partitioned
fi

if [[ $STATE == partitioned ]]; then
    # Filesystem must leave room for the LUKS header (also covers a re-run).
    P2_BYTES=$(( $(part_sectors "$ROOT" size) * SS ))
    FS_MAX=$(( P2_BYTES - HEADER_MIB * 1048576 ))
    if (( $(fs_bytes "$ROOT") > FS_MAX )); then
        fsck_ok "$ROOT"
        resize2fs "$ROOT" "$(( FS_MAX / 1024 ))K" || die "shrinking the filesystem failed"
    fi

    say "Copying /boot onto $BOOT"
    mount -o ro "$ROOT" "$WORK/old"
    mount "$BOOT" "$WORK/new"
    cp -a "$WORK/old/boot/." "$WORK/new/"
    ls "$WORK/new"/vmlinuz-* >/dev/null 2>&1 || die "no kernel found after copying /boot"
    sync
    umount "$WORK/new" "$WORK/old"

    say "Encrypting $ROOT - choose your disk passphrase (typing is invisible)"
    echo "The first prompt names a temporary 'LUKS2-temp-...' device - that's normal."
    echo "This takes a while (roughly an hour per TB). If it gets interrupted, re-run this script."
    if [[ -n $KEYFILE ]]; then
        cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size "${HEADER_MIB}M" \
            --batch-mode --key-file "$KEYFILE" "$ROOT"
    else
        # --batch-mode skips cryptsetup's own "Type 'yes'" question (you already
        # typed ENCRYPT); it still asks for the passphrase twice.
        cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size "${HEADER_MIB}M" \
            --batch-mode --verify-passphrase "$ROOT"
    fi
    STATE=encrypted
fi

if [[ $STATE == resume ]]; then
    say "Resuming encryption of $ROOT - enter your disk passphrase"
    cryptsetup reencrypt --resume-only ${KEYFILE:+--key-file "$KEYFILE"} "$ROOT"
    STATE=encrypted
fi

reencrypt_pending "$ROOT" && die "encryption not finished - re-run to resume"

# ------------------------------------------------------------ boot setup ----

[[ ! -e /dev/mapper/$MAPPER ]] || die "a device called $MAPPER is already open (not from $ROOT) - close it first"
say "Unlocking $ROOT - enter your disk passphrase"
cryptsetup open ${KEYFILE:+--key-file "$KEYFILE"} "$ROOT" "$MAPPER"
DEV=/dev/mapper/$MAPPER
FS_UUID=$(blkid -s UUID -o value "$DEV")
[[ $(blkid -s TYPE -o value "$DEV") == ext4 ]] || die "no ext4 filesystem inside $ROOT"
if [[ -n $EXPECT_UUID && $FS_UUID != "$EXPECT_UUID" ]]; then
    die "filesystem inside $ROOT has UUID $FS_UUID, expected $EXPECT_UUID"
fi

say "Growing the filesystem to fill the encrypted volume"
fsck_ok "$DEV"
resize2fs "$DEV" || die "growing the filesystem failed (data is safe; re-run to retry)"

say "Setting up crypttab and fstab"
mount "$DEV" "$TARGET"
[[ -f $TARGET/etc/fstab ]] || die "no /etc/fstab inside $ROOT"
if [[ ! -d $TARGET/boot.old ]]; then
    mv "$TARGET/boot" "$TARGET/boot.old"
    mkdir "$TARGET/boot"
fi
mount "$BOOT" "$TARGET/boot"
mkdir -p "$TARGET/boot/efi"
mount "$ESP" "$TARGET/boot/efi"

LUKS_UUID=$(blkid -s UUID -o value "$ROOT")
BOOT_UUID=$(blkid -s UUID -o value "$BOOT")
touch "$TARGET/etc/crypttab"
if ! awk -v m="$MAPPER" '$1==m{f=1} END{exit !f}' "$TARGET/etc/crypttab"; then
    # "initramfs" makes Ubuntu's initramfs hook always include this entry,
    # rather than relying on it detecting the root device from inside a chroot.
    echo "$MAPPER UUID=$LUKS_UUID none luks,discard,initramfs" >> "$TARGET/etc/crypttab"
fi
if ! awk '$1 !~ /^#/ && $2=="/boot"{f=1} END{exit !f}' "$TARGET/etc/fstab"; then
    echo "UUID=$BOOT_UUID /boot ext4 defaults 0 2" >> "$TARGET/etc/fstab"
fi
echo "crypttab:"; grep -v '^#' "$TARGET/etc/crypttab" | grep . || true
echo "fstab:";    grep -v '^#' "$TARGET/etc/fstab" | grep . || true

if (( SKIP_CHROOT )); then
    say "Skipping initramfs/GRUB (test mode)"
    exit 0
fi

say "Rebuilding initramfs and GRUB inside the installed system"
for d in dev sys proc run; do
    mount --rbind "/$d" "$TARGET/$d"
    mount --make-rslave "$TARGET/$d"
done
chroot "$TARGET" /bin/bash -euo pipefail -c '
    dpkg -s cryptsetup-initramfs >/dev/null 2>&1 || apt-get install -y cryptsetup-initramfs
    update-initramfs -u -k all
    update-grub
    grub-install --target=x86_64-efi --efi-directory=/boot/efi
'

verify_ok=1
verify_boot "$TARGET" "$FS_UUID" "$BOOT_UUID" || verify_ok=0
cp "$LOG" "$TARGET/boot.old/fde-encrypt.log" 2>/dev/null || true
(( verify_ok )) || die "boot setup has problems (see above). Your data is encrypted and safe; re-run the script to redo the boot setup, or get help with the log at $LOG"

cat <<EOF

==> Done. $ROOT is encrypted.

Next:
  1. Reboot and remove the USB stick. You'll be asked for your passphrase at startup.
  2. Once logged in, confirm the setup:
       sudo bash fde-encrypt.sh --verify
  3. Once everything works, you can delete the old copy of /boot:
       sudo rm -rf /boot.old
  4. Optional but wise: back up the LUKS header to another USB stick:
       sudo cryptsetup luksHeaderBackup $ROOT --header-backup-file luks-header.img

If it doesn't boot, start the live USB again and re-run this script - it will
redo the boot setup without touching your data.
EOF
