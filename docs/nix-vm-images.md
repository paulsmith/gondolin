# Nix-based VM Image Build: Investigation and Plan

This document captures the investigation into replacing gondolin's Alpine Linux
VM image build pipeline with a Nix-based approach, and proposes a concrete
implementation path that preserves the current subsecond boot times.

## Current Architecture

Gondolin builds three artifacts for its QEMU microvm:

| Artifact | Source | Format |
|----------|--------|--------|
| **kernel** | Alpine `linux-virt` APK (pre-built) | `vmlinuz-virt` (compressed bzImage/Image) |
| **initramfs** | Hand-rolled cpio + lz4 with busybox + 2 kernel modules (`virtio_blk`, `ext4`) | `initramfs.cpio.lz4` |
| **rootfs** | Alpine minirootfs + APK packages + gondolin binaries | `rootfs.ext4` |

The build is orchestrated by a pure-TypeScript pipeline (`build-alpine.ts`,
`builder.ts`) that:

1. Downloads Alpine minirootfs tarball
2. Resolves and installs APK packages (custom dependency resolver)
3. Copies gondolin Zig binaries (sandboxd, sandboxfs, sandboxssh, sandboxingress)
4. Extracts kernel modules for initramfs
5. Creates ext4 rootfs via `mke2fs`
6. Creates lz4-compressed initramfs via `cpio` + `lz4`
7. Extracts kernel binary from APK

### Why It's Fast (< 1 second boot)

- QEMU direct kernel boot (`-kernel`, `-initrd`, `-append`) — no BIOS/bootloader
- `microvm` machine type with MMIO virtio devices — minimal device emulation
- Kernel: Alpine's `linux-virt` is already stripped for VM use
- Initramfs: ~76 lines of shell, loads only `virtio_blk` + `ext4`, then `switch_root`
- Rootfs init: ~206 lines of shell as PID 1, no systemd/openrc
- Kernel cmdline: `console=ttyS0 initramfs_async=1`
- QEMU flags: `-nodefaults -no-reboot -nographic`

## Proposed Nix Architecture

The goal is a `flake.nix` at the repository root that produces the same three
artifacts (kernel, initramfs, rootfs.ext4) with equivalent boot performance,
using nixpkgs infrastructure instead of the custom Alpine pipeline.

### Key Design Decisions

**1. Custom minimal kernel via `buildLinux`, not the NixOS default kernel**

The NixOS default kernel is enormous (~100+ MB, thousands of modules). Alpine's
`linux-virt` is 6-15 MB. We need to build our own with `autoModules = false`
and only the virtio drivers compiled in.

```nix
minimalKernel = pkgs.linuxPackagesFor (pkgs.linux_6_12.override {
  structuredExtraConfig = with lib.kernel; {
    # Core virtio transport — built-in, not modules
    VIRTIO           = yes;
    VIRTIO_PCI       = yes;
    VIRTIO_MMIO      = yes;
    VIRTIO_BLK       = yes;
    VIRTIO_NET       = yes;
    VIRTIO_CONSOLE   = yes;
    VIRTIO_RNG       = yes;

    # Filesystem
    EXT4_FS          = yes;
    FUSE_FS          = yes;

    # Strip everything we don't need
    SOUND            = no;
    USB_SUPPORT      = no;
    WIRELESS         = no;
    WLAN             = no;
    BLUETOOTH        = no;
    DRM              = no;
    FB               = no;
    INPUT_EVDEV      = no;
    HID              = no;

    # No loadable modules — everything built in
    MODULES          = no;
  };
  autoModules = false;
  kernelPreferBuiltin = true;
  ignoreConfigErrors = true;
});
```

Setting `MODULES = no` eliminates the need for `modprobe` entirely during boot,
which removes a step from both the initramfs and rootfs init scripts. All virtio
drivers are immediately available at kernel start.

**2. Minimal initramfs via `makeInitrd`, not the NixOS stage-1**

NixOS's standard initrd (`nixos/modules/system/boot/stage-1.nix`) is a full
systemd-based boot environment. We bypass this entirely and use
`pkgs.makeInitrd` (or `makeInitrdNG`) with our own init script, analogous to the
current `guest/image/initramfs-init`.

