{
  description = "Zig compiler development.";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    # Used for shell.nix
    flake-compat = {
      url = "github:edolstra/flake-compat";
      flake = false;
    };
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
    ...
  } @ inputs:
    let
      zigOverlay = f: p: {
        zig = p.stdenv.mkDerivation {
          pname = "zig";
          version = "0.12.0-dev.${self.shortRev or "dirty"}";

          src = p.lib.cleanSource self;

          nativeBuildInputs = [
            p.cmake
            p.llvmPackages_17.llvm.dev
          ];

          buildInputs = [
            p.stdenv.cc.cc.lib
            p.stdenv.cc.cc.libc_dev.out
            p.libxml2
            p.zlib
          ] ++ (with p.llvmPackages_17; [
            libclang
            lld
            llvm
          ]);

          env.ZIG_GLOBAL_CACHE_DIR = "$TMPDIR/zig-cache";

          postPatch = ''
            substituteInPlace lib/std/zig/system.zig \
              --replace "/usr/bin/env" "${p.coreutils}/bin/env"
          '';

          doInstallCheck = true;
          installCheckPhase = ''
            runHook preInstallCheck

            $out/bin/zig test --cache-dir "$TMPDIR/zig-test-cache" -I $src/test $src/test/behavior.zig

            runHook postInstallCheck
          '';
        };
      };
    in
    (flake-utils.lib.eachSystem flake-utils.lib.allSystems (
      system: let
        pkgs = (import nixpkgs {inherit system;}).appendOverlays [
          zigOverlay
        ];
        llvmPackages = pkgs.llvmPackages_17;
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs;
            [
              stdenv.cc.cc.lib
              stdenv.cc.cc.libc_dev.out
              cmake
              gdb
              libxml2
              ninja
              qemu
              wasmtime
              zlib
            ]
            ++ (with llvmPackages; [
              clang
              clang-unwrapped
              lld
              llvm
            ]);

          hardeningDisable = ["all"];
        };

        packages.default = pkgs.zig;
        legacyPackages = pkgs;

        # For compatibility with older versions of the `nix` binary
        devShell = self.devShells.${system}.default;
      }
    )) // {
      overlays.default = zigOverlay;
    };
}
