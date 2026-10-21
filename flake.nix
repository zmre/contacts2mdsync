{
  description = "Contacts2MdSync: two-way sync between Apple Contacts and markdown notes (macOS SwiftUI app)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    # The real mbr, used by `checks.mbr` to validate our fixture output.
    # Deliberately NOT following our nixpkgs: that keeps mbr-cli a cache hit
    # (zmre.cachix.org) instead of a from-source Rust build.
    mbr.url = "github:zmre/mbr-markdown-browser";
  };

  outputs = {
    self,
    nixpkgs,
    mbr,
  }: let
    inherit (nixpkgs) lib;
    systems = ["aarch64-darwin"];
    forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
  in {
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShellNoCC {
        packages = with pkgs; [
          xcodegen
          swiftlint
          swift-format
          xcbeautify
          periphery
          create-dmg
          just
          jq # scripts/mbr-check.sh
        ];
        # Deliberately no pkgs.swift: the app and package build with the
        # system Xcode toolchain (/usr/bin/xcodebuild, xcrun swift). nixpkgs
        # stdenv exports DEVELOPER_DIR/SDKROOT pointing at its own apple-sdk,
        # which would redirect xcrun away from Xcode, so clear them.
        shellHook = ''
          unset DEVELOPER_DIR SDKROOT
        '';
      };
    });

    packages = forAllSystems (pkgs: {
      contacts2mdsync = pkgs.callPackage ./nix/package.nix {};
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.contacts2mdsync;
    });

    overlays.default = final: _prev: {
      contacts2mdsync = final.callPackage ./nix/package.nix {};
    };

    darwinModules.default = import ./nix/darwin-module.nix {inherit self;};

    checks = forAllSystems (pkgs: let
      # Evaluates nix/darwin-module.nix without nix-darwin: stub options stand
      # in for the few nix-darwin options the module sets or reads. Nothing is
      # built; `package` is pinned to a stand-in so the impure app build is
      # never forced.
      evalDarwinModule = cfg:
        (lib.evalModules {
          specialArgs = {inherit pkgs;};
          modules = [
            self.darwinModules.default
            ({lib, ...}: let
              stub = type: lib.mkOption {inherit type;};
            in {
              options = {
                assertions = stub (lib.types.listOf lib.types.unspecified) // {default = [];};
                environment.systemPackages = stub (lib.types.listOf lib.types.package);
                nixpkgs.overlays = stub (lib.types.listOf lib.types.unspecified);
                launchd.user.agents = stub (lib.types.attrsOf lib.types.anything) // {default = {};};
                system.primaryUser = stub (lib.types.nullOr lib.types.str) // {default = "alice";};
              };
              config.programs.contacts2mdsync =
                {
                  enable = true;
                  package = pkgs.emptyFile;
                }
                // cfg;
            })
          ];
        }).config;
      failedAssertions = config: map (a: a.message) (lib.filter (a: !a.assertion) config.assertions);
      app = "/Applications/Nix Apps/Contacts2MdSync.app/Contents/MacOS/Contacts2MdSync";
      expect = name: actual: expected:
        lib.assertMsg (actual == expected)
        "darwin-module check '${name}': expected ${builtins.toJSON expected}, got ${builtins.toJSON actual}";

      hourly = evalDarwinModule {schedule.enable = true;};
      hourlyAgent = hourly.launchd.user.agents.contacts2mdsync-sync.serviceConfig;
      calendar = evalDarwinModule {
        schedule = {
          enable = true;
          calendar = [{Minute = 0;}];
          extraArgs = [];
          logFile = null;
        };
      };
      calendarAgent = calendar.launchd.user.agents.contacts2mdsync-sync.serviceConfig;
      both = evalDarwinModule {
        schedule = {
          enable = true;
          interval = 60;
          calendar = [{Minute = 0;}];
        };
      };
      unscheduled = evalDarwinModule {};
    in {
      # The nix-darwin module evaluates and produces the expected launchd
      # user agent (see evalDarwinModule above).
      darwin-module = assert expect "hourly ProgramArguments" hourlyAgent.ProgramArguments [app "sync" "--quiet"];
      assert expect "hourly StartInterval" hourlyAgent.StartInterval 3600;
      assert expect "hourly has no calendar" (hourlyAgent ? StartCalendarInterval) false;
      assert expect "hourly log" hourlyAgent.StandardOutPath "/Users/alice/Library/Logs/Contacts2MdSync.log";
      assert expect "hourly stderr log" hourlyAgent.StandardErrorPath hourlyAgent.StandardOutPath;
      assert expect "hourly priority" [hourlyAgent.RunAtLoad hourlyAgent.ProcessType hourlyAgent.LowPriorityIO hourlyAgent.Nice] [false "Background" true 10];
      assert expect "hourly assertions" (failedAssertions hourly) [];
      assert expect "calendar ProgramArguments" calendarAgent.ProgramArguments [app "sync"];
      assert expect "calendar StartCalendarInterval" calendarAgent.StartCalendarInterval [{Minute = 0;}];
      assert expect "calendar has no interval" (calendarAgent ? StartInterval) false;
      assert expect "calendar has no log" (calendarAgent ? StandardOutPath) false;
      assert expect "calendar assertions" (failedAssertions calendar) [];
      assert expect "interval+calendar rejected" (lib.length (failedAssertions both)) 1;
      assert expect "no agent unless scheduled" unscheduled.launchd.user.agents {};
        pkgs.runCommandLocal "contacts2mdsync-darwin-module-check" {} "touch $out";

      # Fully pure and sandbox-safe: swift-format is self-contained.
      #
      # Not checks, deliberately:
      #  - the app build (impure: needs Xcode + __noChroot, see nix/package.nix)
      #  - swiftlint: nixpkgs' swiftlint dlopens sourcekitdInProc from the host
      #    Xcode at runtime, which the sandbox blocks (and __impureHostDeps on
      #    /Applications/Xcode.app is refused unless the daemon lists it in
      #    allowed-impure-host-deps). Run it via `just lint` instead.
      format =
        pkgs.runCommandLocal "contacts2mdsync-format-check" {
          src = self;
          nativeBuildInputs = [pkgs.swift-format];
        } ''
          cd $src
          swift-format lint --strict --recursive --parallel \
            --configuration .swift-format \
            App/Contacts2MdSync \
            Packages/Contacts2MdSyncKit/Sources \
            Packages/Contacts2MdSyncKit/Tests \
            Packages/Contacts2MdSyncKit/Package.swift
          touch $out
        '';

      # Spike S10: the exported fixture notes must read cleanly in the real
      # mbr (no contact data problems, no frontmatter parse errors). Serves
      # them with `mbr -s` on loopback inside the sandbox and checks every
      # page's errors.json (see scripts/mbr-check.sh). Fixtures are
      # regenerated by `just update-goldens`.
      mbr =
        pkgs.runCommandLocal "contacts2mdsync-mbr-check" {
          src = lib.fileset.toSource {
            root = ./.;
            fileset = lib.fileset.unions [
              ./scripts/mbr-check.sh
              ./Packages/Contacts2MdSyncKit/Tests/SyncEngineTests/Fixtures/export
            ];
          };
          nativeBuildInputs = [
            mbr.packages.${pkgs.stdenv.hostPlatform.system}.mbr-cli
            pkgs.curl
            pkgs.jq
          ];
          __darwinAllowLocalNetworking = true;
        } ''
          export HOME=$TMPDIR
          cd $src
          bash scripts/mbr-check.sh Packages/Contacts2MdSyncKit/Tests/SyncEngineTests/Fixtures/export
          touch $out
        '';
    });

    formatter = forAllSystems (pkgs: pkgs.alejandra);
  };
}
