#!/bin/bash
# Builds kiosk.iso from scratch: a from-source 32-bit Linux kernel, a
# debootstrapped Ubuntu (i386) userland running nothing but Xorg + a
# minimal WebKitGTK kiosk browser, squashed and packaged as an El
# Torito-bootable ISO. Must run as root on an amd64 Debian/Ubuntu host
# with `dpkg --add-architecture i386` support (the multiarch i386
# packages, not a real i386 machine, are what make this possible).
#
# v86 (the in-browser x86 emulator used by web/index.html) only supports
# 32-bit x86 — there is no long-mode support — so everything here targets
# i386, not amd64, even though the host building it is amd64.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$HERE/src"
BUILD="$HERE/build"
KVER=6.8.0

mkdir -p "$BUILD"
cd "$BUILD"

log() { echo -e "\n== $* ==\n"; }

# ---------------------------------------------------------------------
# 0. Host build dependencies
# ---------------------------------------------------------------------
log "installing host build dependencies"
dpkg --add-architecture i386
apt-get update
apt-get install -y --no-install-recommends \
  build-essential libncurses-dev bison flex libssl-dev libelf-dev bc \
  gcc-multilib g++-multilib \
  debootstrap squashfs-tools isolinux syslinux-common xorriso qemu-system-x86 \
  linux-source-$KVER cpio

# ---------------------------------------------------------------------
# 1. i386 kernel: v86 emulates a Pentium-4-class 32-bit CPU with no long
#    mode, a Bochs/QEMU-style VBE VGA card, IDE/ATA CD-ROM, PS/2, and an
#    NE2000/virtio NIC. kernel.config below is a from-allnoconfig build
#    enabling exactly that hardware plus what a glibc/GTK userland needs
#    (futex, epoll, sysvipc, unix sockets, devtmpfs, overlayfs, squashfs).
#    Starting from the desktop i386_defconfig and subtracting drivers
#    was tried first and is much slower to build (it pulls in i915,
#    the full USB stack, etc.) — allnoconfig + an explicit allow-list
#    is both faster and easier to audit.
# ---------------------------------------------------------------------
if [ ! -f "$BUILD/kernel-src/Makefile" ]; then
  log "extracting kernel source"
  mkdir -p "$BUILD/kernel-src"
  tar xf "/usr/src/linux-source-$KVER.tar.bz2" -C "$BUILD/kernel-src" --strip-components=1
fi

log "building i386 kernel (bzImage)"
cd "$BUILD/kernel-src"
cp "$SRC/kernel.config" .config
yes "" | make ARCH=i386 olddefconfig
make ARCH=i386 -j"$(nproc)" bzImage
cd "$BUILD"

# ---------------------------------------------------------------------
# 2. Rootfs: debootstrap --arch=i386 gets you a working chroot even
#    though Ubuntu no longer ships a bootable i386 kernel — the *kernel*
#    above is the only truly custom part; userland packages still come
#    straight from the regular Ubuntu i386 multiarch archive.
# ---------------------------------------------------------------------
if [ ! -d "$BUILD/rootfs/usr" ]; then
  log "debootstrapping minimal i386 rootfs"
  debootstrap --arch=i386 --variant=minbase noble "$BUILD/rootfs" http://archive.ubuntu.com/ubuntu
fi

ROOTFS="$BUILD/rootfs"
cat > "$ROOTFS/etc/apt/sources.list" <<'EOF'
deb http://archive.ubuntu.com/ubuntu noble main universe
deb http://archive.ubuntu.com/ubuntu noble-updates main universe
deb http://security.ubuntu.com/ubuntu noble-security main universe
EOF
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
echo kiosk > "$ROOTFS/etc/hostname"
cat > "$ROOTFS/etc/hosts" <<'EOF'
127.0.0.1   localhost kiosk
::1         localhost ip6-localhost ip6-loopback
EOF

cleanup_chroot_mounts() {
  umount -l "$ROOTFS/dev/pts" 2>/dev/null || true
  umount -l "$ROOTFS/dev" 2>/dev/null || true
  umount -l "$ROOTFS/proc" 2>/dev/null || true
  umount -l "$ROOTFS/sys" 2>/dev/null || true
}
trap cleanup_chroot_mounts EXIT

mount --bind /dev "$ROOTFS/dev"
mount --bind /dev/pts "$ROOTFS/dev/pts"
mount -t proc proc "$ROOTFS/proc"
mount -t sysfs sysfs "$ROOTFS/sys"

log "installing packages into rootfs (Xorg core + WebKitGTK + build tools for kiosk-browser)"
chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" apt-get install -y --no-install-recommends \
  xserver-xorg-core \
  libgtk-3-0t64 libwebkit2gtk-4.1-0 \
  build-essential pkg-config libgtk-3-dev libwebkit2gtk-4.1-dev \
  udhcpc dbus-x11 fonts-dejavu-core xauth

log "building kiosk-browser (minimal fullscreen WebKitGTK shell, no chrome)"
mkdir -p "$ROOTFS/usr/local/src"
cp "$SRC/kiosk-browser.c" "$ROOTFS/usr/local/src/kiosk-browser.c"
chroot "$ROOTFS" /bin/bash -c \
  "cd /usr/local/src && gcc kiosk-browser.c -o /usr/local/bin/kiosk-browser \$(pkg-config --cflags --libs gtk+-3.0 webkit2gtk-4.1) -O2 -s -Wall"

