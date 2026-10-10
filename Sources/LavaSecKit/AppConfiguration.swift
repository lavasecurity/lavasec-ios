import Foundation

public struct AppConfiguration: Equatable, Codable, Sendable {
    /// Device-local opt-in; a downloaded DNS profile alone does not prove protection.
    public var dnsPatchEnabled: Bool
    public var protectionEnabled: Bool
    public var enabledBlocklistIDs: Set<String>
    public var allowedDomains: Set<String>
    public var blockedDomains: Set<String>
    public var resolverPresetID: String
    public var customResolverAddress: String?
    public var customResolverSecondaryAddress: String?
    public var customResolverName: String?
    /// Explicit tier editing permits an alternative resolver beneath any primary.
    /// False preserves dormant fallback preferences in configurations from older releases.
    public var usesExplicitDNSTiers: Bool
    /// Numbered DNS choices, including disabled rows; effective legacy fields remain interoperable.
    public var savedDNSResolutionSelections: [DNSResolutionSelection]? = nil
    public var fallbackToDeviceDNS: Bool
    // Persisted legacy name: when explicit tiers are enabled, this selects an alternative T2.
    public var usesEncryptedDeviceDNSFallback: Bool
    // The resolver the encrypted Device-DNS fallback routes to when engaged. Mirrors
    // the primary resolver selection (a preset ID plus optional Custom fields) so the
    // user can pick any provider/transport, Custom included (Plus-gated). Defaults to
    // Quad9 DoH (top of the catalog). Only consulted when usesEncryptedDeviceDNSFallback
    // is on and either explicit tiers are enabled or the primary is Device DNS.
    public var fallbackResolverPresetID: String
    public var fallbackCustomResolverAddress: String?
    public var fallbackCustomResolverSecondaryAddress: String?
    public var fallbackCustomResolverName: String?
    public var keepFilteringCounts: Bool
    public var keepDomainDiagnostics: Bool
    public var keepNetworkActivity: Bool
    public var keepLavaGuardProgress: Bool
    public var isPaid: Bool
    public var qaProbeSet: QADomainProbeSet?
    public var customBlocklists: [CustomBlocklistSource]
    public var lavaGuardUnlocks: LavaGuardAchievementLedger
    /// Monotonic supersession token, bumped on every foreground config write
    /// (`persistSharedState`/`persistConfigurationOnly`). A background catalog
    /// refresh captures this value when it builds, then — inside the publish lock —
    /// re-reads the on-disk value and ABORTS the pointer flip if it changed, so a
    /// background publish can never clobber a newer foreground edit. Kept in the
    /// config file so the token and the config it guards are written atomically
    /// (a sidecar would reintroduce a config-vs-token TOCTOU). NOT a filter-content
    /// input, so it is excluded from `PreparedFilterSnapshotIdentity`.
    public var configurationGeneration: Int

    /// Whether the user asked for a chained WireGuard upstream behind DNS filtering.
    ///
    /// This is the *request*, never the verdict. The tunnel latches its data-path mode once
    /// per lifecycle and resolves `dnsOnly` unless this flag is on **and** the device is
    /// eligible (`ChainedAvailability`) **and** the upstream config parses **and** the
    /// WireGuard secret is readable from Keychain right then — so a synced or restored
    /// configuration with this on cannot make an ineligible device claim routes it cannot
    /// forward. Plan D1/D2.
    ///
    /// The device-local pieces of that predicate — the experimental memory override and the
    /// jetsam-exclusion marker — are deliberately absent from this type: they describe one
    /// device, so syncing them would carry a decision about one phone onto another.
    ///
    /// Not yet carried in `BackupConfigurationPayload`. That belongs with the restore
    /// reconcile, because the WireGuard secret is Keychain `ThisDeviceOnly` and does not
    /// migrate: restoring the flag alone would land a device in "chaining requested, secret
    /// missing", which needs the re-enter-your-key path to be meaningful rather than a
    /// silent DNS-only start. A reviewed restore preserves this device's existing chaining
    /// request and fallback preference; it does not import them from the backup.
    public var chainedUpstreamEnabled: Bool

    /// Device-local setup disclosure. Opening it never enables chaining; closing it
    /// clears the chaining request while retaining the separately stored credentials.
    public var wireGuardSetupEnabled: Bool

    /// Changes setup and routing intent together, so a hidden setup cannot remain ON.
    public mutating func setWireGuardSetupEnabled(_ enabled: Bool) {
        wireGuardSetupEnabled = enabled
        if !enabled { chainedUpstreamEnabled = false }
    }

    // THE CHAINED T1 FALLBACK HAS ONE SETTING: whether to run at all.
    //
    // It used to have five: an opt-in toggle plus a second resolver picker restricted to plain
    // IPv4. Both existed for one reason — the rung rode the WireGuard tunnel, which carries plain
    // UDP :53 and nothing else — and PR #590 moved the rung to the physical interface, where all
    // four transports work. A second picker offering a strict subset of the first one's choices,
    // for a resolver the user had already chosen once, was debt from the moment the mechanism
    // under it changed. S4 deleted all five.
    //
    // WHICH resolver is no longer a question here: `resolverPresetID` and the `customResolver*`
    // fields are T1 — the ONE selection the user makes — and T1 is T1 in both modes. Chaining
    // does not renumber it; it inserts T0 above it (`docs/architecture/dns-tiers.md`). WHETHER
    // came back, as the single flag below.
    //
    // No migration, per the plan's D2: chaining is internal-only, and `Decodable` drops the five
    // removed keys silently. A user who had picked a different alternative resolver gets their
    // primary one instead, which is the setting they last stated an opinion about.

