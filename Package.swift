// swift-tools-version:6.0
import PackageDescription

// Hard constraint (design doc §8): the Mac Pro 5,1 target is a Westmere
// Xeon — SSE4.2 is the ceiling, no AVX/AVX2/FMA/F16C. A binary built on
// the (likely newer, AVX2-capable) Intel MacBook must still run on the
// Mac Pro without hitting an illegal instruction — which, inside the
// Phase 1.5 HAL plugin, would crash coreaudiod and take down all system
// audio. Swift's default x86_64 codegen for this triple is already
// baseline (no AVX) unless explicitly requested, but every C target in
// this package pins the baseline explicitly anyway, defensively, rather
// than relying on that default silently staying true. build.sh re-checks
// this after the fact by disassembling the actual build products.
let westmereCFlags: [CSetting] = [
    .unsafeFlags([
        "-march=westmere",
        "-mno-avx", "-mno-avx2", "-mno-fma", "-mno-f16c",
    ])
]

let westmereSwiftFlags: [SwiftSetting] = [
    .unsafeFlags(["-Xcc", "-march=westmere"])
]

let package = Package(
    name: "SoundCast",
    // .v14 only declares a floor of macOS 14.0, which isn't enough to
    // satisfy the process-tap API's actual macOS 14.2 availability
    // requirement at compile time — bumped to .v15 to clear that, which
    // is still far below both real target machines' Tahoe (26.x).
    platforms: [.macOS(.v15)],
    dependencies: [
        // SRP-6a (AirPlay/HomeKit pair-setup, design doc §12) needs
        // correct, non-trivial modular exponentiation over 3072-bit
        // integers — reimplementing that by hand risks subtle
        // correctness/timing bugs in security-sensitive code, so this
        // one well-known, audited dependency is worth it.
        .package(url: "https://github.com/attaswift/BigInt.git", from: "5.3.0"),
    ],
    targets: [
        // Swift can't call shm_open directly (it's declared variadic in
        // Darwin's headers; Swift refuses to bridge any variadic C
        // function, even with the variadic arg unused) — this tiny C
        // target provides a fixed-signature wrapper SoundCastCore can
        // call instead. See Sources/CSoundCastSHM/shim.c.
        .target(
            name: "CSoundCastSHM",
            path: "Sources/CSoundCastSHM",
            cSettings: westmereCFlags
        ),
        // Non-UI Core Audio/capture/output logic, shared by the real app
        // and the smoke-test CLI tool below — split out specifically so
        // the smoke test can exercise the exact same code without
        // needing SwiftUI/AppKit or a full .app bundle around it.
        .target(
            name: "SoundCastCore",
            dependencies: [
                "CSoundCastSHM",
                .product(name: "BigInt", package: "BigInt"),
            ],
            path: "Sources/SoundCastCore",
            swiftSettings: westmereSwiftFlags,
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit"),
                .linkedFramework("Security"),
            ]
        ),
        .executableTarget(
            name: "SoundCast",
            dependencies: ["SoundCastCore"],
            path: "Sources/SoundCast",
            swiftSettings: westmereSwiftFlags,
            linkerSettings: [
                .linkedFramework("SwiftUI"),
                .linkedFramework("AppKit"),
                .linkedFramework("AVFAudio"),
            ]
        ),
        // Autonomous test tool (no UI, no privacy-consent prompt) for the
        // local multi-output path — see Sources/LocalOutputSmokeTest/main.swift.
        .executableTarget(
            name: "LocalOutputSmokeTest",
            dependencies: ["SoundCastCore"],
            path: "Sources/LocalOutputSmokeTest",
            swiftSettings: westmereSwiftFlags,
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        // Full-pipeline test tool (capture + local output chained) — see
        // Sources/CaptureSmokeTest/main.swift. Needs the one-time human
        // permission click, unlike LocalOutputSmokeTest.
        .executableTarget(
            name: "CaptureSmokeTest",
            dependencies: ["SoundCastCore"],
            path: "Sources/CaptureSmokeTest",
            swiftSettings: westmereSwiftFlags,
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        // Phase 1.5 pipeline test (virtual-device shared-memory capture
        // + local output chained) — see
        // Sources/VirtualDeviceSmokeTest/main.swift. No permission
        // click needed, unlike CaptureSmokeTest.
        .executableTarget(
            name: "VirtualDeviceSmokeTest",
            dependencies: ["SoundCastCore"],
            path: "Sources/VirtualDeviceSmokeTest",
            swiftSettings: westmereSwiftFlags,
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        // Phase 2 step 1 test (design doc §12): Bonjour discovery of
        // _airplay._tcp receivers only — no pairing/connection yet. See
        // Sources/AirPlayDiscoverySmokeTest/main.swift.
        .executableTarget(
            name: "AirPlayDiscoverySmokeTest",
            dependencies: ["SoundCastCore"],
            path: "Sources/AirPlayDiscoverySmokeTest",
            swiftSettings: westmereSwiftFlags,
            linkerSettings: [
                .linkedFramework("Network"),
            ]
        ),
        // Phase 2 step 2 test (design doc §12): exercises the real
        // AirPlayRTSPConnection/TLV8/pair-verify wire protocol against a
        // real AirPlay 2 receiver. See
        // Sources/AirPlayPairingSmokeTest/main.swift.
        .executableTarget(
            name: "AirPlayPairingSmokeTest",
            dependencies: ["SoundCastCore"],
            path: "Sources/AirPlayPairingSmokeTest",
            swiftSettings: westmereSwiftFlags,
            linkerSettings: [
                .linkedFramework("Network"),
                .linkedFramework("CryptoKit"),
            ]
        ),
    ]
)