log "shrinking rootfs: dropping build-time-only packages and docs"
chroot "$ROOTFS" apt-get purge -y build-essential gcc g++ libgtk-3-dev libwebkit2gtk-4.1-dev pkg-config
chroot "$ROOTFS" apt-get remove -y --purge systemd-sysv || true
chroot "$ROOTFS" apt-get autoremove -y --purge
chroot "$ROOTFS" apt-get clean
rm -rf "$ROOTFS"/usr/share/doc/* "$ROOTFS"/usr/share/man/* "$ROOTFS"/usr/share/locale/* \
       "$ROOTFS"/usr/share/info/* "$ROOTFS"/var/cache/apt/archives/*.deb
chroot "$ROOTFS" passwd -d root
rm -f "$ROOTFS/etc/resolv.conf"

log "installing init and kiosk homepage"
mkdir -p "$ROOTFS/usr/local/share/kiosk" "$ROOTFS/var/log" "$ROOTFS/root"
install -m 755 "$SRC/init" "$ROOTFS/sbin/init"   # overwrites the systemd symlink
install -m 644 "$SRC/welcome.html" "$ROOTFS/usr/local/share/kiosk/welcome.html"

cleanup_chroot_mounts
trap - EXIT

# ---------------------------------------------------------------------
# 3. Initramfs: a tiny busybox environment whose only job is to find the
#    boot CD, mount its squashfs, overlay a tmpfs on top for writability,
#    and switch_root into it.
# ---------------------------------------------------------------------
log "assembling initramfs"
IR="$BUILD/initramfs-root"
rm -rf "$IR"
mkdir -p "$IR"/{dev,proc,sys,mnt/cdrom,mnt/squash,mnt/overlay,newroot,bin,sbin}

BUSYBOX_DEB="$BUILD/busybox-static_i386.deb"
if [ ! -f "$BUSYBOX_DEB" ]; then
  ( cd "$BUILD" && apt-get download busybox-static:i386 )
  mv "$BUILD"/busybox-static_*_i386.deb "$BUSYBOX_DEB"
fi
dpkg-deb -x "$BUSYBOX_DEB" "$BUILD/busybox-extract"
cp "$BUILD/busybox-extract/usr/bin/busybox" "$IR/bin/busybox"
chmod +x "$IR/bin/busybox"
( cd "$IR/bin" && for a in sh mount umount switch_root mkdir mknod cat sleep basename ls ln modprobe insmod losetup blkid grep sed echo; do ln -sf busybox "$a"; done )
ln -sf ../bin/busybox "$IR/sbin/switch_root"

cat > "$IR/init" <<'INITEOF'
#!/bin/sh
# Initramfs: find the boot CD, mount its squashfs, overlay a tmpfs on top
# for writability, then switch_root into it.
export PATH=/bin:/sbin

mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null

echo "kiosk-initramfs: looking for boot media..."

CDDEV=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  for dev in /dev/sr0 /dev/sr1 /dev/hdc /dev/hda /dev/vda /dev/sda; do
    if [ -b "$dev" ]; then
      if mount -t iso9660 -o ro "$dev" /mnt/cdrom 2>/dev/null; then
        CDDEV="$dev"
        break 2
      fi
    fi
  done
  sleep 0.5
done

if [ -z "$CDDEV" ]; then
  echo "kiosk-initramfs: FATAL: no bootable ISO9660 media found" > /dev/console
  exec sh
fi

echo "kiosk-initramfs: booted from $CDDEV, mounting squashfs..."
mount -t squashfs -o loop,ro /mnt/cdrom/live/filesystem.squashfs /mnt/squash

mount -t tmpfs -o size=256M tmpfs /mnt/overlay
mkdir -p /mnt/overlay/upper /mnt/overlay/work

mount -t overlay overlay \
  -o lowerdir=/mnt/squash,upperdir=/mnt/overlay/upper,workdir=/mnt/overlay/work \
  /newroot

mkdir -p /newroot/mnt/cdrom
mount --move /mnt/cdrom /newroot/mnt/cdrom

echo "kiosk-initramfs: switching root..."
exec switch_root /newroot /sbin/init
INITEOF
chmod 755 "$IR/init"

( cd "$IR" && find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$BUILD/initramfs.img" )

# ---------------------------------------------------------------------
# 4. Squash the rootfs, build the ISO tree, package with isolinux.
# ---------------------------------------------------------------------
log "squashing rootfs"
ISO="$BUILD/iso"
mkdir -p "$ISO/isolinux" "$ISO/boot" "$ISO/live"
mksquashfs "$ROOTFS" "$ISO/live/filesystem.squashfs" -comp zstd -Xcompression-level 19 -noappend

cp /usr/lib/ISOLINUX/isolinux.bin "$ISO/isolinux/"
cp /usr/lib/syslinux/modules/bios/ldlinux.c32 "$ISO/isolinux/"
cp /usr/lib/syslinux/modules/bios/libcom32.c32 "$ISO/isolinux/"
cp /usr/lib/syslinux/modules/bios/libutil.c32 "$ISO/isolinux/"
cp /usr/lib/syslinux/modules/bios/menu.c32 "$ISO/isolinux/"
cp "$SRC/isolinux.cfg" "$ISO/isolinux/isolinux.cfg"

cp "$BUILD/kernel-src/arch/x86/boot/bzImage" "$ISO/boot/vmlinuz"
cp "$BUILD/initramfs.img" "$ISO/boot/initramfs.img"

log "building kiosk.iso"
xorriso -as mkisofs \
  -o "$BUILD/kiosk.iso" \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
  -V "KIOSKOS" \
  "$ISO"

log "done: $BUILD/kiosk.iso"
ls -la "$BUILD/kiosk.iso"
