import Foundation

/// Why a chained upstream could not be staged from a `.conf`.
///
/// Distinct cases because a QA operator reads them off a device screen with no debugger:
/// "which line of my file is wrong" and "this build may not stage at all" are different
/// problems with different fixes, and a single `invalidConf` would make the second one look
/// like the first.
public enum ChainedUpstreamStagingRefusal: Error, LocalizedError, Equatable {
    /// This build addresses the production secret store, so staging is refused.
    ///
    /// THE LOAD-BEARING CASE. See ``ChainedUpstreamStagingRequest``.
    case buildMayNotStage(ChainedUpstreamStoreIdentity)
    /// The build's two halves disagree about which identity it is.
    ///
    /// The FILE half follows `#if LAVA_QA_TOOLS` and the KEY half follows a per-configuration
    /// build setting, and nothing at runtime related them until this case existed — so a
    /// build compiled with `-D LAVA_QA_TOOLS` but NOT the QA configuration passed an
    /// identity-only refusal while committing the private key into the production access
    /// group. That is not hypothetical plumbing: injecting the define through
    /// `OTHER_SWIFT_FLAGS` is this repo's own documented technique for reaching package
    /// targets, and a developer who puts it in `Config/Lava.local.xcconfig` flags every
    /// configuration at once.
    case buildIdentityIsInconsistent(identity: ChainedUpstreamStoreIdentity, group: String)
    /// A `.conf` shape this feature does not carry, named rather than dropped.
    case unsupportedDirective(String)
    /// A required key is absent, or present more than once. Names the key.
    case missingOrRepeatedKey(String)
    /// A key this parser DOES support, in a section it does not belong to.
    ///
    /// Refused rather than ignored, for the reason the repeated-key and `Table = off` rules
    /// exist: the lookups are section-scoped, so `PersistentKeepalive` under `[Interface]`
    /// or `DNS` under `[Peer]` lands in the other dictionary and is never read — staging
    /// then succeeds with keepalive off, no resolvers, or the default MTU, and the file does
    /// not say what the tunnel does (Codex, PR #519). Naming the section is what separates
    /// this from "unsupported": the directive is fine, its placement is not.
    case directiveInWrongSection(directive: String, section: String)
    /// A key's value is not the shape the key requires. Names the key.
    case malformedValue(String)
    /// The parsed values were well-formed but the configuration validator refused them.
    /// Carries the validator's own verdict rather than restating it.
    case configurationRefused(ChainedUpstreamConfiguration.ValidationFailure)
    /// The parsed private key was refused at the rotation boundary — malformed, all-zero, or
    /// the peer's own key pasted into the `[Interface]` section.
    case rotationRefused(ChainedUpstreamSecretStoreFailure)

    /// Recovery copy for the shipping editor. Diagnostic payloads remain in the
    /// typed cases and log identifier; they never become a displayed error dump.
    public var errorDescription: String? {
        switch self {
        case .buildMayNotStage, .buildIdentityIsInconsistent:
            LavaCoreStrings.localized("This build can't save a WireGuard configuration. Update Lava and try again.")
        case .unsupportedDirective:
            LavaCoreStrings.localized("This WireGuard configuration uses a setting Lava doesn't support.")
        case .missingOrRepeatedKey:
            LavaCoreStrings.localized("A required WireGuard setting is missing or repeated.")
        case .directiveInWrongSection:
            LavaCoreStrings.localized("A WireGuard setting is in the wrong section.")
        case .malformedValue:
            LavaCoreStrings.localized("A WireGuard setting has an invalid value.")
        case .configurationRefused:
            LavaCoreStrings.localized("This WireGuard configuration isn't valid. Check its addresses, routes, MTU, and public key.")
        case .rotationRefused(let failure):
            failure.errorDescription
        }
    }

