import Foundation
import XCTest

@testable import LavaSecAppServices

/// Ratchet over the engine's dependency lock so a new third-party crate cannot enter the
/// shipped binary without someone deciding whether it needs an attribution notice.
///
/// The engine's Apple-target archives are compiled into a static library that ships inside
/// the app. The generated notice file carries the package versions, copyright holders, and
/// license texts for the Cargo dependencies and the pinned Rust sysroot crates actually
/// present in those archives. BoringTun also has a concise product-facing entry below.
///
/// The notices themselves are GENERATED — `scripts/generate-wireguard-core-notices.mjs`
/// resolves the crate set from `cargo tree -e normal` for each shipped target triple and
/// emits `THIRD-PARTY-NOTICES.txt` plus a machine-readable index. That is why this file no
/// longer carries a hand-written list of pending crates: a list maintained by hand rots the
/// first time a transitive dependency moves, and the artifact reaches the public mirror
/// whether or not anyone remembered to update it.
///
/// What is still pinned here is the part generation cannot decide: that every crate in the
/// lock is either attributed or explicitly, justifiably not shipped.
final class BundledLibraryAttributionSourceTests: XCTestCase {
    /// Locked crates that are deliberately absent from the generated notices because they are
    /// never compiled into an Apple-target artifact.
    ///
    /// Three reasons, all verifiable by rerunning the generator: other platforms
    /// (`windows_*`, `wasi`, `redox_syscall`); build-time-only tooling that runs on the host
    /// and emits nothing into the binary (`cc`, `shlex`, `find-msvc-tools`, `version_check`,
    /// `rustc_version`, `semver`, `cfg_aliases`, and the `serde` trio those build scripts
    /// use); and backends that `curve25519-dalek` cfg-selects away on aarch64
    /// (`fiat-crypto`, `cpufeatures`, `curve25519-dalek-derive`).
    ///
    /// This is an exclusion list, so it fails safe in the wrong direction — an entry added
    /// here silently drops a notice. `testExclusionsAreNotAQuietWayToDropAttribution` is what
    /// keeps it honest: nothing may be excluded that the generator actually attributed.
    private let cratesNotCompiledForAppleTargets: Set<String> = [
        "cc", "cfg_aliases", "cpufeatures", "curve25519-dalek-derive",
        "fiat-crypto", "find-msvc-tools", "redox_syscall", "rustc_version",
        "semver", "serde", "serde_core", "serde_derive",
        "shlex", "version_check", "wasi", "windows-link",
        "windows-sys", "windows-targets", "windows_aarch64_gnullvm", "windows_aarch64_msvc",
        "windows_i686_gnu", "windows_i686_gnullvm", "windows_i686_msvc", "windows_x86_64_gnu",
        "windows_x86_64_gnullvm", "windows_x86_64_msvc",
    ]

    private struct NoticesIndex: Decodable {
        struct Crate: Decodable {
            let name: String
            let version: String
            let license: String?
        }
        let targets: [String]
        let crates: [Crate]
        let unresolved: [String]
    }

    private func noticesIndex() throws -> NoticesIndex {
        let data = Data(try readSource(.wireGuardCoreNoticesIndex).utf8)
        return try JSONDecoder().decode(NoticesIndex.self, from: data)
    }

