# Contacts2MdSync.app built from source with the system Xcode.
#
# IMPURE BUILD. This derivation sets `__noChroot = true` because it must run
# /usr/bin/xcodebuild from the host's Xcode install and let SwiftPM fetch
# package dependencies (Yams) over the network. Nix only honours __noChroot
# when the daemon's sandbox is disabled or relaxed:
#
#   nix.settings.sandbox = "relaxed";   # nix-darwin; or `false`
#
# With `sandbox = true` the build is refused. Pinning still comes from the
# committed Packages/Contacts2MdSyncKit/Package.resolved (see buildPhase).
{
  lib,
  stdenvNoCC,
  xcodegen,
}: let
  root = ../.;
  fs = lib.fileset;
  # Only what the Xcode build reads, so editing docs/ or flake.nix does not
  # trigger a rebuild. Local SwiftPM/Xcode state is excluded if present.
  fileset =
    fs.difference (fs.unions [
      (root + "/App")
      (root + "/Packages")
    ]) (fs.unions [
      (fs.maybeMissing (root + "/Packages/Contacts2MdSyncKit/.build"))
      (fs.maybeMissing (root + "/Packages/Contacts2MdSyncKit/.swiftpm"))
      (fs.maybeMissing (root + "/App/Contacts2MdSync.xcodeproj"))
      (fs.maybeMissing (root + "/App/build"))
    ]);

  appName = "Contacts2MdSync";

  # MARKETING_VERSION from App/project.yml, the single source of the version.
  version = let
    lines = lib.splitString "\n" (builtins.readFile (root + "/App/project.yml"));
    matches = map (builtins.match "[[:space:]]*MARKETING_VERSION:[[:space:]]*\"?([0-9][0-9.]*)\"?[[:space:]]*") lines;
    found = lib.findFirst (m: m != null) null matches;
  in
    if found == null
    then "0.0.0"
    else lib.head found;

  # Ad-hoc builds are signed with the Dev entitlements. The Release file adds
  # com.apple.developer.contacts.notes, a managed entitlement that AMFI only
  # honours with a provisioning profile; ad-hoc code carrying it is killed at
  # launch. Ship-quality builds use Xcode with a real team/profile instead.
  entitlements = ../App/Contacts2MdSync/Contacts2MdSync.Dev.entitlements;
in
  stdenvNoCC.mkDerivation {
    pname = "contacts2mdsync";
    inherit version;

    src = fs.toSource {inherit root fileset;};

    __noChroot = true;

    nativeBuildInputs = [xcodegen];

    # Xcode already produces a release binary; Nix's strip would rewrite the
    # Mach-O for no benefit. (Signing happens in postFixup regardless.)
    dontStrip = true;

    buildPhase = ''
      runHook preBuild

      export HOME=$TMPDIR
      # Foundation ignores $HOME and resolves ~ via getpwuid(), which for the
      # nixbld user is the unwritable /var/empty; SwiftPM then fails writing
      # ~/Library/Caches/org.swift.swiftpm. CFFIXED_USER_HOME overrides it.
      export CFFIXED_USER_HOME=$TMPDIR
      # xcodegen and xcodebuild both expect a login-ish environment.
      export USER="''${USER:-$(/usr/bin/id -un)}"
      # stdenv may point these at a nixpkgs SDK; xcodebuild must use Xcode's.
      unset DEVELOPER_DIR SDKROOT
      export PATH="$PATH:/usr/bin:/bin:/usr/sbin:/sbin"

      (cd App && xcodegen generate --quiet)

      # Seed the generated workspace with the package's committed pins so
      # SwiftPM resolves exactly those versions (the only remote deps are the
      # local package's).
      resolved=App/${appName}.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
      mkdir -p "$resolved"
      cp Packages/Contacts2MdSyncKit/Package.resolved "$resolved/Package.resolved"

      # The Nix builder already runs under a macOS sandbox profile, and
      # sandbox_apply cannot nest, so SwiftPM's own manifest/plugin
      # sandbox-exec fails with "Operation not permitted". The two
      # -IDEPackageSupportDisable*Sandbox user-default overrides turn it off.
      # The Swift compiler likewise sandboxes macro plugins (@Observable,
      # @State, #Preview) via swift-plugin-server; -disable-sandbox stops it.
      /usr/bin/xcodebuild \
        -project App/${appName}.xcodeproj \
        -scheme ${appName} \
        -configuration Release \
        -destination "platform=macOS" \
        -derivedDataPath $TMPDIR/dd \
        -clonedSourcePackagesDirPath $TMPDIR/spm \
        -packageCachePath $TMPDIR/spm-cache \
        -onlyUsePackageVersionsFromResolvedFile \
        -skipMacroValidation \
        -skipPackagePluginValidation \
        -IDEPackageSupportDisableManifestSandbox=YES \
        -IDEPackageSupportDisablePluginSandbox=YES \
        'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox' \
        CODE_SIGNING_ALLOWED=NO \
        build

      runHook postBuild
    '';

    # bin/contacts2md execs the app binary: the CLI must run as the app's
    # code identity to use its Contacts grant and folder bookmark
    # (architecture §15). It lives outside the bundle, so signing below does
    # not cover (or break on) it.
    installPhase = ''
      runHook preInstall
      mkdir -p $out/Applications $out/bin
      cp -R $TMPDIR/dd/Build/Products/Release/${appName}.app $out/Applications/
      cat > $out/bin/contacts2md <<EOF
      #!/bin/sh
      exec "$out/Applications/${appName}.app/Contents/MacOS/${appName}" "\$@"
      EOF
      chmod +x $out/bin/contacts2md
      runHook postInstall
    '';

    # Signing is the LAST thing that touches the bundle (postFixup is the final
    # hook of fixupPhase). Anything that rewrites a Mach-O after signing
    # silently discards the signature and its entitlements.
    postFixup = ''
      app=$out/Applications/${appName}.app

      # Copied trees can carry read-only modes; codesign must write
      # Contents/_CodeSignature inside the bundle.
      chmod -R u+w "$app"
      # Build-machine xattrs (com.apple.provenance etc.) perturb the seal.
      /usr/bin/xattr -cr "$app"

      # No nested code to sign first: SwiftPM products link statically.
      # --deep is deliberately not used for signing (it would re-sign nested
      # code with these entitlements); it is used for verification below.
      /usr/bin/codesign --force --sign - --options runtime \
        --entitlements ${entitlements} \
        "$app"

      # Shared with scripts/release.sh. Verifies the signature (--deep
      # --strict), hardened runtime, ad-hoc signing and that EVERY key and
      # string value in the entitlements file made it into the signature
      # (codesign exits 0 even when it fails to parse the file and then signs
      # with none). Optional entitlements such as
      # com.apple.security.automation.apple-events and
      # com.apple.security.temporary-exception.apple-events
      # (com.apple.AddressBook) are therefore expected exactly when the file
      # has them; automation.apple-events additionally requires
      # NSAppleEventsUsageDescription in Info.plist.
      bash ${../scripts/verify-app.sh} \
        --adhoc \
        --identifier com.zmre.contacts2mdsync \
        --forbid com.apple.developer.contacts.notes \
        "$app" ${entitlements}

      # The CLI wrapper must exec the signed app binary.
      /usr/bin/grep -q "Contents/MacOS/${appName}" $out/bin/contacts2md || {
        echo "error: bin/contacts2md does not exec the app binary" >&2
        exit 1
      }
    '';

    meta = {
      description = "Two-way sync between Apple Contacts and markdown notes";
      platforms = lib.platforms.darwin;
    };
  }
