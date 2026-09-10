# Kiosk OS

A from-scratch Linux distro that boots straight into a fullscreen browser
and runs nothing else — no desktop, no window manager chrome, no other
applications. Built specifically to be small enough to run entirely
inside a browser tab via [v86](https://github.com/copy/v86), a
WebAssembly x86 emulator (see `../web/index.html`).

## Why not literal Google Chrome?

v86 emulates the CPU in JavaScript/WebAssembly with no hardware
virtualization, and real Chromium (hundreds of MB, a JIT-compiling V8
engine, GPU/sandbox syscalls) is not practical to run under that kind of
emulation. Instead the guest runs a **~50-line WebKitGTK shell**
(`src/kiosk-browser.c`) — a real, modern, JavaScript/CSS3-capable engine
(the same family Safari and GNOME Web use), just without Chromium's
weight. It's a genuine graphical browser, fullscreen, no navigation bar,
no other windows — a kiosk in the literal sense.

## Why a custom-built kernel?

v86 only supports 32-bit x86 (no long mode), and modern Ubuntu no longer
ships a bootable i386 *kernel* (only i386 userland packages, for
Wine/Steam multiarch). So `build.sh` compiles its own i386 kernel from
Ubuntu's kernel source package, configured from `allnoconfig` up with
only what v86's emulated hardware and a glibc/GTK userland need — see
`src/kernel.config`. Starting from the desktop-oriented `i386_defconfig`
and disabling things was tried first; it happily builds i915, the full
USB stack, sound, etc., which is both slow to build and pointless weight
on a kiosk. Allow-listing from nothing is slower to write but much
smaller and faster to build.

## Layout

```
kiosk-os/
  build.sh              # reproducible build: kernel -> rootfs -> squashfs -> ISO
  src/
    kernel.config        # validated i386 kernel config (from allnoconfig)
    kiosk-browser.c       # the entire "browser" — GTK window + WebKitWebView
    init                   # PID 1: udev, DHCP, then supervise Xorg + kiosk-browser
    welcome.html            # default homepage baked into the image
    isolinux.cfg             # BIOS/El Torito boot menu
  build/                # gitignored — everything build.sh generates, including kiosk.iso
```

## Building

Run as root on an amd64 Debian/Ubuntu host with network access to
`archive.ubuntu.com` (multiarch i386 packages, no separate i386 machine
needed):

```
sudo ./kiosk-os/build.sh
```

Output: `kiosk-os/build/kiosk.iso` (~270 MB — WebKitGTK is the bulk of
it; that's the real cost of a genuine modern rendering engine over a
text browser). It is **not** committed to git — too large and it's a
build artifact, not source.

## Boot flow

1. isolinux boots `boot/vmlinuz` with `boot/initramfs.img`.
2. The initramfs (`build.sh`'s embedded busybox init) finds the CD,
   mounts `live/filesystem.squashfs`, layers a tmpfs overlay on top for
   writability, and `switch_root`s into it.
3. `/sbin/init` (`src/init`) brings up udev, DHCP on any NIC, then loops
   forever: start Xorg (the `modesetting` driver against the kernel's
   `bochs-drm` KMS device — matches v86's/QEMU's emulated Bochs VBE VGA
   card), wait for its socket, launch `kiosk-browser` fullscreen, and
   restart the pair if the browser ever exits.
4. Pass `kiosk.home=<url>` on the kernel command line to point it
   somewhere other than the bundled welcome page. Pass `kiosk.debug` to
   also get a root shell on `ttyS0`/tty2 (password-less — this image is
   built for throwaway testing, not production deployment as-is).

## Networking

The guest DHCPs normally and has a real NE2000/virtio NIC. Whether that
reaches the actual internet depends entirely on how it's run:

- **Under real QEMU**: `-netdev user` gives it NAT'd internet access
  like any VM. Works out of the box.
- **Under v86 in a browser tab**: a browser sandbox has no raw sockets,
  so v86's virtual NIC only reaches the outside world if you run a
  [network relay](https://github.com/copy/v86/blob/master/docs/networking.md)
  server and point the emulator at it (`web/index.html` has a field for
  this). Without one, the guest still boots, DHCPs, and browses any
  page baked into the image or reachable via `file://` — it just has
  nowhere to route real HTTP traffic. This is inherent to running any
  full TCP/IP stack inside a browser tab, not specific to this OS.

## Verified

Boots and reaches a running `kiosk-browser` (X + WebKitGTK, DHCP lease
obtained, `bochs-drm` KMS framebuffer bound) in plain `qemu-system-i386`
with `-m 1024`. Not yet re-verified inside v86 itself in this session —
same CPU/hardware profile v86 emulates, so it's expected to behave the
same, but do check `web/index.html`'s serial console panel on first
boot.