```nix
initramfs = pkgs.makeInitrdNG {
  contents = [
    { source = initramfsInit; target = "/init"; }
  ];
  compressor = "lz4 -l";
};
```

Because all virtio and ext4 drivers are compiled into the kernel (no modules),
the initramfs init script becomes even simpler — it only needs to mount
proc/sys/devtmpfs, wait for `/dev/vda`, mount it, and `switch_root`. No
`modprobe` calls needed.

The initramfs only needs `busybox` (for `mount`, `switch_root`, `sleep`, `sh`)
and nothing else. Since `makeInitrdNG` automatically includes the Nix closure of
referenced paths, referencing `${pkgs.busybox-sandbox-shell}` or a static
busybox will pull in exactly what's needed.

**3. Rootfs via `make-ext4-fs.nix`, not the full NixOS disk image builder**

We do NOT want a full NixOS system in the rootfs. The current rootfs contains:

- Alpine base utilities (busybox, bash, coreutils)
- Runtime packages (nodejs, python3, curl, openssh, etc.)
- Gondolin binaries (sandboxd, sandboxfs, sandboxssh, sandboxingress)
- Our custom `/init` script as PID 1

The Nix equivalent uses `make-ext4-fs.nix` to create an ext4 image containing
only the Nix store closure of the packages we need, plus our init script and
filesystem structure:

```nix
rootfs = import "${pkgs.path}/nixos/lib/make-ext4-fs.nix" {
  inherit pkgs lib;
  storePaths = [
    pkgs.busybox
    pkgs.bash
    pkgs.nodejs
    pkgs.python3
    pkgs.curl
    pkgs.openssh
    pkgs.cacert
    pkgs.uv
    gondolinBinaries  # sandboxd, sandboxfs, etc.
    rootfsInitScript
  ];
  volumeLabel = "gondolin-root";
  populateImageCommands = ''
    # Create FHS-like directory structure
    mkdir -p ./files/{sbin,usr/bin,etc,tmp,var,root,home,data,proc,sys,dev,run}

    # PID 1 init script
    cp ${rootfsInitScript} ./files/init
    chmod 755 ./files/init

    # Symlink gondolin binaries to /usr/bin
    ln -s ${gondolinBinaries}/bin/sandboxd   ./files/usr/bin/sandboxd
    ln -s ${gondolinBinaries}/bin/sandboxfs  ./files/usr/bin/sandboxfs
    ln -s ${gondolinBinaries}/bin/sandboxssh ./files/usr/bin/sandboxssh
    ln -s ${gondolinBinaries}/bin/sandboxingress ./files/usr/bin/sandboxingress

    # Symlink common tools to /usr/bin for PATH compatibility
    for bin in bash sh node python3 curl ssh udhcpc ip; do
      target=$(find ./nix/store -name "$bin" -type f -executable | head -1)
      if [ -n "$target" ]; then
        ln -sf "/$target" "./files/usr/bin/$bin"
      fi
    done

    # SSL certs
    mkdir -p ./files/etc/ssl/certs
    ln -s ${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt \
      ./files/etc/ssl/certs/ca-certificates.crt
  '';
};
```

**4. No systemd, no NixOS activation, no services**

The rootfs `/init` is our own shell script — the same one we use today
(`guest/image/init`), adapted for Nix store paths. It runs as PID 1 and directly
launches the gondolin daemons. No systemd, no openrc, no NixOS activation
scripts.

This is the single most important decision for preserving subsecond boot. A
standard NixOS boot goes through systemd (which alone adds seconds), plus NixOS
activation scripts, plus service dependencies. We skip all of that.

**5. PATH and FHS compatibility**

Nix store paths (`/nix/store/xxxx-bash-5.2/bin/bash`) are not on PATH by
default. The rootfs init script and `populateImageCommands` need to create
symlinks under `/usr/bin` for tools that the gondolin daemons and user processes
expect to find. Alternatively, the init script can set `PATH` to include all
relevant Nix store bin directories.

### Flake Structure

