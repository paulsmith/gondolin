# ext4 rootfs image for gondolin VMs.
#
# Produces a raw ext4 image containing:
#   - Nix store closure of all required packages
#   - FHS-compatible symlinks under /usr/bin, /bin, /sbin
#   - gondolin guest binaries (sandboxd, sandboxfs, sandboxssh, sandboxingress)
#   - The rootfs init script as /init (PID 1)
#   - SSL certificates, basic /etc files
#
# The image is auto-sized to fit its contents.  It is mounted read-write by
# the initramfs and used as the root filesystem for the VM.
#
# Usage:
#   rootfs = import ./rootfs.nix { inherit pkgs lib; guestBinaries = ...; };
#   # The ext4 image file is the derivation output itself.

{ pkgs, lib, guestBinaries }:

let
  # The rootfs init script — identical to guest/image/init.
  # We install it at /init (PID 1).  Paths like /usr/bin/sandboxd are
  # provided via symlinks created in populateImageCommands below.
  initScript = pkgs.writeScript "gondolin-init" ''
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

    log_cmd() {
      if [ -n "''${CONSOLE}" ]; then
        "$@" > "''${CONSOLE}" 2>&1 || "$@" || true
      else
        "$@" || true
      fi
    }

    mount -t proc proc /proc || log "[init] mount proc failed"
    mount -t sysfs sysfs /sys || log "[init] mount sysfs failed"
    mount -t devtmpfs devtmpfs /dev || log "[init] mount devtmpfs failed"

    mkdir -p /dev/pts /dev/shm /run
    mount -t devpts devpts /dev/pts || log "[init] mount devpts failed"
    mount -t tmpfs tmpfs /run || log "[init] mount tmpfs failed"

    export PATH=/usr/sbin:/usr/bin:/sbin:/bin

    mkdir -p /tmp /var/tmp /var/cache /var/log /root /home
    mount -t tmpfs tmpfs /tmp || log "[init] mount tmpfs /tmp failed"
    mount -t tmpfs tmpfs /root || log "[init] mount tmpfs /root failed"
    chmod 700 /root || true
    mount -t tmpfs tmpfs /var/tmp || log "[init] mount tmpfs /var/tmp failed"
    mount -t tmpfs tmpfs /var/cache || log "[init] mount tmpfs /var/cache failed"
    mount -t tmpfs tmpfs /var/log || log "[init] mount tmpfs /var/log failed"

    mkdir -p /tmp/.cache /tmp/.config /tmp/.local/share

    export HOME=/root
    export TMPDIR=/tmp
    export XDG_CACHE_HOME=/tmp/.cache
    export XDG_CONFIG_HOME=/tmp/.config
    export XDG_DATA_HOME=/tmp/.local/share
    export UV_CACHE_DIR=/tmp/.cache/uv
    export SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
    export UV_NATIVE_TLS=true

    log "[init] /dev entries:"
    log_cmd ls -l /dev
    if [ -d /dev/virtio-ports ]; then
      log "[init] /dev/virtio-ports:"
      log_cmd ls -l /dev/virtio-ports
    else
      log "[init] /dev/virtio-ports missing"
    fi
    if [ -d /sys/class/virtio-ports ]; then
      log "[init] /sys/class/virtio-ports:"
      log_cmd ls -l /sys/class/virtio-ports
    else
      log "[init] /sys/class/virtio-ports missing"
    fi

    # With CONFIG_MODULES=no these are no-ops but harmless.
    modprobe virtio_console > /dev/null 2>&1 || true
    modprobe virtio_rng > /dev/null 2>&1 || true

    if [ -e /dev/hwrng ]; then
      log "[init] starting rngd"
      rngd -r /dev/hwrng -o /dev/random > /dev/null 2>&1 &
    else
      log "[init] /dev/hwrng missing"
    fi

    # With built-in virtio_net this is also a no-op.
    modprobe virtio_net > /dev/null 2>&1 || true

    if command -v ip > /dev/null 2>&1; then
      ip link set lo up || true
      ip link set eth0 up || true
    else
      ifconfig lo up || true
      ifconfig eth0 up || true
    fi

    if command -v udhcpc > /dev/null 2>&1; then
      UDHCPC_SCRIPT="/usr/share/udhcpc/default.script"
      if [ ! -x "''${UDHCPC_SCRIPT}" ]; then
        UDHCPC_SCRIPT="/sbin/udhcpc.script"
      fi
      if [ -x "''${UDHCPC_SCRIPT}" ]; then
        udhcpc -i eth0 -q -n -s "''${UDHCPC_SCRIPT}" || log "[init] udhcpc failed"
      else
        udhcpc -i eth0 -q -n || log "[init] udhcpc failed"
      fi
    fi

    # With built-in FUSE this is a no-op.
    modprobe fuse > /dev/null 2>&1 || true

    sandboxfs_mount="/data"
    sandboxfs_binds=""

    if [ -r /proc/cmdline ]; then
      for arg in $(cat /proc/cmdline); do
        case "''${arg}" in
          sandboxfs.mount=*)
            sandboxfs_mount="''${arg#sandboxfs.mount=}"
            ;;
          sandboxfs.bind=*)
            sandboxfs_binds="''${arg#sandboxfs.bind=}"
            ;;
        esac
      done
    fi

    wait_for_sandboxfs() {
      for i in $(seq 1 300); do
        if grep -q " ''${sandboxfs_mount} fuse.sandboxfs " /proc/mounts; then
          return 0
        fi
        sleep 0.1
      done
      return 1
    }

    mkdir -p "''${sandboxfs_mount}"

    sandboxfs_ready=0
    sandboxfs_error="sandboxfs mount not ready"

    if [ -x /usr/bin/sandboxfs ]; then
      log "[init] starting sandboxfs at ''${sandboxfs_mount}"
      SANDBOXFS_LOG="''${CONSOLE:-/dev/null}"
      if [ -z "''${SANDBOXFS_LOG}" ]; then
        SANDBOXFS_LOG="/dev/null"
      fi
      /usr/bin/sandboxfs --mount "''${sandboxfs_mount}" --rpc-path /dev/virtio-ports/virtio-fs > "''${SANDBOXFS_LOG}" 2>&1 &

      if wait_for_sandboxfs; then
        sandboxfs_ready=1
        if [ -n "''${sandboxfs_binds}" ]; then
          OLD_IFS="''${IFS}"
          IFS=","
          for bind in ''${sandboxfs_binds}; do
            if [ -z "''${bind}" ]; then
              continue
            fi
            mkdir -p "''${bind}"
            if [ "''${sandboxfs_mount}" = "/" ]; then
              bind_source="''${bind}"
            else
              bind_source="''${sandboxfs_mount}''${bind}"
            fi
            log "[init] binding sandboxfs ''${bind_source} -> ''${bind}"
            log_cmd mount --bind "''${bind_source}" "''${bind}"
          done
          IFS="''${OLD_IFS}"
        fi
      else
        log "[init] sandboxfs mount not ready"
      fi
    else
      log "[init] /usr/bin/sandboxfs missing"
      sandboxfs_error="sandboxfs binary missing"
    fi

    if [ "''${sandboxfs_ready}" -eq 1 ]; then
      printf "ok\n" > /run/sandboxfs.ready
    else
      printf "%s\n" "''${sandboxfs_error}" > /run/sandboxfs.failed
    fi

    if [ -x /usr/bin/sandboxssh ]; then
      log "[init] starting sandboxssh"
      /usr/bin/sandboxssh > "''${CONSOLE:-/dev/null}" 2>&1 &
    else
      log "[init] /usr/bin/sandboxssh missing"
    fi

    if [ -x /usr/bin/sandboxingress ]; then
      log "[init] starting sandboxingress"
      /usr/bin/sandboxingress > "''${CONSOLE:-/dev/null}" 2>&1 &
    else
      log "[init] /usr/bin/sandboxingress missing"
    fi

    log "[init] starting sandboxd"

    exec /usr/bin/sandboxd
  '';

  # busybox provides coreutils, networking (udhcpc, ip, ifconfig), grep, etc.
  busybox = pkgs.busybox.override {
    enableStatic = true;
    extraConfig = ''
      CONFIG_FEATURE_PREFER_APPLETS y
      CONFIG_MODPROBE_SMALL y
    '';
  };

  # udhcpc needs a default.script to configure the interface.
  udhcpcScript = pkgs.writeScript "udhcpc-default.script" ''
    #!/bin/sh
    case "''${1}" in
      deconfig)
        ip addr flush dev "''${interface}" 2>/dev/null || true
        ;;
      renew|bound)
        ip addr add "''${ip}/''${mask}" dev "''${interface}" 2>/dev/null || \
          ifconfig "''${interface}" "''${ip}" netmask "''${mask}" 2>/dev/null || true
        if [ -n "''${router:-}" ]; then
          ip route add default via "''${router}" dev "''${interface}" 2>/dev/null || \
            route add default gw "''${router}" dev "''${interface}" 2>/dev/null || true
        fi
        if [ -n "''${dns:-}" ]; then
          : > /etc/resolv.conf
          for ns in ''${dns}; do
            echo "nameserver ''${ns}" >> /etc/resolv.conf
          done
        fi
        ;;
    esac
  '';

