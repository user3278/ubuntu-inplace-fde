# Ubuntu in-place full disk encryption

Add full disk encryption (LUKS2) to an Ubuntu install that's already set up,
**without reinstalling and without losing data**. One script, run from an
Ubuntu live USB, does the whole job and can pick up where it left off if
it's interrupted.

```
Before                               After
nvme0n1                              nvme0n1
├─p1  EFI   (vfat)                   ├─p1  EFI   (vfat)                  unchanged
└─p2  /     (ext4)                   ├─p2  LUKS2 ─ cryptroot ─ / (ext4)  same data, now encrypted
                                     └─p3  /boot (ext4, 2 GiB)           new, unencrypted
```

You type a passphrase at every startup. Everything on the root partition is
encrypted: your files, `/tmp`, logs, and the swap file.

## Will it work on my machine?

The script expects the layout a default, unencrypted Ubuntu install creates:

| Requirement | How to check (on the installed system) |
|---|---|
| Ubuntu (tested on 24.04), booting in **UEFI** mode | `[ -d /sys/firmware/efi ] && echo UEFI` |
| Exactly **2 partitions**: 1 = EFI (vfat), 2 = `/` (ext4), with `/` last on the disk | `lsblk -o NAME,FSTYPE,MOUNTPOINTS` |
| `/boot` is a folder on `/`, not its own partition | `findmnt /boot` prints nothing |
| A few GB free on `/` | `df -h /` |

It refuses to run, without changing anything, if it finds something else: LVM,
btrfs, a separate `/home` or swap partition, a dual-boot layout, a
legacy-BIOS boot, or a disk too full to shrink. Run `--check` first to see
what it finds.

## Before you start

- **Back up anything important.** The script has been tested hard and
  handles interruptions, but a backup is the real safety net.
- **Pick a passphrase you won't forget.** Several random words work well.
  If you lose it, your data can't be recovered.
- **Keyboard layout:** in the live session, pick the same layout your
  installed system uses. Otherwise symbols in your passphrase may come out
  as different characters at the startup prompt.
- **Plug in the power.** Encryption takes roughly an hour per TB.

## Steps

### 1. On the installed system: note your disk

```bash
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINTS   # the disk holding "/", e.g. nvme0n1 -> /dev/nvme0n1
findmnt -no UUID /                      # optional: pass this as --uuid for an extra safety check
```

Optional, so the live session doesn't need internet:
`sudo apt install cryptsetup-initramfs`

### 2. Make an Ubuntu live USB

Use the same Ubuntu version as your install. Either use Startup Disk Creator
or balenaEtcher, or `dd` (this **erases the stick**, so check the device
name with `lsblk` first):

```bash
sudo dd if=ubuntu-24.04.x-desktop-amd64.iso of=/dev/sdX bs=4M status=progress conv=fsync
```

### 3. Boot the USB

Restart, open the firmware boot menu (often F12, F11, F8 or Esc), and pick
the stick's **UEFI** entry. Choose "Try or Install Ubuntu", then **Try Ubuntu**,
and close the installer window. **Don't click Install.**

### 4. Get the script into the live session

The easiest way is to copy it off your own disk. Open a Terminal (Ctrl+Alt+T):

```bash
sudo mount -o ro /dev/nvme0n1p2 /mnt                 # your root partition
cp /mnt/path/to/fde-encrypt.sh ~/Desktop/            # wherever you saved it
sudo umount /mnt
```

If you open the disk in the Files app instead, **click eject next to it
afterwards**. The script won't run while anything on the disk is mounted.

A second USB stick works too. Don't count on putting files on the live USB
itself: Ubuntu 24.04 uses the stick's spare space for installer logs and
hides it in the live session.

### 5. Dry run (changes nothing)

```bash
sudo bash ~/Desktop/fde-encrypt.sh --disk /dev/nvme0n1 --check
```

It shows the disk, the Ubuntu install it found (version and hostname), and
the plan. You should see `State: fresh`. If it prints `ERROR`, stop and read
the message.

### 6. The real run

```bash
sudo bash ~/Desktop/fde-encrypt.sh --disk /dev/nvme0n1
```