    /// A stable log identifier, never user copy.
    public var logValue: String {
        switch self {
        case .buildMayNotStage(let identity): return "staging-refused-build-\(identity.rawValue)"
        case .buildIdentityIsInconsistent(let identity, _):
            // The group string is NOT logged: it carries the team prefix, and the case's
            // whole subject is that it disagrees with the identity — which the identity
            // alone already says.
            return "staging-refused-inconsistent-\(identity.rawValue)"
        case .unsupportedDirective(let key): return "staging-unsupported-\(key)"
        case .missingOrRepeatedKey(let key): return "staging-missing-key-\(key)"
        case .directiveInWrongSection(let directive, let section):
            // Lower-cased and UNBRACKETED. The payload carries `[Peer]` because that is what
            // the operator reads on the device screen, but every identifier here is a
            // grep-friendly kebab token and a log filter should not have to quote a bracket
            // (Kilo, PR #519).
            return "staging-wrong-section-\(directive)-"
                + section.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        case .malformedValue(let key): return "staging-malformed-\(key)"
        case .configurationRefused(let failure): return "staging-config-\(failure)"
        case .rotationRefused(let failure): return "staging-rotation-\(failure)"
        }
    }
}

/// A chained upstream parsed from a WireGuard `.conf`, for an identity that may be staged.
///
/// Plan: lavasec-infra `plans/2026-07-27-vpn-upstream-phase-3-data-path-plan.md` (S9 — the
/// on-device battery cannot run until a chained configuration can reach a device, and no
/// producer exists before Phase 4).
///
/// ## The refusal is the point, and it is a TYPE and not a check
///
/// This value cannot be constructed for ``ChainedUpstreamStoreIdentity/production``, so
/// "stage a QA record into the slot a shipping build reads" is unrepresentable rather than
/// prohibited — the technique `ChainedResolverEgress` uses for the DNS leak and
/// `ChainedUpstreamRotation` uses for half a rotation.
///
/// The hazard it closes is specific and easy to miss. The phase-3 plan's C8 obligation
/// (its "pre-Phase-4 write path" paragraph) requires that state a QA writer persists be
/// unreachable by a Release build on the same device — because compile-time gating removes a
/// WRITER, never the state that writer already wrote. The gates do not line up on their own:
/// the QA surfaces compile under `DEBUG || LAVA_QA_TOOLS` while the store identity is chosen
/// by `LAVA_QA_TOOLS` ALONE, and a local Debug build signs as the production bundle ID. So a
/// Debug build shows the staging button and addresses the PRODUCTION store — it would write
/// exactly the record a later Release install over the top of it reads, handing a real user a
/// device that can latch chained and surrender silently, before Phase 4, with no notice. That
/// is the outcome C8 exists to prevent, and it is why this refusal is compiled into the
/// package unconditionally rather than living inside the QA gate: a guard that vanishes with
/// the flag it guards protects nothing, and the CI suite that has to prove the guard works
/// does not set the flag.
/// pinned: ChainedUpstreamStagingTests.testAProductionIdentityCannotBeStagedInto
public struct ChainedUpstreamStagingRequest: Sendable {
    /// The rotation to commit — configuration and key together, validated at both boundaries.
    public let rotation: ChainedUpstreamRotation
    /// The identity this request was admitted for. Never `.production`.
    public let identity: ChainedUpstreamStoreIdentity

    /// Parses `conf` and admits it for `identity`, or refuses.
    ///
    /// `accessGroup` is the group the key half will actually be written to — the caller's
    /// resolved `LavaKeychainSharingGroup`. It is required because the identity alone does
    /// not describe the build: see
    /// ``ChainedUpstreamStagingRefusal/buildIdentityIsInconsistent(identity:group:)``.
    ///
    /// - Throws: ``ChainedUpstreamStagingRefusal``.
    public init(
        conf: String, identity: ChainedUpstreamStoreIdentity, accessGroup: String
    ) throws {
        // FIRST, before any parsing. The refusals are about the build, not the file, and a
        // production build that pasted a malformed conf should hear that it may not stage at
        // all — not spend a QA session fixing a file it was never allowed to use.
        guard identity != .production else {
            throw ChainedUpstreamStagingRefusal.buildMayNotStage(identity)
        }
        // BOTH HALVES, because they are chosen by different knobs and only one of them was
        // ever checked. The file half follows `#if LAVA_QA_TOOLS`; the key half follows the
        // per-configuration `LAVA_KEYCHAIN_SHARING_GROUP`. A build that gets the define
        // without the configuration is `.qa` by the first and production by the second, and
        // an identity-only guard waves it through — committing a live WireGuard private key
        // into the group the shipping build is entitled to, where it survives app deletion.
        // Nothing downstream would notice: the configuration lands under the `.qa` filename
        // a production reader never opens, so there is no failure to see.
        guard ChainedUpstreamStoreIdentity.identity(forKeychainGroup: accessGroup) == identity
        else {
            throw ChainedUpstreamStagingRefusal.buildIdentityIsInconsistent(
                identity: identity, group: accessGroup)
        }
        self.rotation = try ChainedUpstreamConfParser.rotation(from: conf)
        self.identity = identity
    }
}

