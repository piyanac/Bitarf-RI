// swift-tools-version:5.9
//
//  Package.swift
//  Bitarf RI
//
//  NOTE: The shipping build is Bitarf RI.xcodeproj. This manifest exists
//  only so that the platform-neutral core (Sources/BitarfRICore) can be compiled
//  and unit-tested quickly from the command line:
//
//      swift build
//      swift test
//
//  The app target in the Xcode project compiles the *same* files directly (via a
//  file-system-synchronized group), so BitarfRICore is never imported as a module
//  from app code — do not add `import BitarfRICore` to anything under
//  Bitarf RI/.
//

import Foundation
import PackageDescription

// `Tests/` is untracked by project convention, so a fresh clone has no test
// sources. Declaring the target unconditionally would make `swift build` fail
// there for a directory that was never meant to ship.
let hasTests = FileManager.default.fileExists(
    atPath: URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Tests/BitarfRICoreTests")
        .path
)

let package = Package(
    name: "BitarfRICore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "BitarfRICore", targets: ["BitarfRICore"]),
    ],
    targets: [
        .target(
            name: "BitarfRICore",
            path: "Sources/BitarfRICore"
        ),
    ]
)

if hasTests {
    package.targets.append(
        .testTarget(
            name: "BitarfRICoreTests",
            dependencies: ["BitarfRICore"],
            path: "Tests/BitarfRICoreTests"
        )
    )
}
