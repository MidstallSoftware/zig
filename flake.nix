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
      zigOverlay = final: prev: {
        zig_0_14 = (prev.zig_0_12.override {
          llvmPackages = prev.llvmPackages_18;
        }).overrideAttrs (f: p: {
          version = "0.14.0-dev.${self.shortRev or "dirty"}";
          src = nixpkgs.lib.cleanSource self;

          postBuild = ''
            stage3/bin/zig build langref
          '';

          postInstall = ''
            install -Dm444 ../zig-out/doc/langref.html -t $doc/share/doc/zig-${f.version}/html
          '';
        });

        zig = final.zig_0_14;
      };
    in
    (flake-utils.lib.eachSystem flake-utils.lib.allSystems (
      system: let
        pkgs = nixpkgs.${system}.legacyPackages.appendOverlays [
          zigOverlay
        ];
        llvmPackages = pkgs.llvmPackages_18;
      in {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = with pkgs;
            [
              stdenv.cc.cc.lib
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