extension ChainedUpstreamStoreIdentity {
    /// The identity a resolved keychain access group belongs to, or `nil` when it belongs to
    /// neither.
    ///
    /// The mapping lives HERE and not only in `project.yml` because a build setting is not
    /// checkable at runtime and a source pin over the yaml cannot see a command-line or
    /// `Lava.local.xcconfig` override — which is exactly how the two halves of one build's
    /// identity came apart. Suffix-matched, because the resolved group carries the team
    /// prefix (`<AppIdentifierPrefix>.<group>`) and no team ID lives in this repository.
    /// pinned: ChainedUpstreamStagingTests.testAFlagWithoutTheQAConfigurationIsRefused
    public static func identity(forKeychainGroup group: String) -> ChainedUpstreamStoreIdentity? {
        // Longest suffix first: the production group is not a suffix of the QA one, but
        // stating the order removes the question rather than relying on it.
        if group.hasSuffix(".com.lavasec.dev.qa.chained-upstream") { return .qa }
        if group.hasSuffix(".com.lavasec.app.chained-upstream") { return .production }
        return nil
    }
}

/// Reads the subset of the WireGuard `.conf` format this feature accepts.
///
/// DELIBERATELY NOT A GENERAL PARSER. It reads the keys `ChainedUpstreamConfiguration` needs
/// and refuses everything else by omission, because a parser that silently ignores a key it
/// does not implement is how a user's `Table = off` or `PreUp = …` becomes a configuration
/// that behaves differently from the file they pasted. Unknown keys are skipped only where
/// they cannot change what the tunnel does with the keys it did read; the values that steer
/// the data path — endpoint, keys, address, routes, DNS, MTU — are all required or explicitly
/// defaulted here.
///
/// Every value is handed to the validating initialisers rather than trusted: the parse
/// answers "what does this text say", and `ChainedUpstreamConfiguration.init` and
/// `ChainedUpstreamRotation.init` answer "may that be used", which is the split those types
/// already enforce for every other producer.
public enum ChainedUpstreamConfParser {
    /// Lower-cased wg-quick keys this feature refuses rather than ignores.
    ///
    /// Each one changes what a wg-quick tunnel DOES, so dropping it silently produces a
    /// session that contradicts the file it was staged from. `Table` is the sharp case
    /// (it disables the route installation this tunnel performs anyway); the rest are the
    /// script hooks — including `PreDNS`/`PostDNS`, which run around `resolvconf(8)` and
    /// are easy to omit precisely because they are newer than the other four — whose
    /// absence is invisible until whatever they set up is missing.
    /// pinned: ChainedUpstreamStagingTests.testBehaviourChangingDirectivesAreRefused
    static let behaviourChangingDirectives = [
        "table", "preup", "postup", "predown", "postdown", "predns", "postdns", "saveconfig",
        // `ListenPort` is the non-obvious one and it is not inert: the vendored engine
        // honours `listen_port` by opening that socket, while this feature's transport is
        // an `NWConnection` whose local port it does not choose — so a file pinning a
        // port would stage green and then not use it, which is the same "session
        // contradicts the file" class as `Table` (Codex, PR #519).
        "listenport",
    ]

