{
  description = "Gondolin VM images — minimal kernel, initramfs, and rootfs for subsecond QEMU boot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;

      # All systems we support as *build* hosts.
      allBuildSystems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];

      # The Linux systems we produce VM images for.
      linuxSystems = [ "x86_64-linux" "aarch64-linux" ];

      # Map a build host to its default Linux VM target.
      # Apple Silicon Mac → aarch64-linux, Intel Mac → x86_64-linux.
      defaultLinuxTarget = {
        "x86_64-linux"   = "x86_64-linux";
        "aarch64-linux"  = "aarch64-linux";
        "x86_64-darwin"  = "x86_64-linux";
        "aarch64-darwin" = "aarch64-linux";
      };

      forAllBuildSystems = lib.genAttrs allBuildSystems;
      forLinuxSystems    = lib.genAttrs linuxSystems;

      # ---------------------------------------------------------------
      # Build the full VM image set for a given Linux target system.
      # These derivations always have system = *-linux, so Nix will
      # offload them to a Linux builder when invoked from macOS.
      # ---------------------------------------------------------------
      mkVmPackages = targetSystem:
        let
          pkgs = nixpkgs.legacyPackages.${targetSystem};

          kernelPackages = import ./nix/kernel.nix { inherit pkgs lib; };
          kernel = kernelPackages.kernel;

          guestBinaries = import ./nix/guest-binaries.nix {
            inherit pkgs;
            targetSystem = targetSystem;
          };

          initramfs = import ./nix/initramfs.nix { inherit pkgs lib; };

          rootfs = import ./nix/rootfs.nix { inherit pkgs lib guestBinaries; };

          kernelImagePath =
            if targetSystem == "x86_64-linux"
            then "${kernel}/bzImage"
            else "${kernel}/Image";

        in {
          inherit kernel initramfs rootfs guestBinaries;

          kernel-packages = kernelPackages;

          vm-image = pkgs.runCommand "gondolin-vm-image" {
            meta.description = "Gondolin VM image set (kernel + initramfs + rootfs)";
          } ''
            mkdir -p $out

            cp ${kernelImagePath}   $out/vmlinuz-virt
            cp ${initramfs}/initrd  $out/initramfs.cpio.lz4
            cp ${rootfs}            $out/rootfs.ext4

            cat > $out/manifest.json <<MANIFEST
            {
              "version": 1,
              "buildId": "nix-${builtins.substring 0 12 (builtins.hashString "sha256" (builtins.toString self.lastModified or "unknown"))}",
              "buildTime": "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)",
              "assets": {
                "kernel": "vmlinuz-virt",
                "initramfs": "initramfs.cpio.lz4",
                "rootfs": "rootfs.ext4"
              },
              "builder": "nix",
              "target": "${targetSystem}"
            }
            MANIFEST
          '';
        };

    in {

      # =================================================================
      # packages.<system>.*
      #
      # On Linux hosts: native builds for the matching architecture.
      # On macOS hosts: re-exports the matching Linux target's packages.
      #   Nix automatically offloads these to a configured Linux builder.
      #
      # Usage from macOS:
      #   nix build .#vm-image            # builds for matching Linux arch
      #   nix build .#vm-image-x86_64     # explicitly target x86_64
      #   nix build .#vm-image-aarch64    # explicitly target aarch64
      #   nix build .#guest-binaries      # builds natively with Zig (no Linux builder needed)
      # =================================================================
      packages = forAllBuildSystems (buildSystem:
        let
          # The Linux target that matches this build host's architecture.
          matchingTarget = defaultLinuxTarget.${buildSystem};
          matchingPkgs   = mkVmPackages matchingTarget;

          isDarwin = lib.hasSuffix "-darwin" buildSystem;

          # On Darwin, guest-binaries can be built *natively* using Zig's
          # cross-compilation (no Linux builder required).
          darwinGuestBinaries = import ./nix/guest-binaries.nix {
            pkgs = nixpkgs.legacyPackages.${buildSystem};
            targetSystem = matchingTarget;
          };

          # Explicit per-arch targets (useful from any host).
          x86Pkgs    = mkVmPackages "x86_64-linux";
          aarch64Pkgs = mkVmPackages "aarch64-linux";

        in
          # On Linux: expose the full set of native packages.
          (if !isDarwin then {
            inherit (matchingPkgs) kernel initramfs rootfs guestBinaries;
            kernel-packages = matchingPkgs.kernel-packages;
            vm-image = matchingPkgs.vm-image;
            default  = matchingPkgs.vm-image;
          }

          # On Darwin: re-export matching Linux packages (requires a Linux
          # builder) plus a native guest-binaries target.
          else {
            # The default target — builds the complete VM image for the
            # matching Linux architecture.  Nix delegates to a Linux
            # builder (nix-darwin linux-builder, remote builder, or
            # Docker-based builder).
            vm-image = matchingPkgs.vm-image;
            default  = matchingPkgs.vm-image;

            # Individual Linux artifacts (also delegated to Linux builder).
            inherit (matchingPkgs) kernel initramfs rootfs;
            kernel-packages = matchingPkgs.kernel-packages;

            # Guest binaries built natively on macOS via Zig cross-
            # compilation.  Does NOT require a Linux builder.
            guest-binaries = darwinGuestBinaries;
          })

          # Both hosts get explicit per-arch image targets.
          // {
            vm-image-x86_64  = x86Pkgs.vm-image;
            vm-image-aarch64 = aarch64Pkgs.vm-image;
          }
      );

      # =================================================================
      # devShells — available on all platforms
      # =================================================================
      devShells = forAllBuildSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          isDarwin = lib.hasSuffix "-darwin" system;
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              # Guest binary development
              zig

              # Host development
              nodejs

              # Image build tools (Linux-only, useful in dev)
            ] ++ lib.optionals (!isDarwin) [
              qemu
              e2fsprogs
              lz4
              cpio
            ];

            shellHook = ''
              echo "gondolin dev shell (${system})"
              echo ""
              echo "  nix build .#vm-image          — full VM image (matching arch)"
              echo "  nix build .#vm-image-x86_64   — VM image for x86_64"
              echo "  nix build .#vm-image-aarch64  — VM image for aarch64"
              echo "  nix build .#guest-binaries    — Zig guest binaries only"
              echo "  nix build .#kernel            — kernel only"
              echo "  nix build .#initramfs         — initramfs only"
              echo "  nix build .#rootfs            — rootfs only"
              echo ""
            '' + lib.optionalString isDarwin ''
              echo "NOTE: Building VM images from macOS requires a Linux builder."
              echo "  • nix-darwin linux-builder (recommended)"
              echo "  • Remote builder via /etc/nix/machines"
              echo "  • Docker-based builder (nixos/nix)"
              echo ""
              echo "guest-binaries builds natively on macOS (no Linux builder needed)."
              echo ""
            '';
          };
        }
      );
    };
}