in import "${pkgs.path}/nixos/lib/make-ext4-fs.nix" {
  inherit pkgs lib;

  # All packages whose closures should be included in the image.
  storePaths = [
    busybox
    pkgs.bash
    pkgs.nodejs
    pkgs.python3
    pkgs.curl
    pkgs.openssh
    pkgs.cacert
    pkgs.uv
    pkgs.rng-tools
    pkgs.iproute2
    guestBinaries
    initScript
    udhcpcScript
  ];

  volumeLabel = "gondolin-root";

  populateImageCommands = ''
    # --- Directory skeleton ---
    mkdir -p ./files/{bin,sbin,usr/bin,usr/sbin,usr/share/udhcpc}
    mkdir -p ./files/{etc/ssl/certs,proc,sys,dev,run,tmp,var,root,home,data}
    mkdir -p ./files/{var/tmp,var/cache,var/log}

    # --- /init (PID 1) ---
    cp ${initScript} ./files/init
    chmod 755 ./files/init

    # --- gondolin guest binaries at /usr/bin ---
    ln -sf ${guestBinaries}/bin/sandboxd      ./files/usr/bin/sandboxd
    ln -sf ${guestBinaries}/bin/sandboxfs     ./files/usr/bin/sandboxfs
    ln -sf ${guestBinaries}/bin/sandboxssh    ./files/usr/bin/sandboxssh
    ln -sf ${guestBinaries}/bin/sandboxingress ./files/usr/bin/sandboxingress

    # --- busybox symlinks for /bin and /sbin ---
    # The init script expects coreutils, mount, etc. on PATH.
    for applet in $(${busybox}/bin/busybox --list); do
      # Put networking tools in /sbin, everything else in /bin
      case "$applet" in
        ifconfig|route|ip|udhcpc|modprobe|insmod|rmmod)
          ln -sf ${busybox}/bin/busybox "./files/sbin/$applet"
          ;;
        *)
          ln -sf ${busybox}/bin/busybox "./files/bin/$applet"
          ;;
      esac
    done

    # --- Runtime packages at /usr/bin ---
    ln -sf ${pkgs.bash}/bin/bash             ./files/usr/bin/bash
    ln -sf ${pkgs.nodejs}/bin/node           ./files/usr/bin/node
    ln -sf ${pkgs.nodejs}/bin/npm            ./files/usr/bin/npm
    ln -sf ${pkgs.python3}/bin/python3       ./files/usr/bin/python3
    ln -sf ${pkgs.python3}/bin/python3       ./files/usr/bin/python
    ln -sf ${pkgs.curl}/bin/curl             ./files/usr/bin/curl
    ln -sf ${pkgs.openssh}/bin/ssh           ./files/usr/bin/ssh
    ln -sf ${pkgs.openssh}/bin/sshd          ./files/usr/sbin/sshd
    ln -sf ${pkgs.openssh}/bin/ssh-keygen    ./files/usr/bin/ssh-keygen
    ln -sf ${pkgs.uv}/bin/uv                 ./files/usr/bin/uv
    ln -sf ${pkgs.rng-tools}/bin/rngd        ./files/usr/bin/rngd
    ln -sf ${pkgs.rng-tools}/bin/rngd        ./files/sbin/rngd
    ln -sf ${pkgs.iproute2}/bin/ip           ./files/usr/bin/ip

    # --- SSL certificates ---
    ln -sf ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
      ./files/etc/ssl/certs/ca-certificates.crt

    # --- udhcpc default script ---
    mkdir -p ./files/usr/share/udhcpc
    cp ${udhcpcScript} ./files/usr/share/udhcpc/default.script
    chmod 755 ./files/usr/share/udhcpc/default.script

    # --- Minimal /etc ---
    echo "gondolin" > ./files/etc/hostname
    echo "root:x:0:0:root:/root:/bin/sh" > ./files/etc/passwd
    echo "root:x:0:" > ./files/etc/group
    echo "nameserver 10.0.2.3" > ./files/etc/resolv.conf
    echo "/bin/sh" > ./files/etc/shells
  '';
}