```
gondolin/
├── flake.nix                    # Top-level flake
├── flake.lock
├── nix/
│   ├── kernel.nix               # Custom minimal kernel derivation
│   ├── initramfs.nix            # initramfs derivation
│   ├── rootfs.nix               # ext4 rootfs derivation
│   ├── guest-binaries.nix       # sandboxd/sandboxfs/etc. (Zig build)
│   └── vm-image.nix             # Combines all three into a final image set
├── guest/
│   ├── image/
│   │   ├── init                 # rootfs init (PID 1) — shared with Nix build
│   │   └── initramfs-init       # initramfs init — shared with Nix build
│   └── src/                     # Zig sources (unchanged)
└── host/                        # TypeScript host (unchanged)
```

### Proposed `flake.nix`

```nix
{
  description = "Gondolin VM images";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
    in {
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          lib = nixpkgs.lib;

          kernel = import ./nix/kernel.nix { inherit pkgs lib; };
          guestBinaries = import ./nix/guest-binaries.nix { inherit pkgs; };
          initramfs = import ./nix/initramfs.nix { inherit pkgs lib; };
          rootfs = import ./nix/rootfs.nix {
            inherit pkgs lib;
            inherit guestBinaries;
          };

        in {
          # Individual artifacts
          inherit kernel initramfs rootfs;
          guest-binaries = guestBinaries;

          # Combined image set (directory with all three artifacts)
          vm-image = pkgs.runCommand "gondolin-vm-image" {} ''
            mkdir -p $out
            cp ${kernel}/bzImage    $out/vmlinuz-virt    # or vmlinux for Firecracker
            cp ${initramfs}/initrd  $out/initramfs.cpio.lz4
            cp ${rootfs}            $out/rootfs.ext4
          '';

          # Default package
          default = self.packages.${system}.vm-image;
        }
      );

      # Dev shell for working on images
      devShells = forAllSystems (system:
        let pkgs = nixpkgs.legacyPackages.${system};
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              qemu
              e2fsprogs
              lz4
              zig_0_15
            ];
          };
        }
      );
    };
}
```

### Build commands

```bash
# Build everything
nix build .#vm-image

# Build individual artifacts
nix build .#kernel
nix build .#initramfs
nix build .#rootfs

# Enter dev shell
nix develop
```

## Porting the Guest Binaries (Zig to Nix)

The gondolin guest binaries (sandboxd, sandboxfs, sandboxssh, sandboxingress)
are written in Zig and currently built via `zig build` with target triples like
`aarch64-linux-musl` / `x86_64-linux-musl`.

Nixpkgs has Zig build support:

```nix
guestBinaries = pkgs.stdenv.mkDerivation {
  pname = "gondolin-guest-binaries";
  version = "0.1.0";
  src = ./guest;

  nativeBuildInputs = [ pkgs.zig_0_15 ];

  buildPhase = ''
    zig build -Dtarget=${zigTarget} -Doptimize=ReleaseSafe
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp zig-out/bin/sandboxd $out/bin/
    cp zig-out/bin/sandboxfs $out/bin/
    cp zig-out/bin/sandboxssh $out/bin/
    cp zig-out/bin/sandboxingress $out/bin/
  '';
};
```

Since these are statically linked musl binaries, they have no runtime
dependencies and can be dropped directly into any rootfs.

## Adapting the Init Scripts for Nix

### initramfs-init

The current initramfs-init calls `modprobe virtio_blk` and `modprobe ext4`.
With `CONFIG_MODULES=no` in our custom kernel, these drivers are compiled in and
available immediately. The init script simplifies to:

```sh
#!/bin/sh
set -eu
mount -t proc proc /proc
mount -t sysfs sysfs /sys
mount -t devtmpfs devtmpfs /dev
mkdir -p /dev/pts /dev/shm /run
mount -t devpts devpts /dev/pts
mount -t tmpfs tmpfs /run

# With built-in drivers, /dev/vda appears immediately
root_device="/dev/vda"
if [ -r /proc/cmdline ]; then
  for arg in $(cat /proc/cmdline); do
    case "${arg}" in root=*) root_device="${arg#root=}" ;; esac
  done
fi

mkdir -p /newroot
mount -t ext4 "${root_device}" /newroot
exec switch_root /newroot /init
```

