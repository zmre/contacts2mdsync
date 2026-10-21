# nix-darwin module for Contacts2MdSync.
#
#   imports = [ contacts2mdsync.darwinModules.default ];
#   programs.contacts2mdsync.enable = true;
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
in {
  options.programs.contacts2mdsync = {
    enable = lib.mkEnableOption "Contacts2MdSync, a two-way Apple Contacts <-> markdown sync app";

    package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.contacts2mdsync;
      defaultText = lib.literalExpression "pkgs.contacts2mdsync";
      description = "The Contacts2MdSync package to install.";
    };
  };

  config = lib.mkIf cfg.enable {
    nixpkgs.overlays = [self.overlays.default];
    environment.systemPackages = [cfg.package];
  };
}