    /// Whether the chained T1 fallback may run — the one setting it has.
    ///
    /// DEFAULTS TRUE, and the default is the whole compatibility story. Between S4 and here the
    /// rung followed automatically from chaining plus a split-tunnel profile, with no consent
    /// gate; defaulting false would silently withdraw the fallback from every existing user,
    /// including the one whose field reports drove PR #596. True reproduces that behaviour
    /// exactly, and the toggle exists so a user can decline the physical-interface lookups the
    /// section footer discloses.
    ///
    /// Enforced in exactly one place — ``chainedTierOneResolverConfiguration`` answers `nil` when
    /// this is off — because nil is ALREADY the "no rung" signal every consumer handles: the
    /// tunnel's plan derivation, the latch, and the settings panel's own enabled question. A
    /// second gate elsewhere could disagree with this one.
    /// pinned: AppConfigurationTests.testTheTierOneFallbackToggleGatesTheRung
    public var chainedTierOneFallbackEnabled: Bool

    public init(
        protectionEnabled: Bool = false,
        dnsPatchEnabled: Bool = false,
        enabledBlocklistIDs: Set<String> = [],
        allowedDomains: Set<String> = [],
        blockedDomains: Set<String> = [],
        resolverPresetID: String = DNSResolverPreset.quad9UnfilteredDoH.id,
        customResolverAddress: String? = nil,
        customResolverSecondaryAddress: String? = nil,
        customResolverName: String? = nil,
        fallbackToDeviceDNS: Bool = true,
        usesEncryptedDeviceDNSFallback: Bool = false,
        usesExplicitDNSTiers: Bool = false,
        fallbackResolverPresetID: String = DNSResolverPreset.quad9UnfilteredDoH.id,
        fallbackCustomResolverAddress: String? = nil,
        fallbackCustomResolverSecondaryAddress: String? = nil,
        fallbackCustomResolverName: String? = nil,
        keepFilteringCounts: Bool = true,
        keepDomainDiagnostics: Bool = true,
        keepNetworkActivity: Bool = true,
        keepLavaGuardProgress: Bool = true,
        isPaid: Bool = false,
        qaProbeSet: QADomainProbeSet? = nil,
        customBlocklists: [CustomBlocklistSource] = [],
        lavaGuardUnlocks: LavaGuardAchievementLedger = LavaGuardAchievementLedger(),
        configurationGeneration: Int = 0,
        chainedUpstreamEnabled: Bool = false,
        wireGuardSetupEnabled: Bool? = nil,
        chainedTierOneFallbackEnabled: Bool = true
    ) {
        self.dnsPatchEnabled = dnsPatchEnabled
        self.protectionEnabled = protectionEnabled
        self.enabledBlocklistIDs = enabledBlocklistIDs
        self.allowedDomains = allowedDomains
        self.blockedDomains = blockedDomains
        self.resolverPresetID = DNSResolverPreset.migratedPresetID(resolverPresetID)
        self.customResolverAddress = customResolverAddress
        self.customResolverSecondaryAddress = customResolverSecondaryAddress
        self.customResolverName = customResolverName
        self.fallbackToDeviceDNS = fallbackToDeviceDNS
        self.usesExplicitDNSTiers = usesExplicitDNSTiers
        self.usesEncryptedDeviceDNSFallback = usesEncryptedDeviceDNSFallback
        self.fallbackResolverPresetID = DNSResolverPreset.migratedPresetID(fallbackResolverPresetID)
        self.fallbackCustomResolverAddress = fallbackCustomResolverAddress
        self.fallbackCustomResolverSecondaryAddress = fallbackCustomResolverSecondaryAddress
        self.fallbackCustomResolverName = fallbackCustomResolverName
        self.keepFilteringCounts = keepFilteringCounts
        self.keepDomainDiagnostics = keepDomainDiagnostics
        self.keepNetworkActivity = keepNetworkActivity
        self.keepLavaGuardProgress = keepLavaGuardProgress
        self.isPaid = isPaid
        self.qaProbeSet = qaProbeSet
        self.customBlocklists = customBlocklists
        self.lavaGuardUnlocks = lavaGuardUnlocks
        self.configurationGeneration = configurationGeneration
        self.chainedUpstreamEnabled = chainedUpstreamEnabled
        self.wireGuardSetupEnabled = wireGuardSetupEnabled ?? chainedUpstreamEnabled
        self.chainedTierOneFallbackEnabled = chainedTierOneFallbackEnabled
    }

    public init(
        protectionEnabled: Bool,
        enabledBlocklistIDs: Set<String>,
        allowedDomains: Set<String>,
        blockedDomains: Set<String>,
        resolverPresetID: String,
        fallbackToDeviceDNS: Bool,
        keepFilteringCounts: Bool,
        keepDomainDiagnostics: Bool,
        keepNetworkActivity: Bool,
        keepLavaGuardProgress: Bool = true,
        isPaid: Bool,
        qaProbeSet: QADomainProbeSet?,
        customBlocklists: [CustomBlocklistSource],
        lavaGuardUnlocks: LavaGuardAchievementLedger = LavaGuardAchievementLedger()
    ) {
        self.init(
            protectionEnabled: protectionEnabled,
            enabledBlocklistIDs: enabledBlocklistIDs,
            allowedDomains: allowedDomains,
            blockedDomains: blockedDomains,
            resolverPresetID: resolverPresetID,
            customResolverAddress: nil,
            customResolverSecondaryAddress: nil,
            customResolverName: nil,
            fallbackToDeviceDNS: fallbackToDeviceDNS,
            keepFilteringCounts: keepFilteringCounts,
            keepDomainDiagnostics: keepDomainDiagnostics,
            keepNetworkActivity: keepNetworkActivity,
            keepLavaGuardProgress: keepLavaGuardProgress,
            isPaid: isPaid,
            qaProbeSet: qaProbeSet,
            customBlocklists: customBlocklists,
            lavaGuardUnlocks: lavaGuardUnlocks
        )
    }

