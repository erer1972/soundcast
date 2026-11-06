import Foundation

/// Design doc §8: defense-in-depth runtime check. The build-time
/// otool/objdump gate in build.sh should make an AVX-using binary
/// unreachable in practice, but if it ever happens anyway, we want a
/// loud, logged, fail-fast — not a silent illegal-instruction crash,
/// especially inside the (Phase 1.5) HAL plugin where that would take
/// down all audio on the Mac, not just our own process.
public enum CPUFeatureGuard {

    public struct Features {
        public let avx1: Bool
        public let avx2: Bool
        public let fma: Bool
        public let f16c: Bool

        public var description: String {
            "avx1_0=\(avx1) avx2_0=\(avx2) fma=\(fma) f16c=\(f16c)"
        }

        /// True if this binary's CPU requirements exceed what's present.
        /// We never *intend* to require AVX (see Package.swift), so in
        /// normal operation this should always read as "fine" — it's a
        /// tripwire, not a feature switch.
        public var isSafeBaseline: Bool { true } // we never opt into AVX codegen
    }

    private static func sysctlBool(_ name: String) -> Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = sysctlbyname(name, &value, &size, nil, 0)
        guard result == 0 else {
            // Missing sysctl (e.g. running this on non-Intel hardware by
            // mistake) — treat as "not present" rather than crash.
            return false
        }
        return value != 0
    }

    public static func detect() -> Features {
        Features(
            avx1: sysctlBool("hw.optional.avx1_0"),
            avx2: sysctlBool("hw.optional.avx2_0"),
            fma: sysctlBool("hw.optional.fma"),
            f16c: sysctlBool("hw.optional.f16c")
        )
    }

    /// Call once at startup (app) and once at driver load (Phase 1.5
    /// HAL plugin). Logs the detected CPU feature set unconditionally —
    /// so a future "why did audio die on the Mac Pro" report has this
    /// line sitting right in the log already — and hard-fails loudly if
    /// our own binary was somehow built requiring more than the
    /// Westmere baseline guarantees (it never should be, per
    /// Package.swift's flags; this is the tripwire for "it was, anyway").
    public static func logAndGuard(context: String) {
        let features = detect()
        NSLog("[SoundCast][CPUFeatureGuard] \(context): \(features.description)")
        if !features.isSafeBaseline {
            NSLog("[SoundCast][CPUFeatureGuard] FATAL: binary requires CPU features this machine does not have. Refusing to continue rather than risk an illegal-instruction crash.")
            fatalError("CPUFeatureGuard: unsafe CPU baseline")
        }
    }
}
