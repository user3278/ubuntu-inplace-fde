#!/usr/bin/env bash
# run-tests.sh - exercise fde-encrypt.sh against throwaway disk images
# attached as loop devices. Touches only the loop devices it creates.
#
#   sudo bash tests/run-tests.sh
#
# Needs: cryptsetup, sfdisk, mkfs.vfat (dosfstools), e2fsprogs, python3.
# Covers everything up to the initramfs/GRUB step, which needs a real
# Ubuntu install (FDE_SKIP_CHROOT=1 stops just before it).

set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SCRIPT=$HERE/../fde-encrypt.sh
PTY=$HERE/pty_passphrase.py
UUID=11111111-2222-3333-4444-555555555555
PASSPHRASE="correct horse battery staple"
# Own device name, so tests also work on a machine whose root is already "cryptroot".
MAPPER=fdetestroot

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
for c in cryptsetup sfdisk mkfs.vfat mkfs.ext4 losetup python3; do
    command -v $c >/dev/null || { echo "missing: $c"; exit 1; }
done

WD=$(mktemp -d "${TMPDIR:-/tmp}/fde-tests.XXXXXX")
LOOPS=()
PASSED=0
FAILED=0

cleanup() {
    umount -R "$WD/mnt" 2>/dev/null
    cryptsetup close fdetest 2>/dev/null
    cryptsetup close "$MAPPER" 2>/dev/null
    for l in "${LOOPS[@]}"; do losetup -d "$l" 2>/dev/null; done
    rm -rf "$WD"
}
trap cleanup EXIT

head -c 64 /dev/urandom > "$WD/key"
printf %s "$PASSPHRASE" > "$WD/passkey"
mkdir -p "$WD/mnt"

ok()    { echo "  PASS: $*"; PASSED=$((PASSED + 1)); }
bad()   { echo "  FAIL: $*"; FAILED=$((FAILED + 1)); }
check() { local what=$1; shift; if "$@" >/dev/null 2>&1; then ok "$what"; else bad "$what"; fi; }
section() { echo; echo "== $*"; }

# make_disk NAME SIZE_MB DATA_MB - fake disk: p1 EFI (vfat), p2 Ubuntu-like ext4
make_disk() {
    local name=$1 size=$2 data=$3 img=$WD/$1.img m=$WD/mnt
    truncate -s "${size}M" "$img"
    printf 'label: gpt\nsize=100MiB, type=U\ntype=L\n' | sfdisk -q "$img"
    DISK=$(losetup -fP --show "$img"); LOOPS+=("$DISK"); udevadm settle
    mkfs.vfat -n TESTESP "${DISK}p1" >/dev/null
    mkfs.ext4 -q -U "$UUID" "${DISK}p2"
    mount "${DISK}p2" "$m"
    mkdir -p "$m"/boot/grub "$m"/boot/efi "$m"/etc/initramfs-tools "$m"/usr/sbin "$m"/data
    echo kernel > "$m/boot/vmlinuz-6.0-test"
    echo cfg > "$m/boot/grub/grub.cfg"
    touch "$m/usr/sbin/grub-install"
    echo 'PRETTY_NAME="Test Ubuntu 24.04"' > "$m/etc/os-release"
    echo testhost > "$m/etc/hostname"
    printf 'UUID=%s / ext4 defaults 0 1\n' "$UUID" > "$m/etc/fstab"
    if (( data > 0 )); then dd if=/dev/urandom of="$m/data/blob" bs=1M count="$data" status=none; fi
    for i in $(seq 1 20); do head -c $((RANDOM * 8)) /dev/urandom > "$m/data/f$i"; done
    (cd "$m" && find data boot -type f -exec sha256sum {} +) > "$WD/$name.sums"
    umount "$m"
}

# Run the script non-interactively against $DISK (key file instead of typing).
run() {
    env FDE_SKIP_CHROOT=1 FDE_YES=1 FDE_BOOT_SIZE_MIB=512 FDE_MAPPER=$MAPPER FDE_KEYFILE="${KEY:-$WD/key}" \
        bash "$SCRIPT" --disk "$DISK" "$@"
}

# With the encrypted root open and mounted at $WD/mnt, run "$@" then close it.
with_open_root() {
    local keyfile=$1 r=0; shift
    cryptsetup open --key-file "$keyfile" "${DISK}p2" fdetest || return 1
    mount -o ro /dev/mapper/fdetest "$WD/mnt" || { cryptsetup close fdetest; return 1; }
    "$@" || r=1
    umount "$WD/mnt"; cryptsetup close fdetest
    return $r
}

# Every file still matches (boot files now live in /boot.old).
data_matches() { (cd "$WD/mnt" && sed 's#  boot/#  boot.old/#' "$WD/$1.sums" | sha256sum -c --quiet); }
one_crypttab_line() { [[ $(grep -c "^$MAPPER " "$WD/mnt/etc/crypttab") == 1 ]]; }
one_boot_line() { [[ $(awk '$2=="/boot"' "$WD/mnt/etc/fstab" | wc -l) == 1 ]]; }