1. Type `ENCRYPT` to confirm.
2. A few minutes: it checks the filesystem, shrinks it, and creates the
   `/boot` partition.
3. **Choose your passphrase**, typed twice. The first prompt names a
   temporary device, `Enter passphrase for LUKS2-temp-….new`. That's normal.
   Nothing shows while you type.
4. Roughly an hour per TB while it encrypts. Leave the Terminal open; the
   script keeps the computer awake.
5. **Enter the passphrase once more** to unlock the disk and finish setup.
6. A couple of minutes: it rebuilds the initramfs and GRUB inside your
   install, then verifies them.

It's finished when it prints `Done` after a list of `ok:` lines.

### 7. Reboot

Restart and remove the USB stick. Enter your passphrase at the prompt, and
your normal desktop loads. Then:

```bash
sudo bash fde-encrypt.sh --verify      # confirms the boot setup
sudo rm -rf /boot.old                  # once you're happy: the old copy of /boot
sudo cryptsetup luksHeaderBackup /dev/nvme0n1p2 --header-backup-file luks-header.img
```

Keep the header backup on another USB stick, not on the encrypted disk.
If the header gets damaged, it's the only way back in.

## If something goes wrong

- **It stops with an error, or gets interrupted** (Ctrl+C, crash, power cut):
  boot the USB again and run the same command. It works out how far it got
  and carries on.
- **It won't boot afterwards:** boot the USB and run the same command. On an
  already-encrypted disk it only redoes the boot setup (crypttab, fstab,
  initramfs, GRUB) and doesn't touch your data.
- **Logs:** `/tmp/fde-encrypt.log` in the live session. A copy is saved to
  `/boot.old/fde-encrypt.log` at the end.

## How it works

| Stage | What happens |
|---|---|
| Checks | Refuses if the disk is in use, the layout is unexpected, it's too full, or (with `--uuid`) the filesystem ID doesn't match. Shows which install it found. |
| Partition | Saves a copy of the partition table in `fde-backup/` on the EFI partition, runs `e2fsck`, shrinks the ext4 filesystem, shrinks partition 2, and adds partition 3 for `/boot`. |
| Copy `/boot` | Copies the kernels, initramfs and GRUB files to the new partition. |
| Encrypt | `cryptsetup reencrypt --encrypt --reduce-device-size 32M`: encrypts in place, shifting data to make room for the 16 MiB LUKS2 header. Progress is saved in the header, so it can resume. |
| Boot setup | Grows the filesystem back, moves the old `/boot` to `/boot.old`, adds the crypttab and fstab entries, then (in a chroot) runs `update-initramfs`, `update-grub` and `grub-install`, and verifies the result. |

The filesystem keeps its UUID, so the existing `/` line in `/etc/fstab`
stays valid. Every stage is detected from the disk's state (`fresh`,
`partitioned`, `resume`, `encrypted`), which is why re-running is safe.

**Why a separate `/boot`?** GRUB 2.12 can't unlock LUKS2 volumes that use
argon2id, the strongest key derivation and cryptsetup's default. Keeping
`/boot` outside the encrypted volume means GRUB never has to: the
initramfs asks for the passphrase. You type it once, and the key derivation
stays strong.

### Security notes

- `/boot` (kernel and initramfs) is **not encrypted**, so someone with
  physical access could tamper with it. Secure Boot reduces that risk.
- The crypttab line uses `discard` (TRIM) for SSD performance. This reveals
  which blocks are unused, not what's in them. Remove `discard` if that
  matters to you.
- The script's options are `--disk`, `--check`, `--uuid`, `--boot-size`
  (default 2048 MiB) and `--verify`. Run with `--help` for details.

## Testing

```bash
sudo bash tests/run-tests.sh
```

This builds throwaway disk images, attaches them as loop devices, and runs
the script against them: a fresh run, typing the passphrase at a terminal,
an interrupted then resumed encryption, re-running on a finished disk, and
every refusal (too full, wrong UUID, partition instead of disk, mounted
disk). It checks every file survives byte for byte. It touches nothing but
its own loop devices.

The final initramfs/GRUB stage needs a real Ubuntu install, so the tests stop
just before it. Use `--verify` on the rebooted system to check that stage.
