// swift-tools-version: 6.2
//
// Contacts2MdSyncKit: all non-UI logic for Contacts2MdSync lives here so it can
// be built and tested with `swift test` without Xcode or the app target.
//
// Dependency graph (arrows point at dependencies):
//
//   contacts2md (exe) -> Contacts2MdCLI -> SyncEngine      -> VaultIndex -> MarkdownCodec -> ContactModel, Yams
//                                       -> SyncTriggers    -> SyncEngine (+ Contacts, FSEvents, AppKit notifications)
//                                       -> SyncStateDB     -> SyncEngine, GRDB
//                                       -> ContactsAdapter -> ContactModel, ContactsShim
//                                       -> PhoneNumberKeys -> ContactModel, PhoneNumberKit
//                                       -> ArgumentParser
//   SyncTestSupport -> SyncEngine, SyncTriggers, PhoneNumberKeys
//
// The engine never imports Contacts.framework: it sees Apple Contacts only
// through the `ContactStore` protocol (ContactModel), implemented by
// ContactsAdapter for real and by SyncTestSupport's FakeContactStore in tests.
//
// Per-device sync state (architecture §4) is defined by the `SyncStateStore`
// protocol in SyncEngine; SyncStateDB implements it on SQLite via GRDB.

import PackageDescription

let swiftSettings: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .treatWarning("UnusedImportAccess", as: .error),
]

let package = Package(
    name: "Contacts2MdSyncKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
    ],
    products: [
        .library(name: "ContactModel", targets: ["ContactModel"]),
        .library(name: "PhoneNumberKeys", targets: ["PhoneNumberKeys"]),
        .library(name: "MarkdownCodec", targets: ["MarkdownCodec"]),
        .library(name: "ContactsShim", targets: ["ContactsShim"]),
        .library(name: "ContactsAdapter", targets: ["ContactsAdapter"]),
        .library(name: "VaultIndex", targets: ["VaultIndex"]),
        .library(name: "SyncEngine", targets: ["SyncEngine"]),
        .library(name: "SyncStateDB", targets: ["SyncStateDB"]),
        .library(name: "SyncTriggers", targets: ["SyncTriggers"]),
        .library(name: "Contacts2MdCLI", targets: ["Contacts2MdCLI"]),
        .library(name: "SyncTestSupport", targets: ["SyncTestSupport"]),
        .executable(name: "contacts2md", targets: ["contacts2md"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.0"),
        .package(url: "https://github.com/PhoneNumberKit/PhoneNumberKit.git", from: "5.0.12"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1"),
    ],
    targets: [
        .target(
            name: "ContactModel",
            swiftSettings: swiftSettings
        ),
        .target(
            name: "PhoneNumberKeys",
            dependencies: [
                "ContactModel",
                .product(name: "PhoneNumberKit", package: "PhoneNumberKit"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "MarkdownCodec",
            dependencies: [
                "ContactModel",
                .product(name: "Yams", package: "Yams"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "ContactsShim",
            linkerSettings: [.linkedFramework("Contacts")]
        ),
        .target(
            name: "ContactsAdapter",
            dependencies: ["ContactModel", "ContactsShim"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "VaultIndex",
            dependencies: ["ContactModel", "MarkdownCodec"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SyncEngine",
            dependencies: [
                "ContactModel",
                "MarkdownCodec",
                "VaultIndex",
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SyncStateDB",
            dependencies: [
                "SyncEngine",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SyncTriggers",
            dependencies: ["ContactModel", "SyncEngine", "VaultIndex"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "Contacts2MdCLI",
            dependencies: [
                "ContactModel",
                "ContactsAdapter",
                "PhoneNumberKeys",
                "SyncEngine",
                "SyncStateDB",
                "SyncTriggers",
                "VaultIndex",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: swiftSettings
        ),
        .executableTarget(
            name: "contacts2md",
            dependencies: ["Contacts2MdCLI"],
            swiftSettings: swiftSettings
        ),
        .target(
            name: "SyncTestSupport",
            dependencies: [
                "ContactModel", "MarkdownCodec", "PhoneNumberKeys", "SyncEngine", "SyncTriggers", "VaultIndex",
            ],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ContactModelTests",
            dependencies: ["ContactModel", "PhoneNumberKeys"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "MarkdownCodecTests",
            dependencies: [
                "MarkdownCodec", "ContactModel", "SyncTestSupport", .product(name: "Yams", package: "Yams"),
            ],
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "ContactsAdapterTests",
            dependencies: ["ContactsAdapter", "ContactModel"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SyncEngineTests",
            dependencies: [
                "SyncEngine", "SyncTestSupport", "ContactModel", "MarkdownCodec", "VaultIndex", "PhoneNumberKeys",
            ],
            exclude: ["Fixtures"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SyncTriggersTests",
            dependencies: ["SyncTriggers", "SyncEngine", "SyncTestSupport", "ContactModel", "VaultIndex"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "SyncStateDBTests",
            dependencies: ["SyncStateDB", "SyncEngine", "ContactModel", "VaultIndex"],
            swiftSettings: swiftSettings
        ),
        .testTarget(
            name: "Contacts2MdCLITests",
            dependencies: [
                "Contacts2MdCLI", "SyncTestSupport", "SyncEngine", "SyncTriggers", "ContactModel", "VaultIndex",
                "PhoneNumberKeys",
            ],
            swiftSettings: swiftSettings
        ),
    ]
)
