{
  description = "open-usage — Linux-native AI coding subscription usage tracker (daemon + CLI + Waybar)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  # Advertise the binary cache so `nix run/build github:0xfell/open-usage` can
  # pull prebuilt closures instead of compiling. Users must trust these (Nix
  # will prompt, or add them to nix.settings on NixOS).
  nixConfig = {
    extra-substituters = [
      "https://0xfell.cachix.org"
      "https://nix-community.cachix.org"
    ];
    extra-trusted-public-keys = [
      "0xfell.cachix.org-1:0VSPKbe/Eilt+WTT/0faSQeQnnhDOH7PxkUvoRtvPPo="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];
  };

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs systems;

      packageFor = system:
        let
          pkgs = import nixpkgs { inherit system; };

          # `secret-tool` (libsecret) is the only optional runtime dep: it is
          # used solely as a fallback when a provider stores its token in the
          # Secret Service rather than a plaintext file. We wrap it onto PATH so
          # the feature works out of the box, but the binary runs fine without
          # it (file-based credentials are the common case).
          runtimePath = lib.makeBinPath [ pkgs.libsecret ];
        in
        pkgs.rustPlatform.buildRustPackage {
          pname = "open-usage";
          version = "0.1.0";
          src = ./.;

          cargoLock = {
            lockFile = ./Cargo.lock;
          };

          nativeBuildInputs = [
            pkgs.makeBinaryWrapper
            # rusqlite is built with the `bundled` feature, which compiles the
            # vendored SQLite amalgamation — needs a C toolchain at build time.
            pkgs.stdenv.cc
          ];

          # reqwest uses rustls (no system OpenSSL); rusqlite bundles SQLite.
          # So there are no system library buildInputs.
          buildInputs = [ ];

          postFixup = ''
            wrapProgram "$out/bin/openusage" \
              --prefix PATH : "${runtimePath}"
          '';

          meta = {
            description = "Linux-native AI subscription usage tracker (daemon + CLI + Waybar)";
            mainProgram = "openusage";
            license = lib.licenses.mit;
            platforms = systems;
          };
        };
    in
    {
      packages = forAllSystems (system: rec {
        default = packageFor system;
        open-usage = default;
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/openusage";
        };
      });

      homeManagerModules.default = { config, lib, pkgs, ... }:
        let
          cfg = config.programs.open-usage;
        in
        {
          options.programs.open-usage = {
            enable = lib.mkEnableOption "open-usage AI subscription usage tracker";

            package = lib.mkOption {
              type = lib.types.package;
              default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
              defaultText = lib.literalExpression "open-usage.packages.\${pkgs.stdenv.hostPlatform.system}.default";
              description = "open-usage package to install.";
            };

            serve = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = false;
                description = ''
                  Run `openusage serve` as a user service exposing the local
                  HTTP API on 127.0.0.1:6736.
                '';
              };

              interval = lib.mkOption {
                type = lib.types.int;
                default = 300;
                description = "Refresh interval in seconds for the serve daemon (min 30).";
              };
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ cfg.package ];

            systemd.user.services.open-usage = lib.mkIf cfg.serve.enable {
              Unit = {
                Description = "open-usage local usage API";
                After = [ "graphical-session.target" ];
                PartOf = [ "graphical-session.target" ];
              };

              Service = {
                ExecStart = "${cfg.package}/bin/openusage serve --interval ${toString cfg.serve.interval}";
                Restart = "on-failure";
                RestartSec = 5;
              };

              Install.WantedBy = [ "default.target" ];
            };
          };
        };

      checks = forAllSystems (system: {
        default = self.packages.${system}.default;
      });

      devShells = forAllSystems (system:
        let
          pkgs = import nixpkgs { inherit system; };
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.cargo
              pkgs.rustc
              pkgs.rustfmt
              pkgs.clippy
              pkgs.rust-analyzer
              pkgs.libsecret
            ];
          };
        });
    };
}