    enum CodingKeys: String, CodingKey {
        case dnsPatchEnabled
        case protectionEnabled
        case enabledBlocklistIDs
        case allowedDomains
        case blockedDomains
        case resolverPresetID
        case customResolverAddress
        case customResolverSecondaryAddress
        case customResolverName
        case fallbackToDeviceDNS
        case usesExplicitDNSTiers
        case savedDNSResolutionSelections
        case usesEncryptedDeviceDNSFallback
        case fallbackResolverPresetID
        case fallbackCustomResolverAddress
        case fallbackCustomResolverSecondaryAddress
        case fallbackCustomResolverName
        case keepFilteringCounts
        case keepDomainDiagnostics
        case keepNetworkActivity
        case keepLavaGuardProgress
        case isPaid
        case qaProbeSet
        case customBlocklists
        case lavaGuardUnlocks
        case configurationGeneration
        case chainedUpstreamEnabled
        case wireGuardSetupEnabled
        // WIRE KEY PINNED TO THE RETIRED SPELLING. The property was renamed when the tier
        // numbering was corrected to the canonical scaffold
        // (`docs/architecture/dns-tiers.md`, PR #637): this rung serves T1, the user's own
        // resolver selection, and only the OLD attempt-order numbering ever called it two.
        // The numbering was wrong; the stored configuration was not. Changing the encoded
        // key would decode as absent on every existing install and, by the `?? true`
        // default below, silently re-enable the rung for anyone who had declined it.
        case chainedTierOneFallbackEnabled = "chainedTierTwoFallbackEnabled"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dnsPatchEnabled = try container.decodeIfPresent(Bool.self, forKey: .dnsPatchEnabled) ?? false
        protectionEnabled = try container.decodeIfPresent(Bool.self, forKey: .protectionEnabled) ?? false
        enabledBlocklistIDs = try container.decodeIfPresent(Set<String>.self, forKey: .enabledBlocklistIDs) ?? []
        allowedDomains = try container.decodeIfPresent(Set<String>.self, forKey: .allowedDomains) ?? []
        blockedDomains = try container.decodeIfPresent(Set<String>.self, forKey: .blockedDomains) ?? []
        // NO STORED PRIMARY RESOLVER MEANS THE USER NEVER CHOSE ONE, so Lava must not choose a
        // company on their behalf: an absent id resolves to Device DNS, which hands the choice
        // back to the network the user is already on. Naming a third party here would be a
        // silent privacy decision made for someone who expressed no preference
        // (`lavasec-infra` `plans/2026-06-15-device-dns-default-plan.md`, Product Rules).
        // The FALLBACK id below deliberately keeps Quad9 DoH: that field is the encrypted
        // safety net for a wedged Device-DNS primary, so "the device's own resolver" is not an
        // answer there — it is the thing being backed up.
        // Decoded into locals FIRST because the id's normalisation needs them: a Custom record is
        // only a Custom selection if it can actually be built (see `recognisedPrimaryResolverID`).
        let decodedCustomAddress = try container.decodeIfPresent(String.self, forKey: .customResolverAddress)
        let decodedCustomSecondaryAddress = try container.decodeIfPresent(String.self, forKey: .customResolverSecondaryAddress)
        let decodedCustomName = try container.decodeIfPresent(String.self, forKey: .customResolverName)
        resolverPresetID = Self.recognisedPrimaryResolverID(
            DNSResolverPreset.migratedPresetID(try container.decodeIfPresent(String.self, forKey: .resolverPresetID) ?? DNSResolverPreset.device.id),
            customResolverAddress: decodedCustomAddress,
            customResolverSecondaryAddress: decodedCustomSecondaryAddress,
            customResolverName: decodedCustomName)
        customResolverAddress = decodedCustomAddress
        customResolverSecondaryAddress = decodedCustomSecondaryAddress
        customResolverName = decodedCustomName
        fallbackToDeviceDNS = try container.decodeIfPresent(Bool.self, forKey: .fallbackToDeviceDNS) ?? true
        usesExplicitDNSTiers = try container.decodeIfPresent(Bool.self, forKey: .usesExplicitDNSTiers) ?? false
        savedDNSResolutionSelections = try container.decodeIfPresent([DNSResolutionSelection].self, forKey: .savedDNSResolutionSelections)
        usesEncryptedDeviceDNSFallback = try container.decodeIfPresent(Bool.self, forKey: .usesEncryptedDeviceDNSFallback) ?? false
        fallbackResolverPresetID = DNSResolverPreset.migratedPresetID(try container.decodeIfPresent(String.self, forKey: .fallbackResolverPresetID) ?? DNSResolverPreset.quad9UnfilteredDoH.id)
        fallbackCustomResolverAddress = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverAddress)
        fallbackCustomResolverSecondaryAddress = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverSecondaryAddress)
        fallbackCustomResolverName = try container.decodeIfPresent(String.self, forKey: .fallbackCustomResolverName)
        keepFilteringCounts = try container.decodeIfPresent(Bool.self, forKey: .keepFilteringCounts) ?? true
        keepDomainDiagnostics = try container.decodeIfPresent(Bool.self, forKey: .keepDomainDiagnostics) ?? false
        keepNetworkActivity = try container.decodeIfPresent(Bool.self, forKey: .keepNetworkActivity) ?? true
        keepLavaGuardProgress = try container.decodeIfPresent(Bool.self, forKey: .keepLavaGuardProgress) ?? true
        isPaid = try container.decodeIfPresent(Bool.self, forKey: .isPaid) ?? false
        #if DEBUG || LAVA_QA_TOOLS
        qaProbeSet = try container.decodeIfPresent(QADomainProbeSet.self, forKey: .qaProbeSet)
        #else
        qaProbeSet = nil
        #endif
        customBlocklists = try container.decodeIfPresent([CustomBlocklistSource].self, forKey: .customBlocklists) ?? []
        lavaGuardUnlocks = try container.decodeIfPresent(
            LavaGuardAchievementLedger.self,
            forKey: .lavaGuardUnlocks
        ) ?? LavaGuardAchievementLedger()
        configurationGeneration = try container.decodeIfPresent(Int.self, forKey: .configurationGeneration) ?? 0
        // Absent => off, by construction: a config written by an older build, or restored
        // from one, can only ever decode to DNS-only.
        chainedUpstreamEnabled = try container.decodeIfPresent(Bool.self, forKey: .chainedUpstreamEnabled) ?? false
        // Existing enabled installs open setup without changing routing intent. A saved
        // OFF choice remains OFF, including when credentials are temporarily unreadable.
        wireGuardSetupEnabled = try container.decodeIfPresent(Bool.self, forKey: .wireGuardSetupEnabled)
            ?? chainedUpstreamEnabled
        // Absent key = a configuration written before the toggle existed, when the rung ran
        // unconditionally. `true` is what that user actually had.
        chainedTierOneFallbackEnabled =
            try container.decodeIfPresent(Bool.self, forKey: .chainedTierOneFallbackEnabled) ?? true
        // THE FIVE `chainedFallback*` KEYS ARE DROPPED SILENTLY, per the plan's D2. Chained mode
        // is internal-only, and a `Decodable` written by key never sees a key it has no case for
        // — so a stored config from an earlier build decodes with the second resolver selection
        // simply gone, and the user's ONE selection serves both modes from then on.
    }

    public var limits: FeatureLimits {
        hasLavaSecurityPlus ? .plus : .free
    }

    public var hasLavaSecurityPlus: Bool {
        isPaid
    }

    /// NORMALISES AN ID ARRIVING FROM STORAGE, so what the settings screen shows is what the
    /// resolver stack runs. `resolverPreset` below already resolves an unrecognised id to Device
    /// DNS, but two consumers key off the RAW id — `DNSResolverSettingsView.usesDeviceDNSSetting`
    /// and `AppViewModel.dnsResolverSummaryText` — and leaving the raw value in place made them
    /// disagree with the runtime: a downgraded or corrupted configuration rendered as
    /// "Device + Fallback" while `ResolverTierTwo.make` was returning `.none`, advertising a
    /// fallback path that did not exist (Codex review, PR #642).
    ///
    /// Normalising rather than teaching each consumer to read the resolved preset keeps the two in
    /// sync, and avoids the contradiction that reading the resolved preset would create for an
    /// unbuildable Custom entry — which would then satisfy both `isCustomResolverSelected` and
    /// `usesDeviceDNSSetting` at once. Custom is therefore passed through untouched; only an
    /// unrecognised BUILT-IN id normalises — and Custom is CHECKED rather than exempted. A stored
    /// `custom-dns` whose address is missing, malformed, or in a form this build no longer parses
    /// cannot be built by `DNSResolverPreset.custom`, so `resolverPreset` falls through to Device
    /// DNS while `DNSResolverSettingsView` still reads the raw id and presents Custom DNS. That is
    /// the same presentation-versus-runtime split as the unknown-id case, reached through the one
    /// door an unconditional Custom exemption left open (Codex review, PR #642).
    ///
    /// CALLED AT THE TWO PERSISTENCE BOUNDARIES ONLY — `init(from:)` and
    /// `BackupConfigurationPayload.restoredConfiguration()` — and deliberately NOT from the
    /// memberwise initializer. A foreign id can only arrive from stored state or a backup, so
    /// those are the doors that need a guard; putting it in the initializer instead made a
    /// general-purpose value-type init silently rewrite its own argument, which broke
    /// `FilterSwitchPlanTests`' field-preservation fixture — a test whose whole point is that a
    /// distinctive device-global value survives a switch untouched. That was the design telling
    /// the truth about itself.
    ///
    /// The cost is deliberate and small: a preset added in a later build, seen by an older one,
    /// is rewritten to Device DNS rather than preserved for a later upgrade. A stored id this
    /// build cannot represent in its own settings UI is not a choice it can honour.
    package static func recognisedPrimaryResolverID(
        _ storedID: String,
        customResolverAddress: String?,
        customResolverSecondaryAddress: String?,
        customResolverName: String?
    ) -> String {
        if storedID == DNSResolverPreset.customID {
            let buildsFromItsOwnFields = DNSResolverPreset.custom(
                primaryRawValue: customResolverAddress,
                secondaryRawValue: customResolverSecondaryAddress,
                displayName: customResolverName
            ) != nil
            return buildsFromItsOwnFields ? storedID : DNSResolverPreset.device.id
        }
        return DNSResolverPreset.allPresets.contains { $0.id == storedID }
            ? storedID
            : DNSResolverPreset.device.id
    }

    public var resolverPreset: DNSResolverPreset {
        if resolverPresetID == DNSResolverPreset.customID,
           let customResolver = DNSResolverPreset.custom(
                primaryRawValue: customResolverAddress,
                secondaryRawValue: customResolverSecondaryAddress,
                displayName: customResolverName
           ) {
            return customResolver
        }

        // AN ID THIS BUILD DOES NOT RECOGNISE IS NOT A CHOICE EITHER — it is a downgrade past a
        // preset that was added later, or a corrupted value. Same rule as the absent case in
        // `init(from:)`: fall back to the network's own resolver rather than silently routing a
        // user's lookups to a company they did not pick.
        return DNSResolverPreset.allPresets.first { $0.id == DNSResolverPreset.migratedPresetID(resolverPresetID) } ?? .device
    }

    /// The resolver the encrypted Device-DNS fallback routes to, resolved the same
    /// way as `resolverPreset` (Custom → built custom preset, else catalog lookup).
    public var fallbackResolverPreset: DNSResolverPreset {
        if fallbackResolverPresetID == DNSResolverPreset.customID,
           let customResolver = DNSResolverPreset.custom(
                primaryRawValue: fallbackCustomResolverAddress,
                secondaryRawValue: fallbackCustomResolverSecondaryAddress,
                displayName: fallbackCustomResolverName
           ) {
            return customResolver
        }

        // Deliberately NOT `.device`, unlike `resolverPreset` above: this field only ever runs
        // when the Device-DNS primary has wedged, so resolving it to the device's own resolver
        // would point the safety net at the thing it exists to rescue.
        return DNSResolverPreset.allPresets.first { $0.id == DNSResolverPreset.migratedPresetID(fallbackResolverPresetID) } ?? .quad9UnfilteredDoH
    }

    /// The resolver the chained T1 rung asks: the user's ONE resolver selection, carried
    /// through unchanged, or `nil` when there is no rung to run.
    ///
    /// WHY A WHOLE CONFIGURATION rather than a preset: the tunnel builds its runtime plan through
    /// `DNSResolverRuntimePlan.make(configuration:…)`, the only overload visible outside the
    /// package — the `resolver:`-taking one is `package`-scoped and `LavaSecTunnel` is a separate
    /// process target. Handing it a configuration gets the rung the user's own choice, on the
    /// user's own transport, with one call and no second copy of the plan-building rules in the
    /// tunnel.
    ///
    /// THE SELECTION IS NO LONGER COPIED FROM A SECOND PICKER, and that is the change: the rung
    /// used to resolve `chainedFallbackResolverPresetID`, a separate setting restricted to plain
    /// IPv4. It resolves `resolverPresetID` now, so DoH, DoT and DoQ reach the rung because the
    /// user can actually select them — the capability shipped in PR #590 and the reachability
    /// arrives here (the plan's S4 obligation, "persist the selected variant rather than coercing
    /// it").
    ///
    /// DEVICE DNS IS ELIGIBLE, and the refusal that used to sit here was wrong.
    ///
    /// It returned nil for `.deviceDNS` on the reasoning that the rung is the resolver the user
    /// chose and never the one DHCP handed them (`LAV-87`). That conflated two different acts:
    ///
    /// - A device-wide fallback EPISODE rewriting the rung into a device-DNS plan is still
    ///   forbidden, by `ignoresDeviceDNSFallbackMode: true` where the plan is built. Nothing
    ///   here relaxes that. Device DNS may not be IMPOSED on the rung.
    /// - A user whose one resolver selection IS Device DNS has ASKED for the network's own
    ///   resolver. Lava already sends every DNS-only query there, and Lava's blocklist runs
    ///   before the upstream query either way, so nothing about filtering changes. Refusing it
    ///   removed a property they had rather than protecting one.
    ///
    /// THE COMPARISON THAT SETTLED IT (founder, 2026-08-27). Native Tailscale with MagicDNS and
    /// no global nameservers serves tailnet names and lets everything else fall through to the
    /// system's own DHCP resolvers. Chaining through an exported WireGuard conf is a request for
    /// that same shape — tailnet names from the conf's `DNS =`, everything else from the user's
    /// own setting. Refusing the fall-through half left a chained user strictly worse off than
    /// running Tailscale directly, which is not a trade any threat model here justifies.
    ///
    /// `nil` NOW MEANS THE USER DECLINED IT. The Optional was previously unreachable — kept only
    /// because "can this selection be a rung at all" was a question a future selection type might
    /// answer no to — and `chainedTierOneFallbackEnabled` gives it a shipping meaning: the user
    /// turned the fallback off. Every caller already treated nil as the closed direction, which
    /// is exactly why the toggle is enforced here and not beside them. Whether a device-DNS rung
    /// has anything to ASK remains a RUNTIME question — the captured resolvers can be empty — and
    /// the tunnel answers that one, not this.
    /// ## The per-query device-DNS fallback is the USER'S OWN VALUE here, and it finally means
    /// something
    ///
    /// `LAV-87` forbids device DNS being IMPOSED on the rung — a device-wide fallback EPISODE
    /// rewriting the plan's primary transport, which is enforced separately by
    /// `ignoresDeviceDNSFallbackMode: true` at the plan site. It says nothing about the PER-QUERY
    /// fallback this flag gates, which is the user's own setting. So the rung carries `self`'s
    /// value, unmodified.
    ///
    /// IT USED TO BE FORCED FALSE, and before that it was briefly the user's value (PR #593) —
    /// both of which were the same non-event. The rung was dispatched into
    /// `ResolverOrchestrator.resolvePrimaryUpstream(_:plan:…rung: .tierOneFallback)`, which runs
    /// the primary route only, while `shouldFallbackToDeviceDNS` is read in the `resolveUpstream`
    /// wrapper one level up — so the flag's value could not reach the code that reads it (Codex
    /// P1, PR #593). Forcing it false was honest bookkeeping about an inert setting, not a
    /// policy.
    ///
    /// The rung now runs `resolveUpstream`, so the ladder beneath it exists and this flag is
    /// live. That is one change, not two: the same dispatch bug is why the T1 rung had no
    /// third rung of any kind — the field report behind it is a split-tunnel user on a train
    /// whose rung asked device resolvers captured on a tower the phone had left, with nothing
    /// below it (founder, 2026-08-27;
    /// `plans/2026-08-27-chained-resolver-adaptation-and-tier-three.md`, lavasec-infra).
    ///
    /// STILL NOT THE CAPTIVE-PORTAL CASE. There T0 is dead through the tunnel and the user's
    /// own selection is blocked by the portal, so the rescue must reach the network's own
    /// resolver — and in a FULL tunnel that additionally needs a bound socket the route plan
    /// cannot capture. The full-tunnel profile covers the resolver with `0.0.0.0/0`, so F2's
    /// `tierOneSocketBinding(destinationIsFloorClaimed:destinationIsProfileCovered:…)` correctly
    /// keeps it `.systemChosen` (and full tunnel has no physical T1 rung at all), leaving the
    /// route the routing table chose. That half remains open in
    /// `plans/2026-08-27-chained-proof-state-retry-and-fallback.md` (lavasec-infra).
    /// pinned: AppConfigurationTests.testTheTierOneConfigurationIsTheUsersOwnResolverSelection
    /// pinned: AppConfigurationTests.testADeviceDNSSelectionIsEligibleAsTheRung
    /// pinned: AppConfigurationTests.testTheRungCarriesTheUsersOwnDeviceFallbackSetting
    public var chainedTierOneResolverConfiguration: AppConfiguration? {
        // THE ONE GATE. See `chainedTierOneFallbackEnabled` for why it lives here and nowhere
        // else: nil is already every consumer's "no rung", so routing the toggle through it
        // cannot disagree with a second check somewhere downstream.
        guard chainedTierOneFallbackEnabled else { return nil }
        return self
    }

    /// The T1 selection as a list of ENDPOINTS the settings panel can enumerate and the
    /// tunnel's admission gate can judge — plain IP literals for a plain selection, the encrypted
    /// endpoint's host for an encrypted one, empty for Device DNS.
    ///
    /// NOT COERCED, and the difference is load-bearing. The old
    /// `chainedFallbackResolverAddresses` ran every preset through `plainDNSVariant`, so a DoH
    /// selection reduced to that provider's plain IPv4 and the tunnel latched an address the rung
    /// would never contact. That coerced array was also what the freshness check compared, so
    /// Cloudflare-plain → Cloudflare-DoH produced an identical array: the panel reported "current"
    /// while the session kept running plaintext (the plan's S4 obligation, "latch a
    /// transport-aware identity"). Both defects had the one cause and both are gone.
    ///
    /// IPv6 IS LISTED, not filtered out, even though `INV-CHAIN-1` keeps the chained rung IPv4-only
    /// and `fallbackOutcomes` refuses every v6 entry as ``ChainedFallbackDisposition/unusableIPv6``.
    /// Listing it is the point: a v6-only plain selection projected to an EMPTY list, and an empty
    /// list means the gate has nothing to refuse — so the panel enumerated nothing, the tunnel
    /// found no admitted address, and a split-tunnel session ran no rung with no statement anywhere
    /// that it had declined one (Codex P2, PR #591). A refusal the surface can name beats a silent
    /// absence. A mixed preset is unaffected: its v4 servers are admitted and the rung runs.
    ///
    /// A HOST, NOT A URL, for the encrypted entries. This list is published into the health
    /// snapshot, which travels in bug reports; a DoH URL can carry a path and a query, and a
    /// Custom entry's are the user's own. The host is what the panel needs to name the resolver
    /// and the least that does it. What the COUNTERS are keyed by is a different question with a
    /// different answer — see ``chainedTierOneResolverAttemptKeys``.
    /// pinned: AppConfigurationTests.testAnEncryptedSelectionEnumeratesItsEndpointHostRatherThanAPlainIPv4
    /// pinned: AppConfigurationTests.testAnIPv6PlainSelectionIsListedSoTheGateCanRefuseIt
    public var chainedTierOneResolverEndpoints: [String] {
        let preset = resolverPreset
        switch preset.transport {
        case .deviceDNS:
            // EMPTY BY CONSTRUCTION, not by refusal. A device-DNS selection names no addresses
            // in the configuration at all — the resolvers are whatever the network handed the
            // device, captured at runtime. The tunnel substitutes its live capture
            // (`PacketTunnelProvider.tierOneOutcomes`), which is the only place they exist.
            return []
        case .plainDNS:
            return preset.ipv4Servers + preset.ipv6Servers
        case .dnsOverHTTPS:
            return [preset.dohEndpoint, preset.secondaryDohEndpoint]
                .compactMap { $0?.url.host }
        case .dnsOverTLS:
            return [preset.dotEndpoint, preset.secondaryDotEndpoint]
                .compactMap { $0?.hostname }
        case .dnsOverQUIC:
            return [preset.doqEndpoint, preset.secondaryDoqEndpoint]
                .compactMap { $0?.hostname }
        }
    }

    /// The identifiers a T1 attempt is RECORDED under — what `ResolverAttempt.address` carries,
    /// and therefore what keys `resolverAttemptCounts` and its siblings in the health snapshot.
    ///
    /// A SECOND PROJECTION, because the display answer and the counter answer genuinely differ and
    /// conflating them silently broke the bug-report redaction. `ResolverOrchestrator.resolveEndpoints`
    /// records an encrypted attempt under the endpoint's `cacheIdentifier` — the complete
    /// `doh:<absolute URL>`, path and query included — while
    /// ``chainedTierOneResolverEndpoints`` publishes the bare host. The redaction folds resolver
    /// counters onto placeholders by matching those keys, so a host-only map matched nothing: a
    /// Custom DoH endpoint, which is the one a user hand-enters and the one most likely to name
    /// their own infrastructure, travelled into the report untouched, and the T1 counters it
    /// keyed were never attributed (Codex P1, PR #591).
    ///
    /// Plain selections are unaffected — for them the attempt key IS the address — which is why
    /// this was invisible until an encrypted resolver could become the rung.
    /// pinned: AppConfigurationTests.testAnEncryptedSelectionExposesTheCacheIdentifiersTheCountersUse
    public var chainedTierOneResolverAttemptKeys: [String] {
        let preset = resolverPreset
        switch preset.transport {
        case .deviceDNS:
            // See ``chainedTierOneResolverEndpoints``: the addresses are a runtime capture, and
            // the tunnel publishes them.
            //
            // EMPTY HERE IS NOT A REDACTION HOLE, and that is worth stating because this array
            // seeds the bug report's fold (`TunnelHealthSnapshot.redactedFallbackIdentities`).
            // For a device-DNS selection the counters key on the ADDRESS — plain attempts always
            // do — and those same addresses reach the fold through the snapshot's latched and
            // effective lists, both of which the tunnel fills from the live capture. The array is
            // load-bearing only for an ENCRYPTED selection, where the counter key
            // (`doh:<absolute URL>`) differs from the endpoint host and nothing else carries it
            // (Codex P1, PR #591).
            return []
        case .plainDNS:
            return preset.ipv4Servers + preset.ipv6Servers
        case .dnsOverHTTPS:
            return [preset.dohEndpoint, preset.secondaryDohEndpoint]
                .compactMap { $0?.cacheIdentifier }
        case .dnsOverTLS:
            return [preset.dotEndpoint, preset.secondaryDotEndpoint]
                .compactMap { $0?.cacheIdentifier }
        case .dnsOverQUIC:
            return [preset.doqEndpoint, preset.secondaryDoqEndpoint]
                .compactMap { $0?.cacheIdentifier }
        }
    }

    public var chainedTierOneResolverIdentity: String {
        Self.resolverIdentity(of: resolverPreset)
    }

    /// A preset's transport-aware identity: preset ID, transport and every endpoint.
    ///
    /// Shared by the primary selection and the encrypted fallback selection so the two cannot
    /// drift into comparing different things. Endpoints alone cannot separate one transport of a
    /// provider from another when both reach the same host — Cloudflare DoT and DoH differ in
    /// scheme and port, not in name — so the preset ID and transport lead.
    public static func resolverIdentity(of preset: DNSResolverPreset) -> String {
        // THE BOOTSTRAP SERVERS ARE PART OF THE ENDPOINT, and leaving them out let a running
        // session keep a superseded one. `cacheIdentifier` is `doh:<url>` / `dot:<host>:<port>` and
        // carries no bootstrap IPs — deliberately, because it keys the per-address counter maps and
        // must stay stable — so replacing a custom DNS stamp with one that has the SAME DoH URL or
        // DoT/DoQ hostname but DIFFERENT bootstrap IPs produced a byte-identical identity. The
        // ordinary resolver reload noticed the changed raw configuration, but the T1 relatch
        // compares this value, so the rung went on resolving through the old bootstrap servers
        // while the panel also reported the selection current (Codex P2, PR #599).
        //
        // Composed here rather than by widening `cacheIdentifier`, which would rekey the counter
        // maps and the bug report's redaction fold along with it.
        // pinned: AppConfigurationTests.testTheIdentitySeparatesTwoStampsSharingAnEndpointURL
        func identify(_ endpoint: DNSOverHTTPSEndpoint?) -> String? {
            endpoint.map { "\($0.cacheIdentifier)@\($0.allBootstrapServers.joined(separator: "+"))" }
        }
        func identify(_ endpoint: DNSOverTLSEndpoint?) -> String? {
            endpoint.map { "\($0.cacheIdentifier)@\($0.allBootstrapServers.joined(separator: "+"))" }
        }
        func identify(_ endpoint: DNSOverQUICEndpoint?) -> String? {
            endpoint.map { "\($0.cacheIdentifier)@\($0.allBootstrapServers.joined(separator: "+"))" }
        }
        let endpoints = preset.ipv4Servers + preset.ipv6Servers
            + [preset.dohEndpoint, preset.secondaryDohEndpoint].compactMap(identify)
            + [preset.dotEndpoint, preset.secondaryDotEndpoint].compactMap(identify)
            + [preset.doqEndpoint, preset.secondaryDoqEndpoint].compactMap(identify)
        return "\(preset.id)|\(preset.transport.rawValue)|\(endpoints.joined(separator: ","))"
    }

    /// Everything the T1 rung's LADDER is built from, not just which resolver it asks first.
    ///
    /// THE RESOLVER IDENTITY IS NOT ENOUGH, and treating it as enough was a fail-open. Since
    /// PR #596 the rung runs the FULL fallback ladder (`INV-CHAIN-7`), so its behaviour depends on
    /// the fallback policy as much as on the selection: `DNSResolverRuntimePlan.make` builds the
    /// rung's plan from `fallbackToDeviceDNS`, `usesEncryptedDeviceDNSFallback` and
    /// `fallbackResolverPreset` besides `resolverPreset`. A relatch keyed on the resolver identity
    /// alone therefore missed every one of those: turning device fallback OFF left a running
    /// session still sending failed T1 lookups to the device resolver until the next restart,
    /// which is the PR #575 privacy failure arriving through a third door (Codex P1, PR #599).
    ///
    /// DERIVED FROM ``resolverLadderInputs``, NOT FROM THE FIELDS DIRECTLY, and that indirection is
    /// the enforcement. `DNSResolverRuntimePlan.make(configuration:)` builds the plan from the same
    /// projection, so a fifth configuration field can only reach the ladder by being added to
    /// `ResolverLadderInputs` — at which point it lands here for free. A hand-listed set of fields
    /// here would silently fall behind the builder instead.
    /// pinned: AppConfigurationTests.testTheRungPolicyIdentityMovesWithEveryLadderInput
    public var chainedTierOneRungPolicyIdentity: String { resolverLadderInputs.identity }

    /// Every configuration input that steers the resolution LADDER — which resolver is asked
    /// first, and what happens when it does not answer.
    ///
    /// One projection with two consumers: `DNSResolverRuntimePlan.make(configuration:)` builds the
    /// runtime plan from it, and ``chainedTierOneRungPolicyIdentity`` fingerprints it to decide
    /// whether a running chained session must relatch its T1 rung. They cannot drift, which is
    /// the point — the relatch decision used to name the resolver only, so the three fallback
    /// fields moved without it and a running session kept the old fallback policy until restart
    /// (Codex P1, PR #599).
    public var resolverLadderInputs: ResolverLadderInputs {
        ResolverLadderInputs(
            resolver: resolverPreset,
            fallbackToDeviceDNS: fallbackToDeviceDNS,
            usesEncryptedDeviceDNSFallback: usesEncryptedDeviceDNSFallback,
            usesExplicitDNSTiers: usesExplicitDNSTiers,
            encryptedFallbackResolver: fallbackResolverPreset,
            configuredPrimaryTier: configuredPrimaryDNSResolverTier)
    }

    public var resolverDiagnosticDisplayName: String {
        resolverPresetID == DNSResolverPreset.customID ? "Custom DNS" : resolverPreset.displayName
    }
}