    /// Directives that are genuinely INERT on this platform, and why — the third category
    /// the ``behaviourChangingDirectives`` doc implies but did not name.
    ///
    /// `FwMark` sets a Linux socket mark for policy routing. The vendored engine's
    /// `set_fwmark` is `#[cfg(any(target_os = "android", "fuchsia", "linux"))]`, so it is not
    /// compiled for iOS at all, and nothing else on this platform reads a mark — dropping it
    /// cannot change what the tunnel does with the keys it DID read, which is exactly the
    /// promise the skip rule makes. Refusing it would reject an otherwise valid provider
    /// `.conf` over a line with no consequence here.
    ///
    /// Named in a set rather than left to the default skip so that the judgement is
    /// deliberate and reviewable: this was reported as a missing refusal (Codex, PR #519) on
    /// the grounds that the engine applies it, which is true on Linux and false for our
    /// target. If that ever changes — an engine build for a platform with marks — this set is
    /// where it stops being inert.
    /// pinned: ChainedUpstreamStagingTests.testEveryWireGuardDirectiveIsReadRefusedOrKnownInert
    static let knownInertDirectives = ["fwmark"]

    /// Keys read only from `[Interface]`, and only from there.
    ///
    /// The lists exist because the lookups are section-scoped and a misplaced key is read by
    /// nobody — see the refusal at the top of `parse` for why silence is the wrong answer.
    /// They name only what this parser actually reads: an unknown key is still skipped, and
    /// a wg-quick directive that changes behaviour is still refused by name regardless of
    /// section (`behaviourChangingDirectives` checks both dictionaries on purpose).
    /// pinned: ChainedUpstreamStagingTests.testASupportedDirectiveInTheWrongSectionIsRefused
    static let interfaceOnlyDirectives = ["privatekey", "address", "dns", "mtu"]

    /// Keys read only from `[Peer]`, and only from there.
    ///
    /// `presharedkey` is a genuine `[Peer]` directive this parser now READS (see `rotation`'s
    /// optional-PSK block, mirroring the optional-DNS one) — being in this list is what makes a
    /// `[Interface]`-placed `PresharedKey` say "wrong section" rather than silently landing in
    /// the interface dictionary where nobody reads it. It used to be here for placement ONLY,
    /// while `separatelyRefusedDirectives` refused it outright; that refusal is gone now that
    /// the staging→engine carry exists.
    static let peerOnlyDirectives = [
        "publickey", "endpoint", "allowedips", "persistentkeepalive", "presharedkey",
    ]

    /// Refused, but not for a wg-quick behaviour reason — so not in
    /// ``behaviourChangingDirectives``, whose doc is about directives that change what a
    /// wg-quick tunnel DOES.
    ///
    /// `PresharedKey` USED to be here, for the reason this set exists: the engine plumbing
    /// carried a PSK but no producer supplied one, so a PSK-bearing file staged green and then
    /// failed as a handshake that never completed — indistinguishable on the device from an
    /// unreachable peer. That reason is now closed. The staging→Keychain→tunnel→engine carry
    /// exists (this parser reads `PresharedKey` as an optional `[Peer]` directive; the secret
    /// store persists it beside the private key; `ChainedSessionCredentialReader` hands it to
    /// `WireGuardSession`), so a PSK from Mullvad, Tailscale, or a self-hosted peer stages and
    /// is honoured rather than silently dropped. `presharedkey` is therefore no longer in this
    /// list — it is READ (`peerOnlyDirectives` keeps it, for placement validation only).
    ///
    /// The AmneziaWG obfuscation keys REMAIN, for a reason the PSK never had. They are not
    /// upstream `wg(8)` — they belong to a fork — and the vendored engine is stock boringtun
    /// 0.7.1 with no junk-packet or header-mangling support anywhere in it. So a `.conf`
    /// written for an Amnezia server describes a handshake this tunnel genuinely cannot
    /// perform: unlike a PSK, there is no engine capability to carry these to, so skipping them
    /// as "unknown" would stage green and then fail as a handshake that never completes. That
    /// is the exact failure the PSK once shared and no longer does (Kilo, PR #519, attributed
    /// them to `wg(8)` — the attribution is wrong and the hazard is real).
    ///
    /// Declared as a set rather than left as a bare `if` so the coverage test can classify each
    /// entry truthfully.
    /// pinned: ChainedUpstreamStagingTests.testEveryWireGuardDirectiveIsReadRefusedOrKnownInert
    static let separatelyRefusedDirectives = [
        // AmneziaWG v1.x/v2 [Interface] obfuscation parameters.
        "jc", "jmin", "jmax", "s1", "s2", "s3", "s4", "h1", "h2", "h3", "h4",
    ]

