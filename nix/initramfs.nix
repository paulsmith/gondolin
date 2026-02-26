# Minimal initramfs for gondolin VMs.
#
# Contains only busybox (for mount, switch_root, sh) and a tiny init script.
# With CONFIG_MODULES=no in our kernel, there is no module loading at all —
# virtio_blk and ext4 are compiled in, so /dev/vda appears immediately.
#
# Compressed with LZ4 for fastest decompression.
#
# Usage:
#   initramfs = import ./initramfs.nix { inherit pkgs lib; };
#   # The cpio.lz4 archive is at: ${initramfs}/initrd

{ pkgs, lib }:

let
  # Use a statically-linked busybox so the initramfs has zero shared-lib deps.
  busybox = pkgs.busybox.override {
    enableStatic = true;
  };

  # The initramfs init script.  This is a simplified version of
  # guest/image/initramfs-init that drops modprobe calls (drivers are built
  # into the kernel) and the wait-for-block loop (virtio_blk is built-in so
  # /dev/vda is present from the start).
  initScript = pkgs.writeScript "initramfs-init" ''
    #!/bin/sh
    set -eu

    CONSOLE="/dev/console"
    if [ ! -c "''${CONSOLE}" ]; then
      if [ -c /dev/ttyAMA0 ]; then
        CONSOLE="/dev/ttyAMA0"
      elif [ -c /dev/ttyS0 ]; then
        CONSOLE="/dev/ttyS0"
      else
        CONSOLE=""
      fi
    fi

    log() {
      if [ -n "''${CONSOLE}" ]; then
        printf "%s\n" "$*" > "''${CONSOLE}" 2>/dev/null || printf "%s\n" "$*"
      else
        printf "%s\n" "$*"
      fi
    }

    mount -t proc proc /proc || log "[initramfs] mount proc failed"
    mount -t sysfs sysfs /sys || log "[initramfs] mount sysfs failed"
    mount -t devtmpfs devtmpfs /dev || log "[initramfs] mount devtmpfs failed"

    mkdir -p /dev/pts /dev/shm /run
    mount -t devpts devpts /dev/pts || log "[initramfs] mount devpts failed"
    mount -t tmpfs tmpfs /run || log "[initramfs] mount tmpfs failed"

    export PATH=/bin

    # Parse kernel cmdline for root= and rootfstype=
    root_device="/dev/vda"
    root_fstype="ext4"

    if [ -r /proc/cmdline ]; then
      for arg in $(cat /proc/cmdline); do
        case "''${arg}" in
          root=*)
            root_device="''${arg#root=}"
            ;;
          rootfstype=*)
            root_fstype="''${arg#rootfstype=}"
            ;;
        esac
      done
    fi

    # With built-in virtio_blk the device should already exist, but keep a
    # short poll loop as a safety net.
    wait_for_block() {
      dev="$1"
      for i in $(seq 1 20); do
        if [ -b "''${dev}" ]; then
          return 0
        fi
        sleep 0.05
      done
      return 1
    }

    if ! wait_for_block "''${root_device}"; then
      log "[initramfs] root device ''${root_device} not found"
      exec sh
    fi

    mkdir -p /newroot
    if ! mount -t "''${root_fstype}" "''${root_device}" /newroot; then
      log "[initramfs] failed to mount ''${root_device}"
      exec sh
    fi

    mkdir -p /newroot/proc /newroot/sys /newroot/dev /newroot/run

    exec switch_root /newroot /init
  '';

in pkgs.makeInitrdNG {
  contents = [
    { source = initScript;           target = "/init"; }
    { source = "${busybox}/bin/busybox"; target = "/bin/busybox"; }

    # Create essential busybox symlinks so the init script can call them
    # without PATH gymnastics.  switch_root and mount are the critical ones.
  ] ++ map (cmd: {
    source = "${busybox}/bin/busybox";
    target = "/bin/${cmd}";
  }) [
    "sh"
    "mount"
    "umount"
    "switch_root"
    "mkdir"
    "cat"
    "printf"
    "sleep"
    "seq"
    "ls"
    "test"
  ];

  compressor = "lz4 -l";
}