public struct AllowlistValidationResult: Equatable, Sendable {
    public let normalizedDomain: String?
    public let isAllowed: Bool
    public let message: String

    public static func allowed(_ domain: String) -> AllowlistValidationResult {
        AllowlistValidationResult(normalizedDomain: domain, isAllowed: true, message: "Allowed domain can be added.")
    }

    public static func rejected(_ message: String) -> AllowlistValidationResult {
        AllowlistValidationResult(normalizedDomain: nil, isAllowed: false, message: message)
    }
}

public struct AllowlistValidator: Sendable {
    public let nonAllowableThreatRules: DomainRuleSet

    public init(nonAllowableThreatRules: DomainRuleSet) {
        self.nonAllowableThreatRules = nonAllowableThreatRules
    }

    public func validate(_ rawDomain: String) -> AllowlistValidationResult {
        do {
            let normalized = try DomainName.normalize(rawDomain)
            if nonAllowableThreatRules.containsNormalized(normalized) {
                return .rejected("Some dangerous domains cannot be allowed.")
            }
            return .allowed(normalized)
        } catch {
            return .rejected(error.localizedDescription)
        }
    }
}

/// The configuration inputs that determine a resolution ladder.
///
/// Extracted so the runtime-plan builder and the T1 relatch fingerprint read the SAME set.
/// Adding a field here is what makes it visible to both; adding one to only the builder is what
/// used to leave a running session on a stale fallback policy (Codex P1, PR #599).
public struct ResolverLadderInputs: Hashable, Sendable {
    /// The saved canonical tier supplying the effective primary resolver.
    public let configuredPrimaryTier: DNSResolverTier
    public let usesExplicitDNSTiers: Bool
    public let resolver: DNSResolverPreset
    public let fallbackToDeviceDNS: Bool
    public let usesEncryptedDeviceDNSFallback: Bool
    public let encryptedFallbackResolver: DNSResolverPreset

