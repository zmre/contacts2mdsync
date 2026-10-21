# nix-darwin module for Contacts2MdSync.
#
#   imports = [ contacts2mdsync.darwinModules.default ];
#   programs.contacts2mdsync.enable = true;
#   programs.contacts2mdsync.schedule.enable = true;   # hourly headless sync
#
# The package is an impure build (needs Xcode and a relaxed sandbox); see
# nix/package.nix.
{self}: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.contacts2mdsync;
  sched = cfg.schedule;

  # nix-darwin installs user agents for `system.primaryUser` (and refuses to
  # evaluate without it). launchd does not expand `~` in plist paths, so the
  # log path must be absolute; derive it from that user's home.
  # (`primaryUserHome` is forced only when a primary user is set: its own
  # default interpolates the user name.)
  primaryUser = config.system.primaryUser or null;
  primaryUserHome =
    if primaryUser == null
    then null
    else config.system.primaryUserHome or "/Users/${primaryUser}";
in {
  options.programs.contacts2mdsync = {
    enable = lib.mkEnableOption "Contacts2MdSync, a two-way Apple Contacts <-> markdown sync app";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.contacts2mdsync;
      defaultText = lib.literalExpression "pkgs.contacts2mdsync";
      description = "The Contacts2MdSync package to install.";
    };

    schedule = {
      enable = lib.mkEnableOption ''
        a scheduled headless sync: a launchd user agent
        (`launchd.user.agents.contacts2mdsync-sync`, installed for
        `system.primaryUser`) that periodically runs the app binary as
        `Contacts2MdSync sync` (the same command as `contacts2md sync`).

        One-time setup is still required: open the app once to grant Contacts
        access and choose the notes folder, and complete a first sync. Until
        then every run exits 3 ("not configured"). Headless runs never prompt
        and never resolve conflicts, duplicates or deletes; those are queued
        for the app's Review badges and logged as warnings (exit 1).

        Note: the `sync` subcommand arrives in milestone M3. With an older
        build of the app the agent's runs fail with a usage error and do
        nothing'';

      interval = lib.mkOption {
        type = lib.types.nullOr lib.types.ints.positive;
        default =
          if sched.calendar == null
          then 3600
          else null;
        defaultText = lib.literalExpression "if calendar == null then 3600 else null";
        example = 1800;
        description = ''
          Run the sync every this many seconds (launchd `StartInterval`). If
          the Mac is asleep, launchd runs it once on wake. Mutually exclusive
          with {option}`calendar`.
        '';
      };

      calendar = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf (lib.types.attrsOf lib.types.int));
        default = null;
        example = lib.literalExpression ''[{ Minute = 0; } { Hour = 12; Minute = 30; }]'';
        description = ''
          Run the sync at these calendar times (launchd
          `StartCalendarInterval`; keys `Minute`, `Hour`, `Day`, `Weekday`,
          `Month`; a missing key is a wildcard, as in crontab). Mutually
          exclusive with {option}`interval`, which defaults to `null` when
          this is set.
        '';
      };

      extraArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = ["--quiet"];
        example = ["--verbose" "--max-apple-changes" "50"];
        description = ''
          Arguments appended after `sync`. The default `--quiet` keeps the log
          to warnings and errors.
        '';
      };

      logFile = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default =
          if primaryUserHome == null
          then null
          else "${primaryUserHome}/Library/Logs/Contacts2MdSync.log";
        defaultText = lib.literalExpression ''"''${system.primaryUserHome}/Library/Logs/Contacts2MdSync.log"'';
        example = "/Users/alice/Library/Logs/Contacts2MdSync/sync.log";
        description = ''
          Absolute path that receives the agent's stdout and stderr (launchd
          `StandardOutPath` / `StandardErrorPath`). launchd neither expands `~`
          nor creates missing directories, so the default is a file directly
          in the primary user's existing {file}`~/Library/Logs` (visible in
          Console.app). If you pick another path, its directory must already
          exist. The file is appended to and never rotated. `null` discards
          output.
        '';
      };

      appPath = lib.mkOption {
        type = lib.types.str;
        default = "/Applications/Nix Apps/Contacts2MdSync.app";
        description = ''
          The app bundle the agent runs (its `Contents/MacOS/Contacts2MdSync`
          executable). This is the copy nix-darwin places in
          {file}`/Applications/Nix Apps`, not the store path: macOS ties the
          Contacts permission and the saved folder bookmark to the app you
          opened, and the store path changes on every rebuild. Running the app
          executable directly (rather than a separate CLI binary) is what
          lets the headless run use the app's Contacts grant.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      nixpkgs.overlays = [self.overlays.default];
      environment.systemPackages = [cfg.package];
    }

    (lib.mkIf sched.enable {
      assertions = [
        {
          assertion = (sched.interval == null) != (sched.calendar == null);
          message = "programs.contacts2mdsync.schedule: set exactly one of `interval` or `calendar`.";
        }
        {
          assertion = sched.logFile == null || lib.hasPrefix "/" sched.logFile;
          message = "programs.contacts2mdsync.schedule.logFile must be an absolute path (launchd does not expand ~).";
        }
      ];

      launchd.user.agents.contacts2mdsync-sync.serviceConfig =
        {
          ProgramArguments =
            ["${sched.appPath}/Contents/MacOS/Contacts2MdSync" "sync"]
            ++ sched.extraArgs;
          RunAtLoad = false;
          ProcessType = "Background";
          LowPriorityIO = true;
          Nice = 10;
        }
        // lib.optionalAttrs (sched.interval != null) {StartInterval = sched.interval;}
        // lib.optionalAttrs (sched.calendar != null) {StartCalendarInterval = sched.calendar;}
        // lib.optionalAttrs (sched.logFile != null) {
          StandardOutPath = sched.logFile;
          StandardErrorPath = sched.logFile;
        };
    })
  ]);
}
