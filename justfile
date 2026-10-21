# Contacts2MdSync tasks. Run inside the dev shell: `nix develop -c just <recipe>`.

project := "App/Contacts2MdSync.xcodeproj"
scheme := "Contacts2MdSync"
derived := "build/DerivedData"
package := "Packages/Contacts2MdSyncKit"
swift_paths := "App/Contacts2MdSync " + package + "/Sources " + package + "/Tests " + package + "/Package.swift"

default:
    @just --list

# Generate the Xcode project from App/project.yml
gen:
    cd App && xcodegen generate

# Build the app (Debug)
build: gen
    set -o pipefail && /usr/bin/xcodebuild \
        -project {{project}} -scheme {{scheme}} -configuration Debug \
        -destination 'platform=macOS' -derivedDataPath {{derived}} build | xcbeautify

# Launch the Debug build
run: build
    open {{derived}}/Build/Products/Debug/Contacts2MdSync.app

# Run the package test suite
test:
    swift test --package-path {{package}}

# Lint Swift sources
lint:
    swiftlint lint --strict --quiet
    swift-format lint --strict --recursive --parallel {{swift_paths}}

# Format Swift sources in place
fmt:
    swift-format format --in-place --recursive --parallel {{swift_paths}}
    swiftlint lint --fix --quiet

# Remove build products and the generated project
clean:
    rm -rf build App/Contacts2MdSync.xcodeproj {{package}}/.build

# Build the app via Nix (impure: needs sandbox = false/relaxed)
nix-build:
    nix build path:.#default