No module loading, no wait loop (virtio_blk is built-in so the device appears
immediately at boot), no busybox beyond the basic utilities already in the
initramfs.

### rootfs init

The rootfs init (`guest/image/init`) needs minimal changes for Nix. The main
difference is that binaries live in `/nix/store/...` paths instead of `/usr/bin`.
Two approaches:

**Option A: Symlinks** — Create `/usr/bin/sandboxd` etc. symlinks in
`populateImageCommands`. The init script stays unchanged. This is the simplest
path and preserves compatibility with the existing init.

**Option B: Nix-aware PATH** — Set PATH in the init script to include all
relevant Nix store paths. More "Nix-native" but requires maintaining PATH
entries.

Recommendation: **Option A** (symlinks). It requires zero changes to the init
scripts and the host-side TypeScript code that references paths like
`/usr/bin/sandboxd`.

The `modprobe` calls in the rootfs init (for `virtio_console`, `virtio_rng`,
`virtio_net`, `fuse`) also become no-ops with a built-in kernel, but they
already have `|| true` guards so they won't break — they'll just silently
succeed.

## Boot Time Analysis

| Phase | Current (Alpine) | With Nix | Notes |
|-------|------------------|----------|-------|
| QEMU startup | ~50ms | ~50ms | Unchanged (same QEMU, same flags) |
| Kernel decompress + init | ~100ms | ~80ms | Potentially faster with built-in drivers (no module loading) |
| initramfs init | ~30ms | ~15ms | No modprobe calls, no wait loop for /dev/vda |
| switch_root + rootfs init | ~200ms | ~200ms | Same init script logic |
| Network (DHCP) | ~100ms | ~100ms | Unchanged |
| sandboxd ready | ~20ms | ~20ms | Unchanged |
| **Total** | **~500ms** | **~465ms** | Nix version may be slightly faster |

The Nix approach should be at least as fast, potentially slightly faster due to
built-in drivers eliminating module loading. The critical path is unchanged:
custom shell init scripts, direct kernel boot, no systemd.

## Image Size Analysis

| Artifact | Current (Alpine) | Expected (Nix) | Notes |
|----------|------------------|-----------------|-------|
| kernel | ~8-15 MB | ~5-10 MB | Custom minimal vs. Alpine linux-virt |
| initramfs | ~2-5 MB | ~1-3 MB | No kernel modules needed in initramfs |
| rootfs | ~500 MB - 2 GB | ~800 MB - 2.5 GB | Nix store overhead (more closure deps) |

The rootfs will likely be larger because Nix packages include their full
dependency closures in `/nix/store`. For example, `nodejs` in Nix pulls in glibc,
gcc runtime libs, etc. as separate store paths. However:

- The ext4 image is auto-sized to content, so it's not wasteful
- The image is loaded from disk, not memory — size doesn't affect boot time
- Using `pkgs.pkgsStatic` or `pkgs.pkgsMusl` for some packages can reduce closures

This is the main tradeoff: reproducibility and maintainability vs. image size.

## Integration with the Host TypeScript Code

The host code (`sandbox-server.ts`, `sandbox-controller.ts`) expects three files
in a directory:

- `vmlinuz-virt` — kernel
- `initramfs.cpio.lz4` — initramfs
- `rootfs.ext4` — rootfs

The Nix build produces exactly these with the same names. The integration point
is `builder.ts`, which currently calls `buildAlpineImages()` + `fetchKernel()`.
A Nix-based build would either:

1. **Replace the TypeScript pipeline** — `builder.ts` shells out to
   `nix build .#vm-image` and copies the result
2. **Exist alongside it** — The flake is an independent build path; users choose
   `gondolin build --distro alpine` or `nix build .#vm-image`
3. **Hybrid** — The TypeScript builder detects if Nix is available and delegates
   to it when `distro: "nixos"` is configured

Recommendation: **Option 2** initially (parallel build paths), evolving to
Option 1 once the Nix build is proven equivalent. The existing `build-config.ts`
already has a `distro: "alpine" | "nixos"` union type and a `NixOSConfig`
interface stub.

## Risks and Mitigations

### Risk: Nix store overhead makes rootfs too large

