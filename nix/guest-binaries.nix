# Gondolin guest binaries (sandboxd, sandboxfs, sandboxssh, sandboxingress).
#
# These are Zig programs compiled as statically-linked musl executables.
# The Zig build system handles cross-compilation natively — we just set
# -Dtarget to the appropriate triple.
#
# Usage:
#   guestBinaries = import ./guest-binaries.nix { inherit pkgs; };
#   # Binaries are at ${guestBinaries}/bin/{sandboxd,sandboxfs,sandboxssh,sandboxingress}

{ pkgs }:

let
  zigTargets = {
    "x86_64-linux"  = "x86_64-linux-musl";
    "aarch64-linux" = "aarch64-linux-musl";
  };

  zigTarget = zigTargets.${pkgs.stdenv.hostPlatform.system}
    or (throw "Unsupported system: ${pkgs.stdenv.hostPlatform.system}");

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
    platforms = [ "x86_64-linux" "aarch64-linux" ];
  };
}
