# Gondolin guest binaries (sandboxd, sandboxfs, sandboxssh, sandboxingress).
#
# These are Zig programs compiled as statically-linked musl executables.
# Zig handles cross-compilation natively — it can produce Linux musl
# binaries from any host (including macOS) without a separate toolchain.
#
# The `targetSystem` parameter controls the output architecture:
#   "x86_64-linux"  → x86_64-linux-musl
#   "aarch64-linux" → aarch64-linux-musl
#
# When called from a macOS host, the Zig compiler runs natively on macOS
# and cross-compiles to the Linux target.  No Linux builder required.
#
# Usage:
#   guestBinaries = import ./guest-binaries.nix {
#     inherit pkgs;
#     targetSystem = "aarch64-linux";
#   };

{ pkgs
, targetSystem ? pkgs.stdenv.hostPlatform.system
}:

let
  zigTargets = {
    "x86_64-linux"  = "x86_64-linux-musl";
    "aarch64-linux" = "aarch64-linux-musl";
  };

  zigTarget = zigTargets.${targetSystem}
    or (throw "Unsupported target system: ${targetSystem}");

in pkgs.stdenv.mkDerivation {
  pname = "gondolin-guest-binaries";
  version = "0.1.0";

  src = ../guest;

  nativeBuildInputs = [ pkgs.zig ];

  # Zig manages its own cache; point it at a writable location.
  ZIG_GLOBAL_CACHE_DIR = "$TMPDIR/zig-cache";

  dontConfigure = true;
  dontFixup = true;  # no need for patchelf on static musl binaries

  buildPhase = ''
    runHook preBuild

    mkdir -p "$TMPDIR/zig-cache"

    zig build \
      -Dtarget=${zigTarget} \
      -Doptimize=ReleaseSmall \
      --cache-dir "$TMPDIR/zig-cache" \
      --global-cache-dir "$TMPDIR/zig-cache"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp zig-out/bin/sandboxd      $out/bin/
    cp zig-out/bin/sandboxfs     $out/bin/
    cp zig-out/bin/sandboxssh    $out/bin/
    cp zig-out/bin/sandboxingress $out/bin/

    runHook postInstall
  '';

  meta = {
    description = "Gondolin guest VM binaries (sandboxd, sandboxfs, sandboxssh, sandboxingress)";
    platforms = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
  };
}
