# Contacts2MdSync.app from a published GitHub release: the Developer ID
# signed, notarized and stapled zip built by scripts/release.sh.
#
# Pure and sandbox-safe (unlike ./package.nix). The app's code signature is
# Apple-issued and stable across versions, so macOS keeps the Contacts and
# Automation (TCC) grants and the app's folder bookmark across upgrades.
#
# Nothing may touch the bundle after unpacking: any byte changed inside
# Contacts2MdSync.app breaks the signature (and the stapled ticket). Hence
# dontFixup (no strip, no patchShebangs, no install_name rewrites) and plain
# unzip into $out.
#
# Version and hash come from ./release.json; bump them with
# scripts/update-release-nix.sh. flake.nix only exposes this package once that
# file holds a real hash.
{
  lib,
  stdenvNoCC,
  fetchurl,
  unzip,
  releaseInfo,
}: let
  appName = "Contacts2MdSync";
  inherit (releaseInfo) version;
in
  stdenvNoCC.mkDerivation {
    pname = "contacts2mdsync";
    inherit version;

    src = fetchurl {
      url = "https://github.com/zmre/contacts2mdsync/releases/download/v${version}/${appName}-${version}.zip";
      inherit (releaseInfo) hash;
    };

    nativeBuildInputs = [unzip];

    dontUnpack = true;
    dontConfigure = true;
    dontBuild = true;
    dontFixup = true;

    # bin/contacts2md execs the app binary so the CLI runs as the app's code
    # identity (its Contacts grant and folder bookmark; architecture §15).
    installPhase = ''
      runHook preInstall
      mkdir -p $out/Applications $out/bin
      unzip -q $src -d $out/Applications
      rm -rf $out/Applications/__MACOSX
      test -x "$out/Applications/${appName}.app/Contents/MacOS/${appName}" || {
        echo "error: ${appName}.app/Contents/MacOS/${appName} missing from the release zip" >&2
        exit 1
      }
      cat > $out/bin/contacts2md <<EOF
      #!/bin/sh
      exec "$out/Applications/${appName}.app/Contents/MacOS/${appName}" "\$@"
      EOF
      chmod +x $out/bin/contacts2md
      runHook postInstall
    '';

    passthru.fromRelease = true;

    meta = {
      description = "Two-way sync between Apple Contacts and markdown notes (notarized release build)";
      homepage = "https://github.com/zmre/contacts2mdsync";
      sourceProvenance = [lib.sourceTypes.binaryNativeCode];
      platforms = lib.platforms.darwin;
      mainProgram = "contacts2md";
    };
  }