# ---------------------------------------------------------------------------
section "Fresh run (key file)"
make_disk t1 3072 400
run --check > "$WD/t1-check.log" 2>&1
check "--check shows the system it found" grep -q "Test Ubuntu 24.04 (hostname: testhost)" "$WD/t1-check.log"
check "--check reports State: fresh" grep -q "State: fresh" "$WD/t1-check.log"
check "--check changes nothing" test "$(blkid -s TYPE -o value "${DISK}p2")" = ext4
check "full run succeeds" run
check "root partition is LUKS2" cryptsetup isLuks --type luks2 "${DISK}p2"
check "new /boot partition exists" test "$(blkid -s LABEL -o value "${DISK}p3")" = FDEBOOT
check "partition table backup saved on EFI partition" bash -c "mount -o ro ${DISK}p1 $WD/mnt && ls $WD/mnt/fde-backup/*.sfdisk; r=\$?; umount $WD/mnt; exit \$r"
check "all files intact" with_open_root "$WD/key" data_matches t1
check "crypttab entry has the initramfs option" with_open_root "$WD/key" grep -q "^$MAPPER UUID=.* luks,discard,initramfs" "$WD/mnt/etc/crypttab"
check "fstab mounts the new /boot" with_open_root "$WD/key" grep -q " /boot ext4 " "$WD/mnt/etc/fstab"
run --check > "$WD/t1-check2.log" 2>&1
check "re-check reports State: encrypted" grep -q "State: encrypted" "$WD/t1-check2.log"
check "re-run on encrypted disk succeeds" run
check "re-run adds no duplicate crypttab line" with_open_root "$WD/key" one_crypttab_line
check "re-run adds no duplicate /boot line" with_open_root "$WD/key" one_boot_line

# ---------------------------------------------------------------------------
section "Typing the passphrase at a terminal"
make_disk t2 3072 200
python3 -I "$PTY" "$PASSPHRASE" -- env FDE_SKIP_CHROOT=1 FDE_YES=1 FDE_BOOT_SIZE_MIB=512 FDE_MAPPER=$MAPPER \
    bash "$SCRIPT" --disk "$DISK" > "$WD/t2.log" 2>&1
check "interactive run succeeds (no unanswered questions)" test $? -eq 0
check "asked for the passphrase 3 times (set, verify, unlock)" grep -q "answered 3 passphrase" "$WD/t2.log"
check "never shows cryptsetup's 'Type yes' question" bash -c "! grep -q 'Are you sure' $WD/t2.log"
check "the typed passphrase unlocks the disk" cryptsetup open --test-passphrase --key-file "$WD/passkey" "${DISK}p2"
check "a wrong passphrase does not" bash -c "! printf wrong | cryptsetup open --test-passphrase --key-file - ${DISK}p2"
check "all files intact" with_open_root "$WD/passkey" data_matches t2

# ---------------------------------------------------------------------------
section "Interrupted, then resumed"
make_disk t3 3072 400
KEY=/nonexistent run > "$WD/t3a.log" 2>&1
check "run stopped at the encryption step" grep -q "Failed to open key file" "$WD/t3a.log"
run --check > "$WD/t3b.log" 2>&1
check "re-check reports State: partitioned" grep -q "State: partitioned" "$WD/t3b.log"
# Start encryption but stop right after it begins (as after a crash).
cryptsetup reencrypt --encrypt --type luks2 --reduce-device-size 32M --init-only \
    --batch-mode --key-file "$WD/key" "${DISK}p2" >/dev/null 2>&1
run --check > "$WD/t3c.log" 2>&1
check "half-finished encryption reports State: resume" grep -q "State: resume" "$WD/t3c.log"
check "resumed run succeeds" run
check "all files intact" with_open_root "$WD/key" data_matches t3

# ---------------------------------------------------------------------------
section "Refusals (nothing should change)"
make_disk t4 1024 820
run > "$WD/t4a.log" 2>&1
check "too-full disk is refused" grep -q "too full to shrink" "$WD/t4a.log"
run --uuid 00000000-0000-0000-0000-000000000000 > "$WD/t4b.log" 2>&1
check "wrong --uuid is refused" grep -q "wrong disk?" "$WD/t4b.log"
bash "$SCRIPT" --disk "${DISK}p2" --check > "$WD/t4c.log" 2>&1
check "a partition given as --disk is refused" grep -q "not a whole disk" "$WD/t4c.log"
mount -o ro "${DISK}p1" "$WD/mnt"
run --check > "$WD/t4d.log" 2>&1
umount "$WD/mnt"
check "a mounted disk is refused" grep -q "something on .* is mounted" "$WD/t4d.log"
check "disk still has 2 partitions" test "$(lsblk -nro TYPE "$DISK" | grep -c part)" = 2
check "root is still plain ext4" test "$(blkid -s TYPE -o value "${DISK}p2")" = ext4
check "all files intact" bash -c "mount -o ro ${DISK}p2 $WD/mnt && (cd $WD/mnt && sha256sum -c --quiet $WD/t4.sums); r=\$?; umount $WD/mnt; exit \$r"

# ---------------------------------------------------------------------------
echo
echo "$PASSED passed, $FAILED failed"
(( FAILED == 0 ))