    /// The DNS settings page's fallback selection, including when its switch is off.
    /// A provider primary falls back to Device DNS; a Device-DNS primary uses the
    /// separately selected provider. Unlike `ResolverTierTwo.resolve`, this preserves
    /// the selection while disabled and does not apply runtime admission constraints.
    public var configuredFallbackResolver: DNSResolverPreset {
        resolver.transport == .deviceDNS || (usesExplicitDNSTiers && usesEncryptedDeviceDNSFallback) ? encryptedFallbackResolver : .device
    }

    /// Whether the user permits the configured fallback. Runtime admission can still
    /// refuse it, for example when Device DNS has no captured resolver addresses.
    public var isConfiguredFallbackEnabled: Bool {
        resolver.transport == .deviceDNS ? usesEncryptedDeviceDNSFallback : (fallbackToDeviceDNS || (usesExplicitDNSTiers && usesEncryptedDeviceDNSFallback))
    }

    public init(
        resolver: DNSResolverPreset,
        fallbackToDeviceDNS: Bool,
        usesEncryptedDeviceDNSFallback: Bool,
        usesExplicitDNSTiers: Bool = false,
        encryptedFallbackResolver: DNSResolverPreset,
        configuredPrimaryTier: DNSResolverTier = .tierOne
    ) {
        self.configuredPrimaryTier = configuredPrimaryTier
        self.usesExplicitDNSTiers = usesExplicitDNSTiers
        self.resolver = resolver
        self.fallbackToDeviceDNS = fallbackToDeviceDNS
        self.usesEncryptedDeviceDNSFallback = usesEncryptedDeviceDNSFallback
        self.encryptedFallbackResolver = encryptedFallbackResolver
    }

    /// A stable string form, for comparing a session's latched ladder against the current one.
    ///
    /// Both resolvers carry their transport and endpoints, not just their preset ID: a custom
    /// entry keeps one ID across completely different addresses, and two transports of one
    /// provider reach the same host.
    public var identity: String {
        var terms = [
            AppConfiguration.resolverIdentity(of: resolver),
            fallbackToDeviceDNS ? "device-fallback-on" : "device-fallback-off",
            usesEncryptedDeviceDNSFallback ? "encrypted-fallback-on" : "encrypted-fallback-off"
        ]
        // Alternative T2 identity matters only when that tier is enabled.
        if usesEncryptedDeviceDNSFallback && (usesExplicitDNSTiers || resolver.transport == .deviceDNS) {
            terms.append(AppConfiguration.resolverIdentity(of: encryptedFallbackResolver))
        }
        if usesExplicitDNSTiers { terms.append("explicit-tiers") }
        if configuredPrimaryTier != .tierOne { terms.append("configured-primary:\(configuredPrimaryTier.rawValue)") }
        return terms.joined(separator: "#")
    }
}