    /// The rotation `conf` describes.
    ///
    /// - Throws: ``ChainedUpstreamStagingRefusal``.
    public static func rotation(from conf: String) throws -> ChainedUpstreamRotation {
        var interface: [String: [String]] = [:]
        var peer: [String: [String]] = [:]
        var section: String?
        var seenSections: Set<String> = []

        for rawLine in conf.split(whereSeparator: { $0.isNewline }) {
            // `whereSeparator: isNewline` and not `separator: "\n"`: a CRLF file splits into
            // lines ending in a stray `\r` under the latter, and every value then carries an
            // invisible trailing character that fails base64 decoding for a reason no user can
            // see (found on the #442 spike parser).
            let line = rawLine.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("[") {
                section = line.lowercased()
                // A REPEATED HEADER IS REFUSED, not merged. `section` is only a dictionary
                // selector, so a second `[Peer]` appends into the first one's bucket: its
                // required keys then read as repeated (caught), but its OPTIONAL keys —
                // `PersistentKeepalive`, and `DNS` under a second `[Interface]` — silently
                // join a section the file presents as separate. A multi-peer `.conf` is a
                // shape this feature does not carry, and quietly folding half of one into
                // the peer it does use is the "stages an upstream they did not choose"
                // failure the repeated-key rule already refuses.
                if let section, !seenSections.insert(section).inserted {
                    throw ChainedUpstreamStagingRefusal.unsupportedDirective(section)
                }
                continue
            }
            guard let separator = line.firstIndex(of: "=") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            switch section {
            case "[interface]": interface[key, default: []].append(value)
            case "[peer]": peer[key, default: []].append(value)
            default: continue
            }
        }

        // EVERY LOOKUP BELOW IS SECTION-SCOPED, so a supported key in the wrong section is
        // read by nobody. For the REQUIRED keys that surfaces as `missingOrRepeatedKey`,
        // which is a refusal — wrong, but loud. For the OPTIONAL ones it is silent: `DNS`
        // under `[Peer]`, `MTU` under `[Peer]`, or `PersistentKeepalive` under `[Interface]`
        // stage green as no resolvers, the default MTU, or keepalive off, and the tunnel
        // then does something the pasted file does not say (Codex, PR #519). Checked FIRST
        // so a misplaced required key is diagnosed as misplaced rather than missing.
        for directive in Self.interfaceOnlyDirectives where peer[directive] != nil {
            throw ChainedUpstreamStagingRefusal.directiveInWrongSection(
                directive: directive, section: "[Peer]")
        }
        for directive in Self.peerOnlyDirectives where interface[directive] != nil {
            throw ChainedUpstreamStagingRefusal.directiveInWrongSection(
                directive: directive, section: "[Interface]")
        }

        // A repeated key is refused rather than last-wins. Two `Endpoint` lines mean the file
        // says two different things and nothing here can know which the user meant; picking
        // one silently stages an upstream they did not choose.
        let privateKeyText = try exactlyOne(interface, "PrivateKey")
        let address = try exactlyOne(interface, "Address")
        let peerKey = try exactlyOne(peer, "PublicKey")
        let endpoint = try exactlyOne(peer, "Endpoint")
        let allowedIPsText = try exactlyOne(peer, "AllowedIPs")

        // wg-quick directives that CHANGE WHAT THE TUNNEL DOES are refused by name. The
        // doc above promises unknown keys are skipped only where they cannot change what
        // the tunnel does with the keys it did read, and `Table = off` breaks that promise
        // outright: in wg-quick it disables automatic route installation from
        // `AllowedIPs`, while this tunnel derives and installs the default routes from the
        // very same `AllowedIPs` regardless — so the staged session does the opposite of
        // what the pasted file says (Codex, PR #519; the first version of this parser even
        // used `Table = off` as its example of a harmless unknown key, which is how the
        // promise came to be false). The rest are the script hooks: they run commands
        // wg-quick would execute around the interface, and a tunnel that silently does not
        // run them is not the configuration the operator pasted.
        for directive in Self.behaviourChangingDirectives
        where interface[directive] != nil || peer[directive] != nil {
            throw ChainedUpstreamStagingRefusal.unsupportedDirective(directive)
        }

        // The AmneziaWG obfuscation keys are REFUSED rather than dropped, for the reason
        // recorded on `separatelyRefusedDirectives`: the vendored engine cannot obfuscate, so
        // such a file would stage green and then fail as a handshake that never completes.
        // `PresharedKey` is deliberately NOT in this set any more — it is parsed below. Driven
        // from the set rather than a bare key test so the declaration the coverage test reads
        // is the same one enforcing the refusal.
        for directive in Self.separatelyRefusedDirectives
        where interface[directive] != nil || peer[directive] != nil {
            throw ChainedUpstreamStagingRefusal.unsupportedDirective(directive)
        }

        guard let privateKey = Data(base64Encoded: privateKeyText) else {
            throw ChainedUpstreamStagingRefusal.malformedValue("PrivateKey")
        }
        let (host, port) = try endpointParts(endpoint)
        // A DUAL-STACK ADDRESS LIST IS ACCEPTED, and its IPv6 entries are deliberately not
        // carried. This previously refused any value containing a comma, reasoning that
        // taking the IPv4 half would leave "the file not saying what the tunnel does".
        //
        // That reasoning does not survive contact with the tunnel it describes. Chained mode
        // NEVER uses a configured IPv6 address: `TunnelRoutePlan` assigns the fixed ULA
        // `chainedTunnelIPv6Address` (fd00:1a7a::2) and claims `::/0` **in order to drop it**
        // (INV, "the tunnel never advertises a route it cannot forward, except the IPv6
        // DEFAULT route, which chained mode claims in order to blackhole"). So the v6 half is
        // unused whether it is present in the file or absent from it, and the tunnel's IPv6
        // behaviour — fail closed at the route — is identical either way. Nothing vanishes
        // that the tunnel would otherwise have honoured.
        //
        // What the refusal DID do is reject essentially every real provider configuration:
        // Mullvad, and every other dual-stack provider, writes
        // `Address = 10.68.193.169/32,fc00:bbbb:bbbb:bb01::5:c1a8/128`. A technically correct
        // file was refused as malformed, which reads as "your config is broken" rather than
        // "this build does not carry IPv6" (found on device, S9: every one of 539 Mullvad
        // configs refused with `staging-malformed-Address`).
        //
        // Still exactly ONE IPv4 entry: that address is the inner source the peer's AllowedIPs
        // must permit, so an ambiguous or absent one is a genuine defect, not a preference.
        // Entries are trimmed because a comma-separated list is conventionally written with
        // spaces after the commas — the same reading `AllowedIPs` and `DNS` already get below.
        let addressEntries = address
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // An IPv6 literal is the only thing here that can contain a colon.
        let ipv4AddressEntries = addressEntries.filter { !$0.contains(":") }
        guard ipv4AddressEntries.count == 1 else {
            throw ChainedUpstreamStagingRefusal.malformedValue("Address")
        }
        let ipv4Address = ipv4AddressEntries[0]
        // THE PREFIX IS VALIDATED, THEN NORMALISED AWAY — any well-formed IPv4 prefix
        // `/0`…`/32` is accepted and the suffix dropped, so the parse yields the same bare
        // host it always did for `/32` or a bare address. An earlier version accepted only
        // `/32` or bare and refused every other prefix as malformed, reasoning that a `/24`
        // describes an on-link subnet the session will not have. That reasoning does not
        // survive contact with the tunnel: `TunnelRoutePlan` installs the inner address as a
        // bare `/32` REGARDLESS of what the file wrote, and with `0.0.0.0/0` claimed the
        // interface subnet decides nothing about routing — every destination enters the
        // tunnel via `AllowedIPs`, not an on-link subnet route. So a `/24` is behaviourally
        // SUBSUMED by the `/32` the plan installs; the strictness rejected legitimate files
        // without protecting anything.
        //
        // What it DID reject is the largest population of real configs: `/24` (and `/16`,
        // `/8`, …) is what PiVPN, wg-easy, wireguard-ui, pfSense/OPNsense/Mikrotik, the
        // official WireGuard quickstart, and virtually every hand-written wg-quick client
        // config write — the core bring-your-own-upstream audience (#1 gap in the MECE
        // WG-config audit).
        //
        // A MALFORMED suffix is still refused, not repaired. The length must be a CANONICAL
        // decimal `0…32` — the same rule `AllowedIPs` lengths get in
        // `ChainedUpstreamConfiguration.isPlausiblePrefix` (`/08` and `/8` are not two
        // spellings of one prefix) — so `/garbage`, `/33`, `/-1`, `/128`, `/320`, and `/032`
        // are refused. `omittingEmptySubsequences: false` is deliberate: Swift drops empty
        // pieces by default, so a trailing `10.64.0.2/` would otherwise collapse to one
        // element and read as a bare address, a malformed suffix silently accepted.
        //
        // ABSENT is accepted for the reason it always was: wg-quick reads a bare IPv4 address
        // as /32, which is exactly what the plan installs, so that file and this tunnel
        // already agree. Either shape yields a BARE `clientAddress` (no prefix), which is what
        // `ChainedUpstreamConfiguration` and the plan's hardcoded /32 both expect.
        let addressParts = ipv4Address.split(
            separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        if addressParts.count == 2 {
            // Canonical decimal length `0…32`, mirroring `isPlausiblePrefix`. A garbage,
            // out-of-range, empty, or leading-zero suffix is refused; a valid one is dropped
            // (the plan reinstalls /32 regardless of its width).
            let lengthText = addressParts[1]
            guard !lengthText.isEmpty, lengthText.allSatisfy(\.isNumber),
                  lengthText.count == 1 || lengthText.first != "0",
                  let length = Int(lengthText), (0...32).contains(length)
            else {
                throw ChainedUpstreamStagingRefusal.malformedValue("Address")
            }
        }
        // THE HOST SIDE IS NOT WHITESPACE-REPAIRED. The suffix above is validated then
        // dropped, but the host half is read exactly as written. The first version of this
        // check made the SUFFIX exact and left the host `trimmingCharacters` — the same
        // expression, strict on one side and lenient on the other — so `10.64.0.2 /32`
        // passed: the suffix compared equal and the trim quietly repaired the host (Codex,
        // PR #519). This guard is what keeps interior whitespace shut regardless of the
        // suffix relaxation above.
        //
        // The line between this and the trimming a few lines below is not taste. A
        // comma-separated list (`AllowedIPs`, `DNS`) is CONVENTIONALLY written with spaces
        // after the commas, so trimming there reads the file as its author wrote it. Nothing
        // writes a space inside an address, so trimming here would be repairing the file
        // instead of reading it — and this is the boundary that decides whether the tunnel
        // matches what was pasted. `endpointParts` already holds this line.
        guard !addressParts[0].contains(where: { $0.isWhitespace }) else {
            throw ChainedUpstreamStagingRefusal.malformedValue("Address")
        }
        let clientAddress = String(addressParts[0])
        let allowedIPs = allowedIPsText.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // ABSENT is the only tolerated shape, and `try?` was wrong here: it swallowed the
        // repeated-key and empty-value refusals too, so `DNS =` twice — or `DNS =` with
        // nothing after it — became an empty resolver list, which readiness later refuses as
        // `noUsableTunnelDNS` with no hint that the file said otherwise. Absence is an
        // ordinary shape (the configuration's own doc says so); present-but-unusable is not.
        let dnsAddresses: [String]
        if interface["dns"] == nil {
            dnsAddresses = []
        } else {
            dnsAddresses = try exactlyOne(interface, "DNS")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            // The empty-value refusal has to survive the SPLIT, not just the read: `DNS =`
            // is caught by `exactlyOne`, but `DNS = ,` passes it as a non-empty value and
            // then collapses to nothing here — the same silent empty-resolver shape, one
            // step later (Kilo, PR #519). A present DNS line that names no resolver is a
            // file saying something the tunnel cannot use, and it is refused as such
            // rather than surfacing later as `noUsableTunnelDNS` with nothing to explain
            // it.
            guard !dnsAddresses.isEmpty else {
                throw ChainedUpstreamStagingRefusal.malformedValue("DNS")
            }
        }

        let mtu = try optionalUInt16(interface, "MTU")
        let keepalive = try optionalUInt16(peer, "PersistentKeepalive") ?? 0

        // OPTIONAL, exactly like `DNS` above: absent is the common shape (WireGuard's own "no
        // PSK"), so nil-when-absent is ordinary rather than a refusal. Present-but-malformed is
        // not: a `PresharedKey` line that is repeated, empty, not base64, or not exactly 32
        // bytes decoded is a file saying something the engine cannot use, and it is refused
        // here — with the same byte width the write boundary and the engine both enforce —
        // rather than surfacing later as a handshake that never completes. `exactlyOne` names
        // the repeated/empty case; the decode and length name the malformed one.
        let presharedKey: Data?
        if peer["presharedkey"] == nil {
            presharedKey = nil
        } else {
            let text = try exactlyOne(peer, "PresharedKey")
            guard let decoded = Data(base64Encoded: text),
                decoded.count == ChainedUpstreamConfiguration.presharedKeyByteCount
            else {
                throw ChainedUpstreamStagingRefusal.malformedValue("PresharedKey")
            }
            presharedKey = decoded
        }

        let configuration: ChainedUpstreamConfiguration
        do {
            configuration = try ChainedUpstreamConfiguration(
                endpointHost: host,
                endpointPort: port,
                peerPublicKey: peerKey,
                clientAddress: clientAddress,
                allowedIPs: allowedIPs,
                persistentKeepaliveSeconds: keepalive,
                interfaceMTU: mtu,
                dnsAddresses: dnsAddresses)
        } catch let failure as ChainedUpstreamConfiguration.ValidationFailure {
            throw ChainedUpstreamStagingRefusal.configurationRefused(failure)
        }

        do {
            return try ChainedUpstreamRotation(
                configuration: configuration, privateKey: privateKey, presharedKey: presharedKey)
        } catch let failure as ChainedUpstreamSecretStoreFailure {
            throw ChainedUpstreamStagingRefusal.rotationRefused(failure)
        }
    }

    private static func exactlyOne(
        _ section: [String: [String]], _ key: String
    ) throws -> String {
        let values = section[key.lowercased()] ?? []
        guard values.count == 1, !values[0].isEmpty else {
            throw ChainedUpstreamStagingRefusal.missingOrRepeatedKey(key)
        }
        return values[0]
    }

    private static func optionalUInt16(
        _ section: [String: [String]], _ key: String
    ) throws -> UInt16? {
        let values = section[key.lowercased()] ?? []
        guard !values.isEmpty else { return nil }
        guard values.count == 1, let parsed = UInt16(values[0]) else {
            // Present-but-unreadable is a refusal, never a silent default: an `MTU = 12800`
            // typo defaulting to 1280 is a session that behaves unlike the file.
            throw ChainedUpstreamStagingRefusal.malformedValue(key)
        }
        return parsed
    }

    /// Splits `host:port`, including the bracketed IPv6 form.
    private static func endpointParts(_ endpoint: String) throws -> (String, UInt16) {
        guard let separator = endpoint.lastIndex(of: ":") else {
            throw ChainedUpstreamStagingRefusal.malformedValue("Endpoint")
        }
        var host = String(endpoint[..<separator])
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        guard let port = UInt16(endpoint[endpoint.index(after: separator)...]), port != 0 else {
            throw ChainedUpstreamStagingRefusal.malformedValue("Endpoint")
        }
        return (host, port)
    }
}
