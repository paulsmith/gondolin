{
  description = "Gondolin VM images — minimal kernel, initramfs, and rootfs for subsecond QEMU boot";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;

      # Helper to get pkgs for a given system.
      pkgsFor = system: nixpkgs.legacyPackages.${system};
    in
    {
      packages = forAllSystems (system:
        let
          pkgs = pkgsFor system;
          lib = nixpkgs.lib;

          # --- Individual build components ---

          kernelPackages = import ./nix/kernel.nix { inherit pkgs lib; };
          kernel = kernelPackages.kernel;

          guestBinaries = import ./nix/guest-binaries.nix { inherit pkgs; };

          initramfs = import ./nix/initramfs.nix { inherit pkgs lib; };

          rootfs = import ./nix/rootfs.nix { inherit pkgs lib guestBinaries; };

          # Determine the correct kernel image path per architecture.
          # x86_64: bzImage at arch/x86/boot/bzImage
          # aarch64: Image at arch/arm64/boot/Image
          kernelImagePath =
            if system == "x86_64-linux"
            then "${kernel}/bzImage"
            else "${kernel}/Image";

        in {
          # --- Individual artifacts for testing / debugging ---

          inherit kernel initramfs rootfs guestBinaries;

          kernel-packages = kernelPackages;

          # --- Combined image set (the main output) ---
          #
          # Produces a directory with the three files the host expects:
          #   vmlinuz-virt         — kernel image
          #   initramfs.cpio.lz4   — compressed initramfs
          #   rootfs.ext4          — ext4 root filesystem
          #
          vm-image = pkgs.runCommand "gondolin-vm-image" {
            meta.description = "Gondolin VM image set (kernel + initramfs + rootfs)";
          } ''
            mkdir -p $out

            cp ${kernelImagePath}   $out/vmlinuz-virt
            cp ${initramfs}/initrd  $out/initramfs.cpio.lz4
            cp ${rootfs}            $out/rootfs.ext4

            # Write a manifest for the host TypeScript code to consume.
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
              "builder": "nix"
            }
            MANIFEST
          '';

          # --- Default package ---
          default = self.packages.${system}.vm-image;
        }
      );

      # --- Dev shell for working on guest code and images ---
      devShells = forAllSystems (system:
        let pkgs = pkgsFor system;
        in {
          default = pkgs.mkShell {
            packages = with pkgs; [
              # VM runtime
              qemu

              # Image build tools (for manual experiments)
              e2fsprogs
              lz4
              cpio

              # Guest binary development
              zig

              # Host development
              nodejs
              nodePackages.typescript
            ];

            shellHook = ''
              echo "gondolin dev shell"
              echo "  nix build .#vm-image    — build all VM artifacts"
              echo "  nix build .#kernel      — build just the kernel"
              echo "  nix build .#initramfs   — build just the initramfs"
              echo "  nix build .#rootfs      — build just the rootfs"
              echo ""
            '';
          };
        }
      );
    };
}