    private func lockedCrateNames() throws -> Set<String> {
        let lock = try readSource(.wireGuardCoreLock)
        var names: Set<String> = []
        for line in lock.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("name = \"") , trimmed.hasSuffix("\"") else { continue }
            let value = trimmed.dropFirst("name = \"".count).dropLast()
            names.insert(String(value))
        }
        return names
    }

    func testEveryLockedCrateIsAttributedOrExcludedWithReason() throws {
        let locked = try lockedCrateNames()
        XCTAssertFalse(locked.isEmpty, "failed to parse any package name from the engine lock")

        // Our own crate owes itself no attribution.
        let ownCrate = "lavasec-wireguard-core"
        XCTAssertTrue(locked.contains(ownCrate))

        let attributed = Set(try noticesIndex().crates.map(\.name))
        XCTAssertTrue(attributed.contains("boringtun"), "the anchor project must stay attributed")

        let unaccounted = locked
            .subtracting(attributed)
            .subtracting(cratesNotCompiledForAppleTargets)
            .subtracting([ownCrate])
        XCTAssertEqual(
            unaccounted,
            [],
            "a new engine dependency is neither attributed nor excluded. Regenerate with "
                + "`node scripts/generate-wireguard-core-notices.mjs`; if it genuinely does not "
                + "compile for an Apple target, add it to cratesNotCompiledForAppleTargets with "
                + "the reason."
        )
    }

    func testExclusionsAreNotAQuietWayToDropAttribution() throws {
        let locked = try lockedCrateNames()
        let attributed = Set(try noticesIndex().crates.map(\.name))

        // The dangerous direction. Excluding a crate the generator DID attribute would remove
        // a notice we owe while every other test stays green.
        XCTAssertEqual(
            cratesNotCompiledForAppleTargets.intersection(attributed),
            [],
            "this crate is compiled into the artifact — it cannot be excluded as non-Apple"
        )
        XCTAssertEqual(
            cratesNotCompiledForAppleTargets.subtracting(locked),
            [],
            "a crate that is no longer a dependency must be removed from the exclusion list"
        )
    }

    func testEveryAttributedCrateCarriesLicenseTextAndAHolder() throws {
        let index = try noticesIndex()
        let notices = try readSource(.wireGuardCoreNotices)

        XCTAssertEqual(
            index.unresolved,
            [],
            "the generator could not resolve a license for every crate; unresolved attribution "
                + "must be fixed, not shipped"
        )
        XCTAssertGreaterThan(index.crates.count, 40, "the generated crate set looks truncated")

        for crate in index.crates {
            XCTAssertNotNil(crate.license, "\(crate.name) has no SPDX license expression")
            XCTAssertTrue(
                notices.contains("\(crate.name) \(crate.version)"),
                "\(crate.name) is indexed but missing from the rendered notices"
            )
        }
        // Apache-2.0 is hard-wrapped, so its own prose yields lines beginning with
        // "copyright" that name nobody. Those must never be rendered as if they were
        // attributions — a fabricated holder is worse than an absent one.
        // Scoped to the PACKAGES section on purpose: these phrases appear legitimately in
        // the reproduced Apache-2.0 body further down, which we are obliged to include
        // verbatim. The defect is them appearing as a crate's attribution, not at all.
        // GUARDED, and the `?? startIndex` / `?? endIndex` defaults are exactly why it needs to be:
        // they make the expression LOOK like the safe whole-string shape while both real bounds
        // come from independent searches. Reordering the two headings would trap here — and a trap
        // kills the xctest process, so the whole bundle reports nothing instead of this one test
        // going red (Codex P2, PR #605).
        let packagesStart = notices.range(of: "PACKAGES (")?.lowerBound ?? notices.startIndex
        let licenseTextsStart =
            notices.range(of: "LICENSE TEXTS (")?.lowerBound ?? notices.endIndex
        guard packagesStart <= licenseTextsStart else {
            return XCTFail("PACKAGES must precede LICENSE TEXTS in the rendered notices")
        }
        let packagesSection = String(notices[packagesStart..<licenseTextsStart]).lowercased()
        for boilerplate in ["copyright license to reproduce", "copyright notice that is included"] {
            XCTAssertFalse(
                packagesSection.contains(boilerplate),
                "license prose is being presented as a copyright holder"
            )
        }
        // Naming a license without reproducing it is the failure mode these licenses exist to
        // prevent — BSD-3 clause 2 and the MIT notice clause both require the TEXT to travel.
        XCTAssertFalse(
            notices.contains("Text:       NONE PROVIDED BY THE CRATE"),
            "a crate reached the notices with no license text"
        )
    }

    func testTheAppShipsTheSameNoticesTheRepoRecords() throws {
        // The app cannot reference ThirdParty/ (check-xcodegen-sources forbids that root for
        // app targets), but the licenses require the text to travel with the binary — so the
        // generator emits a second copy inside the app's source root. Two files is a drift
        // risk by construction, which is why one generator owns both and --check verifies
        // both. This asserts the invariant the packaging depends on: they are identical.
        let repoCopy = try readSource(.wireGuardCoreNotices)
        let appCopy = try readSource(.appBundledLibraryNotices)
        XCTAssertEqual(
            appCopy, repoCopy,
            "the shipped notice text drifted from the generated one — regenerate, never hand-edit"
        )
        XCTAssertTrue(appCopy.contains("boringtun"), "the shipped copy looks truncated")
    }

    func testTheGeneratedSetCoversExactlyTheShippedSlices() throws {
        let index = try noticesIndex()
        let buildScript = try readSource(.buildWireGuardCoreScript)

        // DERIVED from the build script, not re-listed here. A hardcoded copy of the triples
        // passes forever after a fourth slice is added: the old three are still in both
        // places, so the assertion stays green while the generator silently omits the new
        // slice's crates. Set equality against the script's own definition is the only form
        // that fails when they diverge.
        let definition = try XCTUnwrap(
            buildScript.range(of: "targets=(").map { range in
                String(buildScript[range.upperBound...].prefix(while: { $0 != ")" }))
            },
            "the build script's targets=(...) definition moved — this test derives from it"
        )
        let shippedSlices = Set(definition.split(whereSeparator: \.isWhitespace).map(String.init))

        XCTAssertFalse(shippedSlices.isEmpty, "parsed no targets from the build script")
        XCTAssertEqual(
            Set(index.targets),
            shippedSlices,
            "the generator's enumerated triples and the slices the build script produces have "
                + "diverged — a slice can otherwise ship code nobody counted"
        )
    }
    func testLinkingTheEngineRequiresRenderingItsNotices() throws {
        let project = try readSource(.projectYAML)
        let legalScreen = try [readSource(.legalVersionSettingsView), readSource(.reactNativeReferenceContent)].joined(separator: "\n")

        let aProductionTargetLinksTheEngine = project.contains("product: LavaSecChainedUpstream")
        let theScreenRendersBundledLibraries = legalScreen.contains("bundledLibraryNotices")

        if aProductionTargetLinksTheEngine {
            XCTAssertTrue(
                theScreenRendersBundledLibraries,
                "a shipped target now contains BoringTun, so LegalNoticesView must render "
                    + "ThirdPartyLegalNotices.bundledLibraryNotices — attribution for a bundled "
                    + "library is owed to the user, not just to the repository"
            )
        }

        // Non-vacuous regardless of the branch above: the data the screen will render must exist.
        XCTAssertFalse(
            ThirdPartyLegalNotices.bundledLibraryNotices.isEmpty,
            "the bundled-library notice set must never be emptied while the engine is vendored"
        )
    }
}
