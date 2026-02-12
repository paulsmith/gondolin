# Minimal Linux kernel for gondolin VMs.
#
# Builds a stripped-down kernel with only virtio drivers compiled in
# (CONFIG_MODULES=no). This eliminates module loading during boot and
# keeps the kernel image small (~5-10 MB), comparable to Alpine's linux-virt.
#
# Usage:
#   kernel = import ./kernel.nix { inherit pkgs lib; };
#   # kernel is a linuxPackages set; the kernel image is at:
#   #   kernel.kernel  (the kernel derivation)
#   #   kernel.kernel.dev  (for module headers, if ever needed)

{ pkgs, lib }:

let
  # Use the same major kernel version across architectures.
  # linux_6_12 is a good LTS choice; adjust as nixpkgs evolves.
  baseKernel = pkgs.linux_6_12;

  gondolinKernel = baseKernel.override {
    # --- Critical: do not auto-detect host hardware and enable drivers ---
    autoModules = false;

    # Prefer building detected requirements as built-in (y) rather than
    # loadable modules (m).  Combined with the MODULES=no below this is
    # belt-and-suspenders.
    kernelPreferBuiltin = true;

    # Suppress errors for options that vanish when subsystems are disabled.
    ignoreConfigErrors = true;

    structuredExtraConfig = with lib.kernel; {
      # =====================================================================
      # Core: disable loadable module support entirely.
      # Everything we need is compiled straight into the kernel image.
      # This shaves tens of milliseconds off boot (no modprobe, no depmod).
      # =====================================================================
      MODULES = no;

      # =====================================================================
      # Virtio transport — the only "hardware" our QEMU microvm exposes.
      # =====================================================================
      VIRTIO           = yes;
      VIRTIO_PCI       = yes;
      VIRTIO_MMIO      = yes;
      VIRTIO_BLK       = yes;
      VIRTIO_NET       = yes;
      VIRTIO_CONSOLE   = yes;
      VIRTIO_RNG       = yes;
      VIRTIO_BALLOON   = no;   # not needed for sandbox VMs

      # =====================================================================
      # Filesystems
      # =====================================================================
      EXT4_FS          = yes;
      FUSE_FS          = yes;   # sandboxfs is FUSE-based
      TMPFS            = yes;
      PROC_FS          = yes;
      SYSFS            = yes;
      DEVTMPFS         = yes;
      DEVTMPFS_MOUNT   = yes;  # auto-mount devtmpfs at /dev

      # =====================================================================
      # Networking (minimal — just enough for a single virtio-net device)
      # =====================================================================
      NET              = yes;
      INET             = yes;   # IPv4
      IPV6             = yes;
      PACKET           = yes;   # needed by udhcpc/dhcpcd
      UNIX             = yes;   # AF_UNIX sockets
      NETDEVICES       = yes;

      # =====================================================================
      # TTY / serial console
      # =====================================================================
      TTY              = yes;
      SERIAL_8250      = yes;   # ttyS0 on x86_64
      SERIAL_8250_CONSOLE = yes;
      SERIAL_AMBA_PL011 = yes;  # ttyAMA0 on aarch64
      SERIAL_AMBA_PL011_CONSOLE = yes;

      # =====================================================================
      # Pseudo-terminals (needed by sandboxd for PTY allocation)
      # =====================================================================
      UNIX98_PTYS      = yes;
      DEVPTS_FS        = yes;

      # =====================================================================
      # Misc required
      # =====================================================================
      BINFMT_ELF       = yes;
      BINFMT_SCRIPT    = yes;   # #! scripts
      INOTIFY_USER     = yes;   # file watching
      SIGNALFD         = yes;
      TIMERFD          = yes;
      EVENTFD          = yes;
      EPOLL            = yes;
      FUTEX            = yes;
      ADVISE_SYSCALLS  = yes;
      AIO              = yes;
      CGROUPS          = yes;   # useful for resource limits

      # =====================================================================
      # Disable everything we don't need
      # =====================================================================
      SOUND            = no;
      USB_SUPPORT      = no;
      WIRELESS         = no;
      WLAN             = no;
      BLUETOOTH        = no;
      NFC              = no;
      DRM              = no;
      FB               = no;
      VGA_CONSOLE      = no;
      FRAMEBUFFER_CONSOLE = no;
      INPUT_EVDEV      = no;
      HID              = no;
      I2C              = no;
      SPI              = no;
      HWMON            = no;
      THERMAL          = no;
      WATCHDOG         = no;
      MEDIA_SUPPORT    = no;
      RC_CORE          = no;
      CAN              = no;
      INFINIBAND       = no;
      ACCESSIBILITY    = no;
      PCMCIA           = no;
      ACPI_FAN         = no;
      CPU_FREQ         = no;
      # Storage controllers we'll never use
      ATA              = no;
      SCSI             = no;
      MD               = no;
      BLK_DEV_DM       = no;
      # Network protocols we don't need
      BRIDGE           = no;
      VLAN_8021Q       = no;
      NETFILTER        = no;
      IP_DCCP          = no;
      IP_SCTP          = no;
      RDS              = no;
      TIPC             = no;
      ATM              = no;
      L2TP             = no;
      DECNET           = no;
      LLC2             = no;
      LAPB             = no;
      PHONET           = no;
      IEEE802154       = no;
      CAIF             = no;
      AF_RXRPC         = no;
      AF_KCM           = no;
      NET_TEAM         = no;
      OPENVSWITCH      = no;
    };
  };

in pkgs.linuxPackagesFor gondolinKernel
