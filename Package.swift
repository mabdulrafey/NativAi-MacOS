// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "NativAI",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "NativAI",
            path: "Sources/NativAI",
            resources: [
                .copy("Resources/catalog.json")
            ]
        ),
        // Pure-logic core, compiled a second time for testing.
        //
        // The app target is an executable, which XCTest cannot import, and the
        // views are @MainActor SwiftUI/AppKit types that don't belong in a unit
        // test anyway. Rather than restructure the whole app (which would also
        // break the flat file layout the Xcode project's synchronized folders
        // depend on), this target compiles just the Foundation-only decision
        // logic — routing, budgeting, compaction and persistence — which is where
        // a silent regression actually costs the user something.
        //
        // `Tests/NativAICoreTests/Core/` holds symlinks to those production
        // files. SPM rejects `../` paths in `sources` (it excludes them without
        // an error, which shows up confusingly as "cannot find X in scope"), but
        // it does follow symlinks. That keeps exactly one real copy of each file
        // in the repository, so the tests can never drift from the code they test.
        .testTarget(
            name: "NativAICoreTests",
            path: "Tests/NativAICoreTests"
        )
    ]
)
