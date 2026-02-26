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
      MODULES = lib.mkForce no;

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
      VIRTIO_BALLOON   = lib.mkForce no;

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
      # Disable everything we don't need.
      #
      # Options that conflict with nixpkgs common-config.nix defaults use
      # lib.mkForce to override the base "yes"/"module" value.
      # =====================================================================
      SOUND               = lib.mkForce no;
      USB_SUPPORT         = lib.mkForce no;
      WIRELESS            = lib.mkForce no;
      WLAN                = lib.mkForce no;
      BLUETOOTH           = lib.mkForce no;
      NFC                 = lib.mkForce no;
      DRM                 = lib.mkForce no;
      FB                  = lib.mkForce no;
      VGA_CONSOLE         = lib.mkForce no;
      FRAMEBUFFER_CONSOLE = lib.mkForce no;
      INPUT_EVDEV         = lib.mkForce no;
      HID                 = lib.mkForce no;
      I2C                 = lib.mkForce no;
      SPI                 = lib.mkForce no;
      HWMON               = lib.mkForce no;
      THERMAL             = lib.mkForce no;
      WATCHDOG            = lib.mkForce no;
      MEDIA_SUPPORT       = lib.mkForce no;
      RC_CORE             = lib.mkForce no;
      CAN                 = lib.mkForce no;
      INFINIBAND          = lib.mkForce no;
      ACCESSIBILITY       = lib.mkForce no;
      PCMCIA              = lib.mkForce no;
      ACPI_FAN            = lib.mkForce no;
      CPU_FREQ            = lib.mkForce no;
      # Storage controllers we'll never use
      ATA                 = lib.mkForce no;
      SCSI                = lib.mkForce no;
      MD                  = lib.mkForce no;
      BLK_DEV_DM          = lib.mkForce no;
      # Network protocols we don't need
      BRIDGE              = lib.mkForce no;
      VLAN_8021Q          = lib.mkForce no;
      NETFILTER           = lib.mkForce no;
      IP_DCCP             = lib.mkForce no;
      IP_SCTP             = lib.mkForce no;
      RDS                 = lib.mkForce no;
      TIPC                = lib.mkForce no;
      ATM                 = lib.mkForce no;
      L2TP                = lib.mkForce no;
      DECNET              = lib.mkForce no;
      LLC2                = lib.mkForce no;
      LAPB                = lib.mkForce no;
      PHONET              = lib.mkForce no;
      IEEE802154          = lib.mkForce no;
      CAIF                = lib.mkForce no;
      AF_RXRPC            = lib.mkForce no;
      AF_KCM              = lib.mkForce no;
      NET_TEAM            = lib.mkForce no;
      OPENVSWITCH         = lib.mkForce no;
    };
  };

in pkgs.linuxPackagesFor gondolinKernel