**Mitigation:** Use `pkgs.pkgsMusl` for smaller closures (musl libc is much
smaller than glibc). Use `pkgs.busybox` for coreutils (single binary, ~1 MB
vs. ~30 MB for GNU coreutils). For nodejs/python, accept the larger closure —
these are big packages regardless of distro.

### Risk: Nix kernel build is slow

**Mitigation:** Kernel builds are cached by Nix. After the first build, they're
instant. They can also be served from a binary cache (Cachix or self-hosted) so
CI/CD and other developers never need to compile the kernel locally. The nixpkgs
`linux_6_12` base is already cached on cache.nixos.org — our override just adds
config changes.

### Risk: Nix-built packages differ from Alpine versions

**Mitigation:** This is expected and mostly irrelevant — the guest runs
user-provided code via sandboxd, not Alpine-specific software. The key binaries
(sandboxd, sandboxfs) are our own Zig builds and are identical in both pipelines.
The runtime packages (nodejs, python3, etc.) will be whatever versions nixpkgs
provides, which are typically more up-to-date than Alpine.

### Risk: No Nix on macOS for building Linux images

**Mitigation:** `nix build` with `--system x86_64-linux` can cross-build on
macOS using a Linux builder (e.g., `nix-darwin` with a Linux VM, or a remote
builder). Alternatively, the existing container-based build path in `builder.ts`
can invoke `nix build` inside a NixOS container. This mirrors the current
approach where macOS builds already use a container.

### Risk: Nix adds a build dependency

**Mitigation:** The Alpine build path remains available. Nix is only required if
you want the Nix build. Over time, as the team adopts Nix, the Alpine path can
be deprecated.

## Implementation Phases

### Phase 1: Kernel

- Create `nix/kernel.nix` with a minimal `buildLinux` configuration
- Target: x86_64 and aarch64, virtio-only, CONFIG_MODULES=no
- Validate it boots with QEMU using the existing Alpine initramfs/rootfs
- Measure boot time compared to Alpine `linux-virt`

### Phase 2: Initramfs

- Create `nix/initramfs.nix` using `makeInitrdNG`
- Include busybox (static) and the simplified initramfs-init script
- Validate it works with both the Nix kernel and existing Alpine kernel

### Phase 3: Rootfs

- Create `nix/rootfs.nix` using `make-ext4-fs.nix`
- Include all current packages (bash, nodejs, python3, curl, openssh, etc.)
- Create FHS symlinks for /usr/bin compatibility
- Include gondolin binaries
- Validate the full boot: Nix kernel + Nix initramfs + Nix rootfs

### Phase 4: Guest Binaries

- Create `nix/guest-binaries.nix` wrapping the Zig build
- Ensure cross-compilation works (x86_64 host building aarch64 target)
- Wire into rootfs derivation

### Phase 5: Integration

- Create `flake.nix` tying everything together
- Add `nix build .#vm-image` as a single command for the full image
- Update docs
- Optionally wire into `builder.ts` as an alternative to Alpine

### Phase 6: Validation

- Boot time benchmarks (must remain < 1 second)
- Functional tests (sandboxd exec, sandboxfs mount, networking)
- Image size comparison
- CI integration

## Summary

Replacing the Alpine build with Nix is feasible and preserves subsecond boot
times. The key insight is that we are NOT building a NixOS system — we're using
Nix purely as a build tool to produce the same three artifacts (kernel,
initramfs, rootfs) that the current pipeline produces. The boot path remains
identical: direct kernel boot, shell script PID 1, no systemd.

The main benefits are:

- **Reproducibility** — Exact same image from any machine with Nix
- **Cacheability** — Nix store + binary caches mean incremental builds
- **Declarative** — One `flake.nix` describes the entire image
- **Customizability** — Override any package version, kernel config, etc.
- **Single toolchain** — No more custom APK resolver, tar parser, etc.

The main costs are:

- **Nix dependency** — Developers need Nix installed (or use the container path)
- **Larger rootfs** — Nix store closure overhead adds ~200-500 MB
- **Learning curve** — Nix has a steep learning curve
- **Kernel build time** — First build compiles a kernel (~10-30 min); cached after
