import XCTest

/// Repository-specific guards for the state opened by the AppViewModel file split.
///
/// Swift's `private(set)` cannot span concern files, so setters and the shared implementation
/// state are internal. These checks catch the corpus's write forms, coordinated-only primitives,
/// and escaping live-state handles in source outside the class. The compiler remains authoritative
/// for syntax and types; this is an architecture check, not a general Swift mutation analysis.
///
/// Conservative reads/key paths and ambiguous names require review instead of silently opening a
/// new coupling. Prefer the model's coordinated entry points, and keep new policy logic in package
/// types with executable tests rather than expanding the app's orchestration surface.
final class AppViewModelEncapsulationSourceTests: XCTestCase {
    /// Stored state whose SETTER opened up from `private(set)` to internal purely because the
    /// class spans files. Adding a name here is only correct when a sibling file must write it.
    static let widenedSetters = [
        "adminQAStatusMessage",
        "catalogGeneratedAt",
        "catalogStatusIsError",
        "catalogStatusMessage",
        "catalogVersion",
        "chainedConnectEstablishing",
        "chainedForwardingUnconfirmed",
        "chainedSetupReady",
        "chainedLifecycleNotice",
        "compiledBlocklistRuleCount",
        "compiledRuleCount",
        "filterEditTargetID",
        "filterPreparationFailureIsRetryable",
        "filterPreparationOrigin",
        "filterPreparationState",
        "isStagingChainedUpstreamForQA",
        "isVPNConfigurationInstalled",
        "lavaGuardProgress",
        "library",
        "libraryOriginatesFromLaunchReseed",
        "networkActivityLog",
        "pendingReviewRequest",
        "protectedRuleCount",
        "sourceStates",
        "sudokuGameState",
        "temporaryProtectionPauseUntil",
        "tunnelHealth",
        "vpnStatus",
    ]

    /// Stored state that was fully `private` before the split and is now internal for the same
    /// reason. `private(set)` is not the only guarantee a file split removes: a `private var` the
    /// class relied on — `sharedStateUnavailableAtLoad` gates the persistence funnels against an
    /// unreadable-launch placeholder — is just as writable from any app-target source once it is
    /// internal, and the first version of this suite did not cover it (Codex, PR #652).
    static let formerlyPrivateState = [
        "awaitsProtectionOnHaptic",
        "blockRules",
        "cachedBlockRuleSets",
        "catalogGuardrailEntryCount",
        "catalogSourcesByID",
        "chainedConnectLifecycleState",
        "chainedEstablishmentProgress",
        "chainedLifecycleMutationIdentity",
        "chainedLifecycleSamplingTask",
        "chainedOnDemandArmID",
        "chainedOnDemandArmTask",
        "configurationLoadedFromDisk",
        "configurationReplacementGate",
        "currentCatalog",
        "didReseedFilterLibraryOnLastLoad",
        "failClosedReconcileRetryAttempt",
        "failClosedReconcileRetryEpoch",
        "filterSnapshotPreparationService",
        "hasPendingWarmSwitchCacheRehydration",
        "isFailClosedReconcileRetryScheduled",
        "isForegroundManualSwitchInFlight",
        "isReconcilingPendingFilterSwitch",
        "isReconcilingWarmNonActiveFilters",
        "lastLavaGuardUsageAccrualAt",
        "lastLavaGuardUsageIsRunning",
        "lastObservedProtectionUptimeIsRunning",
        "lastProtectionStatusRefresh",
        "lastSurfacedTierBudgetMessage",
        "lastTunnelHealthFlushRequestedAt",
        "networkActivityLogReadGate",
        "pauseController",
        "pendingReconcileRerun",
        "pendingSwitchFilterID",
        "pendingWarmReconcileRerun",
        "protectionActionOrchestrator",
        "protectionSessionStore",
        "protectionTeardownDepth",
        "reseedSuppressionAwaitingUnlockConfirmation",
        "sharedStateUnavailableAtLoad",
        "threatGuardrail",
        "tunnelHealthReadGate",
        "tunnelManager",
        "userProtectionIntent",
        "vpnLifecycleController",
    ]

    /// Mutable TYPE-level state the split widened. `Self.isWarmPassInFlight` guards the background
    /// warm pass against re-entrancy, and it is written from a sibling concern file, so it had to
    /// widen with the rest — but `AppViewModel.isWarmPassInFlight = true` from outside would defeat
    /// the guard just as effectively as an instance write (Codex, PR #652).
    static let formerlyPrivateStaticState = [
        "isWarmPassInFlight",
        "warmPassRerunRequestedWindow",
    ]

    /// Everything the class can now have written from outside, which is what the split gave away.
    static var internallySettableState: [String] {
        widenedSetters + formerlyPrivateState + formerlyPrivateStaticState
    }

    /// Methods that may be CALLED through one of these properties from outside the class, because
    /// they only read. Everything else is treated as a write.
    ///
    /// 🔴 AN ALLOWLIST, NOT A BLACKLIST, AND THAT IS THE POINT. The previous version enumerated
    /// mutating methods, which cannot be complete: Swift's mutable-collection API alone offers
    /// `reverse`, `shuffle`, `swapAt`, `replaceSubrange` and more, and a reviewer found the list
    /// missing them (Codex, PR #652). Inverting it bounds the problem by THIS codebase instead of
    /// by Swift's surface: exactly two read methods are called through these properties today, and
    /// a new one is a deliberate act with a reviewer rather than a silent hole.
    static let readOnlyMethodsCallableFromOutside = [
        "filter",
        "progress",
    ]

    /// `private(set)` declarations the split did NOT have to widen. Pinned so a later edit cannot
    /// quietly widen them too.
    static let keptPrivateSetters = [
        "filterDrafts",
        "isConfiguringVPN",
        "catalog",
        "account",
        "backup",
        "plus",
        "reports",
        "customization",
    ]

    /// Source roots the `LavaSec` app target compiles — and ONLY those.
    ///
    /// `LavaSecWidget` and `LavaSecIntents` are separate targets in `project.yml` that never link
    /// `AppViewModel`, so nothing in them can write this state. Scanning them anyway would flag a
    /// widget's own unrelated `.vpnStatus` — the predicate matches property NAMES and cannot prove
    /// the receiver is an `AppViewModel` (Codex, PR #652).
    static let appTargetRoots = ["LavaSecApp", "Shared"]

    // MARK: - The predicate

    static let identifierEnd = "(?!" + sourceIdentifierCharacter + ")"
    static let identifierStart = "(?<!" + sourceIdentifierCharacter + ")"
    static func memberAccessPattern(for name: String) -> String {
        #"\.\s*`?"# + NSRegularExpression.escapedPattern(for: name) + "`?" + identifierEnd
    }
    static let operatorCharacterPattern = sourceOperatorCharacter
    static let nestedSubscriptPattern: String = {
        let inner = #"\[[^\[\]]*\]"#
        let nested = #"\[(?:[^\[\]]|"# + inner + #")*\]"#
        return #"\[(?:[^\[\]]|"# + nested + #")*\]"#
    }()

    /// Repository-supported write forms through an internal setter, pinned by the corpus below.
    ///
    /// Matched against the WHOLE source rather than line by line: an assignment may be split across
    /// a newline, and a line-scan can never see that (`\s*` cannot bridge a split the scanner has
    /// already made).
    static func writePatterns(for property: String) -> [String] {
        let name = NSRegularExpression.escapedPattern(for: property)
        // The property as it appears after a member-access dot, tolerating IDENTIFIER-ESCAPE
        // BACKTICKS. Swift accepts ``viewModel.`vpnStatus` = .connected``, which writes through the
        // widened setter exactly as the bare spelling does, and every pattern here placed the bare
        // name straight after the dot — so the backticks alone kept the invariant green (Codex,
        // PR #652). The trailing lookahead does the job `\b` did, that the name is not a prefix of
        // a longer identifier, and still works with a backtick in the way.
        let member = #"`?"# + name + "`?" + identifierEnd
        // `= v` but not `==`; every compound form Swift has.
        //
        // Including the OVERFLOW SHIFTS `&<<=` and `&>>=`. `&[-+*]=` covered `&+=`, `&-=` and
        // `&*=` only, and since this is anchored immediately after the path, nothing could consume
        // the `&` — so `x.p &<<= 1` was a legal write on `Int`/`UInt` that this pin could not see,
        // while plain `<<=` was caught (Kilo, PR #652).
        //
        // The last alternative covers CUSTOM operators. Swift lets a source define one — `<>=`,
        // `.=`, `~=` — and a mutating custom operator writes through the widened setter exactly as
        // a built-in does (Codex, PR #652). Rather than enumerate a set that can never be complete,
        // any run of operator-head characters ending in `=` and not starting or ending a comparison
        // counts: it is the shape an assignment operator has.
        // 🔴 COMPARISONS ARE EXCLUDED FIRST. `!=`, `<=`, `>=`, `==` and `~=` all fit "operator
        // characters then `=`", and admitting them flagged `viewModel.filterEditTargetID !=
        // detailTargetID` — a plain read — in `FilterMyListView.swift`. The real tree caught it, as
        // it has every time this predicate was widened. `<<=` and `>>=` survive the exclusion
        // because their second character is not `=`.
        // Swift's documented operator scalars, including combining/variation continuations.
        // https://docs.swift.org/swift-book/ReferenceManual/LexicalStructure.html#Operators
        let operatorHead = operatorCharacterPattern
        let assign = #"(?:=[^=]|[-+*/%&|^]=|<<=|>>=|&(?:[-+*]|<<|>>)=|\?\?=|"#
            + #"(?!(?:!=|<=|>=|==|~=))"# + operatorHead + #"+=(?!=))"#
        // A path continuing from the property: chained members and subscripts, `?`/`!` unwraps.
        // The subscript body allows nested indexes so `p[keys[i]] = v` is seen (Codex).
        //
        // Unbounded receiver fragments exclude newlines. These run over the whole file rather than
        // line by line — which is what lets the split assignment `x.p\n    = v` be seen — but a
        // negated class like `[^\]]` matches a newline too, so without this the path would chain a
        // property on one line to an unrelated call fifty lines below. That false-positived four
        // real read sites before it was bounded.
        //
        // WHITESPACE separators are the exception, and may cross a line. Swift's leading-dot
        // continuation makes `x.tunnelHealth\n    .upstreamFailureCount = 0` one expression, and a
        // separator that stopped at `[ \t]` could not see it (Kilo, PR #652). Letting only
        // whitespace bridge lines is safe in a way a negated class is not: any intervening CODE
        // stops the match, so the far-chaining this bound exists to prevent still cannot happen.
        // Balanced to three levels: `p[keys[sections[i]]] = v` is a real write, and each level has
        // to be spelled out because a regex cannot recurse (Codex, PR #652).
        // Subscript and tuple bodies MAY span lines within their matching delimiters. A wrapped
        // lvalue — `viewModel.sourceStates[\n    keys[index]\n] = state` — is an ordinary write
        // that a newline-excluding body could not match (Codex, PR #652).
        //
        // Safe for the same reason trivia is: a subscript body is BOUNDED by its brackets, so it
        // cannot run to an unrelated call far below the way an unbounded negated class can. The
        // brackets are what stop it, not the newline.
        let subscriptBody = nestedSubscriptPattern
        // Separators are plain whitespace because the source has already had its comments and
        // string literals blanked (`sourceOutsideCommentsAndStrings`, PR #651). Swift allows a
        // comment between any two tokens — `viewModel.vpnStatus/*note*/ = .connected` is an
        // ordinary write — and blanking upstream handles that while also stopping a write QUOTED
        // in a comment or a string from being reported.
        //
        // 🔴 ATOMIC, and this is not an optimisation. Blanking replaces a comment with SPACES, so
        // the text now carries whitespace runs as long as the comments in this codebase — hundreds
        // of characters. A non-atomic `[ \t\r\n]*` sits inside `path`, which is itself starred,
        // so each run offers exponentially many ways to split it: the whole-tree scan went from
        // ~53 s to over ten minutes and had to be killed. `(?>…)` forbids backtracking into a run
        // once consumed, which is always correct here — a whitespace run has exactly one useful
        // parse — and restores the scan to seconds.
        let trivia = #"(?>[ \t\r\n]*)"#
        let dot = trivia + #"\."# + trivia
        // Intermediate members may be backtick-escaped too, not just the protected one:
        // ``viewModel.`tunnelHealth`.`chainedFallbackLatchedAddresses`.removeAll()`` is one write
        // with an escape at every hop.
        let identifier = #"`?"# + sourceIdentifierHead + sourceIdentifierCharacter + #"*`?"#
        let pathMember = #"(?:"# + identifier + #"|[0-9]+)"#
        let path = #"(?:[?!]|"# + subscriptBody + #"|"# + dot + pathMember + #")*"#
        // Balanced path grouping is normalized by writeViolations before these patterns run.
        let receiver = dot + member
        let reads = readOnlyMethodsCallableFromOutside
            .map(NSRegularExpression.escapedPattern(for:))
            .joined(separator: "|")
        return [
            // x.p = v, x.p[k] = v, x.p.member = v, x.p.a[keys[i]] &+= v — one pattern, whole path.
            receiver + path + trivia + assign,
            // Any PAREN CALL through the property that is not a known read: `x.p.reverse()`,
            // `x.p.member.swapAt(…)`, `x.p!.placeValue(…)`.
            receiver + path + dot + #"(?!`?(?:"# + reads + ")`?" + identifierEnd + ")" + identifier + trivia + #"\("#,
            // Trailing-closure calls: `x.p.removeAll { … }` has no parentheses to key on, and a
            // short name list could never be complete either (Codex), so the read allowlist decides
            // here too. The catch is that `if let id = viewModel.p.member {` is textually identical
            // — an identifier followed by a brace — so `writeViolations` drops matches on lines that
            // OPEN a control-flow statement. That is the one place this predicate reads context.
            receiver + path + dot + #"(?!`?(?:"# + reads + ")`?" + identifierEnd + ")" + identifier + trivia + #"\{"#,
            // &x.p — inout, in ARGUMENT POSITION.
            //
            // Whitespace after `&` is legal (`mutate(& viewModel.p)`) and the receiver may itself
            // be subscripted (`mutate(&models[index].vpnStatus)`); both write through the widened
            // setter and both evaded the earlier class, which demanded a letter straight after `&`
            // and could not cross a `[` (Kilo, PR #652).
            //
            // 🔴 But `&` alone is not enough once a space may follow it: the second `&` of a
            // boolean `a && viewModel.p` then reads as an inout marker, which false-positived
            // three real SwiftUI bindings. Requiring `(`, `,` or `:` first pins the match to an
            // argument, which is the only place `&` means inout — and as a bonus a bitwise
            // `mask & viewModel.p`, a plain read, no longer matches either.
            // The receiver path may itself wrap: `mutate(&viewModel\n    .vpnStatus)` is a leading-dot
            // continuation Swift accepts, and a receiver class limited to `[ \t]` could not cross it
            // (Codex, PR #652). Same bounded-whitespace argument as everywhere else here.
            #"[(,:]"# + trivia + #"&"# + trivia + #"(?:\("# + trivia + #")*"# + identifier + path + dot + member,
            // $viewModel.p — a settable SwiftUI binding, which private(set) used to forbid.
            //
            // The receiver may be a PATH, not just one identifier: `$models[index].vpnStatus` and
            // `$store.viewModel.vpnStatus` both form a writable key path through the widened
            // setter, and requiring the name straight after the first identifier saw neither
            // (Codex, PR #652). `path` is the same fragment the assignment patterns use, so
            // subscripts and chained members are admitted here on identical terms.
            #"\$"# + identifier + path + dot + member,
            // ANY key path to this state, `\.p` or `\Root.p`.
            //
            // Deliberately NOT narrowed to the writable spellings. Swift infers
            // `ReferenceWritableKeyPath` CONTEXTUALLY — `assign(\.vpnStatus, .connected)` carries no
            // type name and no `=`, so no textual rule can separate it from a read-only `KeyPath`
            // (Codex, PR #652). No source outside the class forms a key path to any of this state
            // today, so flagging all of them costs nothing now and makes the first one a reviewer's
            // decision — the same trade as the read allowlist above.
            // `\Root.p` and `\Module.Root.p` — Swift accepts a module-qualified root, and
            // permitting one component made the qualified spelling read-only to this scan while
            // the widened setter accepts it (Codex, PR #652).
            #"\\"# + trivia + identifier + path + dot + member,
            #"\\"# + dot + member,
            // viewModel[keyPath: …p…] = v
            #"\[keyPath:[^\]\n]*\."# + member + #"[^\]\n]*\]\s*"# + assign,
        ]
    }

    /// Compile each property's patterns once; the shared Swift scalar ranges are substantial.
    static let writeExpressions = Dictionary(uniqueKeysWithValues: internallySettableState.map { name in
        (name, writePatterns(for: name).map { try! NSRegularExpression(pattern: $0) })
    })

    /// Statement openers whose brace is control flow, not a trailing closure.
    static let controlFlowOpeners = ["if ", "guard ", "while ", "for ", "switch ", "} else"]

    /// Balanced delimiter offsets in already-blanked source. UTF-16 preserves Foundation ranges.
    static func parenthesisPairs(in code: String) -> [(open: Int, close: Int)] {
        var stack: [Int] = []
        var pairs: [(Int, Int)] = []
        for (offset, unit) in code.utf16.enumerated() {
            if unit == 40 { stack.append(offset) }
            if unit == 41, let open = stack.popLast() { pairs.append((open, offset)) }
        }
        return pairs
    }

    /// Peel balanced grouping around plain member paths, from inside out. Function argument lists
    /// stay intact: mutating a value returned by copy(x.p) need not mutate x.p itself.
    static func unwrappingGroupedPaths(in code: String, pairs: [(open: Int, close: Int)]) -> String {
        let identifier = #"`?"# + sourceIdentifierHead + sourceIdentifierCharacter + #"*`?"#
        let path = try! NSRegularExpression(pattern:
            #"^\s*"# + identifier + #"(?:\s*[?!]|\s*\.\s*(?:"# + identifier
            + #"|[0-9]+)|\s*"# + nestedSubscriptPattern + #")*\s*$"#)
        let callPrefix = try! NSRegularExpression(pattern: #"(?:"# + identifier + #"|[)\]?!])\s*$"#)
        let keyword = try! NSRegularExpression(pattern: identifierStart + #"(?:return|throw|yield|await|try[?!]?)\s*$"#)
        var units = Array(code.utf16)
        for pair in pairs {
            let content = String(decoding: units[(pair.open + 1)..<pair.close], as: UTF16.self)
            guard internallySettableState.contains(where: content.contains),
                  path.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
            else { continue }
            let prefix = String(decoding: units[..<pair.open], as: UTF16.self)
            let range = NSRange(prefix.startIndex..., in: prefix)
            if callPrefix.firstMatch(in: prefix, range: range) != nil,
               keyword.firstMatch(in: prefix, range: range) == nil { continue }
            units[pair.open] = 32
            units[pair.close] = 32
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Line numbers (1-based) of every write to the class's internally-settable state in `source`.
    static func writeViolations(in source: String) -> [(line: Int, property: String)] {
        // Comments and string literals are BLANKED, not dropped — lengths and newlines are kept,
        // so reported line numbers are the file's own. `sourceCodeOnly` REMOVES comment lines,
        // which shifted every subsequent line and sent the reader tens of rows off.
        let originalCode = sourceOutsideCommentsAndStrings(source)
        let pairs = parenthesisPairs(in: originalCode)
        let code = unwrappingGroupedPaths(in: originalCode, pairs: pairs)
        let originalText = originalCode as NSString
        // A balanced tuple followed by assignment contains lvalues at any nesting depth.
        let codeUnits = Array(originalCode.utf16)
        let tupleAssignments = pairs.filter { pair in
            var next = pair.close + 1
            while next < codeUnits.count, [9, 10, 13, 32].contains(codeUnits[next]) { next += 1 }
            return next < codeUnits.count && codeUnits[next] == 61
                && (next + 1 == codeUnits.count || codeUnits[next + 1] != 61)
        }
        let lines = code.split(separator: "\n", omittingEmptySubsequences: false)
        var found: [(Int, String)] = []
        for property in internallySettableState {
            // Cheap literal pre-filter. EVERY pattern below contains the property name, so a file
            // that does not mention it at all cannot match any of them — and most files mention
            // almost none of the 76 names. Without this the engine attempts a match at every
            // position of every file for every property, because each pattern begins with a
            // quantifier rather than a literal it can anchor on; the whole-tree scan took ~295 s.
            guard code.contains(property) else { continue }
            let tupleMember = try! NSRegularExpression(pattern:
                memberAccessPattern(for: property))
            for pair in tupleAssignments {
                let range = NSRange(location: pair.open + 1, length: pair.close - pair.open - 1)
                for match in tupleMember.matches(in: originalCode, range: range) {
                    let line = originalText.substring(to: match.range.location).filter { $0 == "\n" }.count + 1
                    found.append((line, property))
                }
            }
            for (index, expression) in writeExpressions[property, default: []].enumerated() {
                let range = NSRange(code.startIndex..., in: code)
                for match in expression.matches(in: code, range: range) {
                    guard let matchRange = Range(match.range, in: code) else { continue }
                    let line = code[code.startIndex..<matchRange.lowerBound].filter { $0 == "\n" }.count + 1
                    // The trailing-closure pattern cannot tell `x.p.removeAll { … }` from
                    // `if let id = x.p.member {`. Two things decide, and BOTH are needed: the line
                    // opens a control-flow statement, AND the matched `{` is the last thing on the
                    // line — i.e. it opens the statement body. A one-line branch such as
                    // `if reset { viewModel.p.list.removeAll { … } }` keeps its match, because
                    // there the brace is followed by the closure's own code (Codex, PR #652).
                    if index == trailingClosurePatternIndex, line - 1 < lines.count {
                        let text = lines[line - 1].trimmingCharacters(in: .whitespaces)
                        let opensStatement = Self.controlFlowOpeners.contains(where: text.hasPrefix)
                        let afterMatch = code[matchRange.upperBound...]
                            .prefix { $0 != "\n" }
                            .trimmingCharacters(in: .whitespaces)
                        let linePrefix = code[..<matchRange.lowerBound]
                            .split(separator: "\n", omittingEmptySubsequences: false).last ?? ""
                        let bodyDepth = linePrefix.reduce(0) { depth, character in
                            if character == "{" { return depth + 1 }
                            if character == "}" { return max(0, depth - 1) }
                            return depth
                        }
                        if opensStatement, afterMatch.isEmpty, bodyDepth == 0 { continue }
                    }
                    found.append((line, property))
                }
            }
        }
        return found.map { (line: $0.0, property: $0.1) }
    }

    /// Index of the trailing-closure pattern within ``writePatterns(for:)``.
    static let trailingClosurePatternIndex = 2

    /// Implementation methods widened solely to share them between concern files. Preserve the
    /// former access boundary for the complete inventory instead of guessing which helper needs
    /// a lifecycle gate. A rename must update this list; the test checks every declaration.
    ///
    /// Two names also have intentional outside-facing overloads: pauseProtectionTemporarily and
    /// sendTunnelMessage. Their public APIs remain callable; this name-based guard cannot resolve
    /// overload signatures. Other same-name collisions are conservatively reported for review.
    static let coordinatedOnlyPrimitives = [
        "appendAppNetworkActivity", "appendNetworkActivity", "applyCatalogSyncResult",
        "applyReusablePreparedSnapshot", "applySyncResults", "beginChainedEstablishmentDiagnostics",
        "beginFreshProtectionVPNSession", "beginProtectionTeardown", "bundleInfoValue",
        "cancelChainedEstablishmentDiagnostics", "clearFailClosedReconcileRetryLadder", "clearLibraryOriginatesFromLaunchReseed",
        "clearTemporaryProtectionPause", "confirmReseedSuppressionAfterUnlock", "currentPublishedArtifactPointerToken",
        "currentSnapshot", "customBlocklistDisplayKey", "customBlocklistSource",
        "deviceFamilyDescription", "disableProtection", "dismissPreparationCoverIfStrandedBySupersession",
        "domainHistoryDomainActionRejectionTitle", "drainChainedOnDemandArm", "duplicateName",
        "enableProtection", "enabledCustomBlocklistIdentities", "enabledCustomBlocklists",
        "endProtectionTeardown", "endProtectionVPNSession", "errorDebugDetails",
        "errorIdentityDetails", "estimatedBlocklistRuleCount", "executeChainedConnectLifecycleEffects",
        "filterPreparationFailureMessage", "filterRuleBudgetMessage", "hasReusableArtifactForCurrentConfiguration",
        "isLocalProtectionUptimeStatus", "isOnDemandConfirmedEnabled", "isProtectionEnabledStatus",
        "isProtectionStopPendingStatus", "isProtectionTransitionStatus", "listSummary",
        "loadBackgroundWarmIndex", "loadCachedCatalogAfterSyncFailure", "loadCachedCatalogIfAvailable",
        "loadExistingTunnelManager", "loadLavaGuardProgress", "loadOrCreateTunnelManager",
        "loadPersistedConfiguration", "loadPreparedFilterSummaryForCurrentConfiguration", "loadSudokuGameState",
        "loadTemporaryProtectionPause", "logFocusSwitchEvent", "logVPNDebugEvent",
        "makeLatencyTrace", "makeProtectionRestoreRequest", "markLibraryOriginatesFromPersistedRecoveryReseed",
        "matchingTunnelManagers", "migrateLowRiskLaunchCacheIfNeeded", "mirrorActiveFilterIntoConfiguration",
        "modificationDate", "neutralizeInheritedProtectionDuringOnboarding", "noteFilterUpdatedReviewMoment",
        "notifyTunnelProtectionPauseUpdated", "notifyTunnelSnapshotUpdated", "persistConfigurationOnly",
        "persistExplicitProtectionIntent", "persistFilterChanges", "persistFilterLibrary",
        "persistFilterReseedDroppingDurableMarkerWhenLanded", "persistLavaGuardProgress", "persistLibraryOnlyChange",
        "persistPreparedSnapshotArtifacts", "persistResolverSettings", "persistSharedState",
        "persistedLibraryArtifactTokens", "prepareChainedStateForExplicitGuardStart", "prepareFilterSnapshot",
        "preparedSnapshotForCurrentConfiguration", "preparedSnapshotForProtectionStartup", "rebuildEnabledBlockRules",
        "reconcileChainedUpstreamAfterEligibilityChange", "reconcileTierBudgetStatusAfterPlanOrRestoreChange", "reconcileTunnelSnapshotAfterLaunch",
        "reconcileWarmNonActiveFilters", "reconnectProtectionNow", "recordUserInitiatedProtectionOnForReview",
        "recoverUserProtectionIntentFromDurableState", "reduceChainedConnectLifecycleState", "refreshCompiledBlocklistRuleCount",
        "rehydrateRuleSetCachesAfterWarmSwitch", "reloadSharedStateIfBlockedByDataProtection", "requestTunnelHealthFlush",
        "reseedSuppressionMarkerState", "restoreFiltersAfterTemporaryProtectionPause", "restoreProtectionIfNeeded",
        "resumeTemporaryProtectionIfExpired", "runVPNStartupDebugProbe", "scheduleBackgroundCustomBlocklistRefresh",
        "scheduleFailClosedReconcileRetryIfNeeded", "scheduleProtectionNotificationIfNeeded", "scheduleTemporaryProtectionResume",
        "setManagerOnDemand", "startOnboardingBlocklistSyncIfNeeded", "startOnboardingDefaultBlocklistSyncIfNeeded",
        "surfaceSnapshotReconcileFailureStatusMessage", "surfaceTierBudgetStatusMessage", "synchronizeLavaGuardProgress",
        "synchronizeLocalProtectionUptime", "tunnelManagerDebugDetails", "uniqueFilterName",
        "updateCustomBlocklistHashes", "updateProtectionStatus", "updateProtectionStatusFromCachedManager",
        "vpnErrorMessage", "vpnStatusDebugDescription", "vpnStatusReportDescription",
        "warmNonActiveFiltersInBackground", "warmReusableSnapshotForSwitch", "widerWarmWindow",
        "withFocusDiagnosticsConsent",
    ]

    /// Every app-target Swift source that is NOT one of the class's own files, as (path, text).
    static func appTargetSourcesOutsideTheClass() throws -> [(String, String)] {
        let classFiles = Set(SourceFile.appViewModelSources.map(\.rawValue))
        var sources: [(String, String)] = []
        for root in appTargetRoots {
            let rootURL = packageRootURL.appendingPathComponent(root)
            // 🔴 A failed enumeration must FAIL, not `continue`. Skipping it leaves an empty scan
            // and both pins that use this pass over nothing — the silently-vacuous shape this
            // suite exists to prevent, reintroduced by the refactor that extracted this helper
            // (Kilo, PR #652).
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL, includingPropertiesForKeys: nil) else {
                throw SourceIntrospectionFailure(description: """
                    could not enumerate \(root)/ — every pin that scans outside the class would \
                    scan nothing and pass.
                    """)
            }
            while let url = enumerator.nextObject() as? URL {
                guard url.pathExtension == "swift" else { continue }
                let relative = root + "/" + url.path.dropFirst(rootURL.path.count + 1)
                guard !classFiles.contains(relative) else { continue }
                sources.append((relative, try String(contentsOf: url, encoding: .utf8)))
            }
        }
        return sources
    }

    /// State whose shared storage makes a read as dangerous as a write.
    ///
    /// `tunnelManager` is an `NETunnelProviderManager`, a reference type. `private` used to keep it
    /// inside the class; internal means any app-target file can take the reference and later call
    /// `connection.stopVPNTunnel()` or mutate the profile, entirely outside the model's lifecycle
    /// accounting — no assignment involved, so the write predicate can never see it (Codex,
    /// PR #652).
    ///
    /// This includes actors and value wrappers over shared storage: copying ProtectionSessionStore
    /// permits persisted writes, and a copied Task retains cancellation authority. The pre-split
    /// property audit also includes the background index, defaults and private storage URLs.
    /// Copying a value wrapper or URL must not become a path around coordinated persistence.
    static let referenceStateThatMustNotEscape = [
        "tunnelManager", "protectionActionOrchestrator", "pauseController", "vpnLifecycleController",
        "filterSnapshotPreparationService", "protectionSessionStore", "backgroundWarmIndexStore",
        "defaults", "appGroupDefaults", "catalogCacheURL", "configurationURL", "filterLibraryURL",
        "networkActivityLogURL", "pendingFilterSwitchMarkerLockURL",
        "chainedLifecycleSamplingTask", "chainedOnDemandArmTask",
        "protectionStatusRefreshCoordinator", "liveActivityController", "protectionUserNotifications",
    ]


    /// Every WRITE form the predicate must catch. Each is a write the compiler refused before the
    /// split; the awkward ones were found by review, not by imagination.
    static let writeForms = [
            #"viewModel.sourceStates["x"] = .sync"#,
            "viewModel.sourceStates[id] = sourceState",
            "viewModel.sourceStates.removeAll()",
            "viewModel.library.setActiveFilter(id: id)",
            "viewModel.library.syncActiveFilter(from: configuration)",
            "viewModel.networkActivityLog.clear()",
            "viewModel.lavaGuardProgress.clearUsageProgress()",
            "viewModel.sudokuGameState?.placeValue(3, at: cell)",
            "viewModel.sudokuGameState!.placeValue(3, at: cell)",
            "viewModel.tunnelHealth.upstreamFailureCount = 0",
            "viewModel.tunnelHealth.resolverAttemptCounts[id] = 1",
            "viewModel.tunnelHealth.chainedFallbackLatchedAddresses.append(value)",
            "viewModel.tunnelHealth.chainedFallbackLatchedAddresses.reverse()",
            "viewModel.tunnelHealth.清除()",
            "viewModel.tunnelHealth.filter🦊()",
            "viewModel.tunnelHealth.progress🦊 { mutate() }",
            "mutate(&🦊.protectedRuleCount)",
            #"let path = \🦊Store.models[0].vpnStatus"#,
            "viewModel.tunnelHealth.chainedFallbackLatchedAddresses.swapAt(0, 1)",
            "viewModel.tunnelHealth.chainedFallbackLatchedAddresses.sort { $0 < $1 }",
            "viewModel.tunnelHealth.chainedFallbackLatchedAddresses.removeAll { $0 == address }",
            #"let path: WritableKeyPath<AppViewModel, NEVPNStatus> = \.vpnStatus"#,
            "viewModel.sharedStateUnavailableAtLoad = false",
            "viewModel.blockRules = DomainRuleSet()",
            "AppViewModel.isWarmPassInFlight = true",
            #"let path: WritableKeyPath<AppViewModel, NEVPNStatus> = \AppViewModel.vpnStatus"#,
            "if shouldReset { viewModel.tunnelHealth.chainedFallbackLatchedAddresses.removeAll { $0 == a } }",
            "if shouldReset { viewModel.tunnelHealth.chainedFallbackLatchedAddresses.removeAll {\n $0 == a\n} }",
            "viewModel.sourceStates[keys[sections[index]]] = state",
            "assign(\\.vpnStatus, .connected)",
            #"let path: KeyPath<AppViewModel, NEVPNStatus> = \.vpnStatus"#,
            #"items.map(\.vpnStatus)"#,
            "viewModel.sourceStates[keys[index]] = state",
            "viewModel.sourceStates[\n    keys[index]\n] = state",
            "viewModel.compiledRuleCount += 1",
            "viewModel.compiledRuleCount &+= 1",
            "viewModel.compiledRuleCount <<= 1",
            "viewModel.vpnStatus = .connected",
            "viewModel.vpnStatus\n    = .connected",
            "viewModel . vpnStatus = .connected",
            "viewModel . tunnelHealth . upstreamFailureCount = 0",
            "(viewModel.vpnStatus, localStatus) = (.connected, value)",
            #"let path: ReferenceWritableKeyPath<AppViewModel, NEVPNStatus> = \.vpnStatus"#,
            "viewModel[keyPath: \\AppViewModel.vpnStatus] = .connected",
            "doThing(&viewModel.protectedRuleCount)",
            #"TextField("x", text: $viewModel.catalogStatusMessage)"#,
            // Found by review, PR #652 — each of these evaded the predicate and each is a write
            // the compiler refused before the split.
            "viewModel.compiledRuleCount &<<= 1",
            "viewModel.compiledRuleCount &>>= 1",
            "viewModel.tunnelHealth\n    .upstreamFailureCount = 0",
            "mutate(& viewModel.sourceStates)",
            "mutate(&models[index].vpnStatus)",
            // Wrapped across lines — the standard shape once a call exceeds the line limit, and a
            // coverage regression when the inout anchor was tightened (Kilo, PR #652).
            "mutate(\n    &viewModel.protectedRuleCount\n)",
            "mutate(\n    a,\n    &models[index].vpnStatus\n)",
            "mutate(&viewModel\n    .vpnStatus)",
            "viewModel.compiledRuleCount <>= 1",
            "viewModel.compiledRuleCount <~~>= 1",
            "viewModel.compiledRuleCount ⊕= 1",
            "viewModel.compiledRuleCount ⊕\u{0301}= 1",
            "(viewModel.vpnStatus,\n localStatus) = (.connected, value)",
            "viewModel.chainedEstablishmentProgress!.1 += 1",
            "mutate(&(viewModel.protectedRuleCount))",
            "mutate(&viewModel!.protectedRuleCount)",
            #"let path = \AppViewModel /* note */ .vpnStatus"#,
            #"assign(\ /* note */.vpnStatus, .connected)"#,
            #"let path = \ AppViewModel.vpnStatus"#,
            #"let path = \Store.models[0].vpnStatus"#,
            // Found by review, PR #652 — trivia around the selector dot, a module-qualified key
            // path, and a write that EXECUTES inside a string interpolation.
            "viewModel.library /* note */ . /* note */ setActiveFilter(id: id)",
            #"let path: WritableKeyPath<AppViewModel, NEVPNStatus> = \LavaSec.AppViewModel.vpnStatus"#,
            #"let line = "\(viewModel.library.setActiveFilter(id: id))""#,
            "mutate(a, &models[index].tunnelHealth.upstreamFailureCount)",
            "(viewModel.tunnelHealth).upstreamFailureCount = 0",
            "(viewModel.tunnelHealth).chainedFallbackLatchedAddresses.removeAll()",
            "(viewModel.vpnStatus) = .connected",
            "((viewModel.vpnStatus)) = .connected",
            "( ( (viewModel.vpnStatus) ) ) = .connected",
            "((viewModel.tunnelHealth)).upstreamFailureCount = 0",
            "((viewModel.tunnelHealth)).chainedFallbackLatchedAddresses.removeAll()",
            "(viewModel.tunnelHealth.chainedFallbackLatchedAddresses[indexes[0]]).append(\"x\")",
            "try (viewModel.blockRules).insert(domain: \"example.com\")",
            "try? (viewModel.blockRules).insert(domain: \"example.com\")",
            "try! (viewModel.blockRules).insert(domain: \"example.com\")",
            "((viewModel.vpnStatus, localStatus), third) = ((.connected, value), value2)",
            "viewModel.`vpnStatus` = .connected",
            "viewModel.`tunnelHealth`.upstreamFailureCount = 0",
            "viewModel.`tunnelHealth`.`chainedFallbackLatchedAddresses`.removeAll()",
            "viewModel.vpnStatus/*note*/ = .connected",
            "viewModel.tunnelHealth/*note*/.upstreamFailureCount = 0",
            "viewModel.tunnelHealth.chainedFallbackLatchedAddresses.removeAll/*note*/ { $0 == a }",
            #"TextField("x", text: $models[index].catalogStatusMessage)"#,
            #"TextField("x", text: $store.viewModel.catalogStatusMessage)"#,
            #"Toggle("x", isOn: $store.models[index].viewModel.sharedStateUnavailableAtLoad)"#,]

    /// Reads and literal payloads that must not be reported — the brake on over-reach.
    static let readForms = [
            "let count = viewModel.compiledRuleCount",
            "other.vpnStatus🦊 = 1",
            "(other.vpnStatus🦊, value) = (1, 2)",
            "if viewModel.pendingReviewRequest, scenePhase == .active {",
            "hub.lavaGuardProgress.progress(for: guardID, ledger: ledger)",
            #"Text(viewModel.catalogStatusMessage)"#,
            "guard viewModel.vpnStatus == .connected else { return }",
            "let snapshot = viewModel.tunnelHealth",
            "let active = viewModel.library.activeFilter",
            "if let match = viewModel.library.filter(id: id) {",
            "!viewModel.networkActivityLog.entries.isEmpty",
            "if let id = viewModel.library.activeFilterID {",
            "if viewModel.tunnelHealth.isChainedUpstreamActive {",
            "if viewModel.library.activeFilter.isEmpty {",
            // Swift treats this as regex syntax, not executable interpolation (PR #660).
            ##"let r = #/\#(mutate(&viewModel.protectedRuleCount))/#"##,
            "copy((viewModel.tunnelHealth)).upstreamFailureCount = 0",
            "copy /* note */ ((viewModel.tunnelHealth)).chainedFallbackLatchedAddresses.removeAll()",
    ]

    // MARK: - The coverage ratchet

    /// Floors for the write/read corpora, set to the EXACT current counts.
    ///
    /// Exact, not slack. A floor below the real count tolerates silent removals up to the gap — my
    /// first version left five of slack, so deleting a write form still passed and the ratchet did
    /// not ratchet. Adding coverage means bumping these by hand, which is the point: the number is
    /// a deliberate statement about how much evidence exists.
    ///
    /// 🔴 THIS EXISTS BECAUSE THE HARNESS HAD AN ASYMMETRIC ORACLE, and that asymmetry — not
    /// carelessness — caused every repeated regression while this predicate was written.
    ///
    /// WIDENING the predicate has a loud automatic detector: `testNoSourceOutsideTheClassWritesA
    /// WidenedProperty` scans the whole real app tree on every `swift test` and must find nothing,
    /// so an over-reach fails immediately. Three of three over-reaches were caught that way, inside
    /// the commit that made them — `a && viewModel.p` read as inout, `!=` read as an assignment,
    /// `.disabled(viewModel.p)` read as a mutating call on a parenthesised value.
    ///
    /// NARROWING it had no detector. A clean tree stays clean whether the predicate sees a write
    /// form or not, so lost coverage is invisible — and four of four coverage losses shipped and
    /// were caught only by external review. The worst was an inout anchor tightened to fix a false
    /// positive, which silently dropped the wrapped multi-line call the LOOSER pattern had caught:
    /// net coverage went DOWN in a commit titled "Close five predicate evasions".
    ///
    /// The corpus is the missing detector. Every write form stays, and the count only goes up.
    static let writeFormFloor = 91
    static let readFormFloor = 17

    func testTheWriteCorpusOnlyGrowsAndCannotBePadded() {
        // `writeForms` and `readForms` are the two halves of the same brake: the write corpus
        // catches narrowing, the read corpus catches the over-widening that narrowing fixes cause.
        XCTAssertGreaterThanOrEqual(
            Self.writeForms.count, Self.writeFormFloor,
            """
            A write form was removed from the corpus. The floor only goes up — if the predicate \
            genuinely no longer needs to catch a form, argue it in the diff rather than shrinking \
            the evidence that it does.
            """
        )
        XCTAssertGreaterThanOrEqual(
            Self.readForms.count, Self.readFormFloor,
            "a read form was removed; the brake on over-reach is what keeps narrowing fixes honest"
        )
        XCTAssertEqual(Set(Self.writeForms).count, Self.writeForms.count,
                       "duplicate write forms inflate the count without adding coverage")
        XCTAssertEqual(Set(Self.readForms).count, Self.readForms.count,
                       "duplicate read forms inflate the count without adding coverage")
    }

    // MARK: - The pins

    /// No source outside the class writes a property whose setter only opened up because of the
    /// split. The executable corpus records the supported write forms.
    func testNoSourceOutsideTheClassWritesAWidenedProperty() throws {
        var violations: [String] = []
        let sources = try Self.appTargetSourcesOutsideTheClass()
        XCTAssertGreaterThan(sources.count, 50, "the walk found almost nothing — this pin is vacuous")
        for (relative, text) in sources {
            for hit in Self.writeViolations(in: text) {
                violations.append("\(relative):\(hit.line) writes \(hit.property)")
            }
        }
        XCTAssertEqual(
            violations, [],
            """
            Only AppViewModel's own files may write these properties — their setters are internal \
            solely because `private(set)` cannot span the files of one class.
            """
        )
    }

    /// No source outside the class CALLS a primitive that must go through its coordinated entry
    /// point. The list above described that rule; nothing read it, so `await
    /// viewModel.disableProtection()` passed the whole suite while retaining exactly the
    /// stale-intent and unclaimed-orchestrator behaviour the rule exists to prevent (Codex,
    /// PR #652).
    func testNoSourceOutsideTheClassCallsACoordinatedOnlyPrimitive() throws {
        let classCode = sourceOutsideCommentsAndStrings(try readAppViewModelSource())
        XCTAssertEqual(Set(Self.coordinatedOnlyPrimitives).count, Self.coordinatedOnlyPrimitives.count)
        for name in Self.coordinatedOnlyPrimitives {
            let declaration = try NSRegularExpression(pattern:
                Self.identifierStart + #"func\s+"# + NSRegularExpression.escapedPattern(for: name) + #"\s*(?:<|\()"#)
            XCTAssertNotNil(declaration.firstMatch(in: classCode, range: NSRange(classCode.startIndex..., in: classCode)),
                            "Update the implementation-method inventory after renaming \(name).")
        }
        for name in Self.coordinatedOnlyPrimitives {
            let access = try NSRegularExpression(pattern: Self.memberAccessPattern(for: name))
            for (code, expected) in [("model.\(name)", true), ("service.\(name)🦊()", false)] {
                XCTAssertEqual(access.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil, expected)
            }
        }
        var violations: [String] = []
        let sources = try Self.appTargetSourcesOutsideTheClass()
        XCTAssertGreaterThan(sources.count, 50, "the walk found almost nothing — this pin is vacuous")
        for (relative, text) in sources {
            let code = sourceOutsideCommentsAndStrings(text)
            for primitive in Self.coordinatedOnlyPrimitives {
                guard code.contains(primitive) else { continue }
                // A call through ANY receiver. Two honest caveats, because the first version of
                // this comment claimed more than the pattern delivers (Kilo, PR #652):
                //
                // The class's own `self.disableProtection()` is excluded because the class's files
                // are filtered out of this walk entirely — not by the pattern, which would match it.
                //
                // A same-named method on an unrelated type IS matched. That is a false positive
                // waiting for the first `someCoordinator.disableProtection()`, and it is the
                // direction to err in: a name collision on a lifecycle primitive is worth a human
                // look, and the failure names the file and the primitive.
                // Any member ACCESS, called or not. `let stop = viewModel.disableProtection`
                // binds the method and invokes it later with its own arguments, which requiring a
                // following `(` could never see (Codex, PR #652) — and a reference taken is a
                // bypass whether or not this file also calls it.
                //
                // The dot is the same trivia-aware one the write predicate uses, so
                // `await viewModel./* why */disableProtection()` is caught too.
                // Backticks escape the name here as they do everywhere else:
                // ``await viewModel.`disableProtection`()`` reaches the same method.
                let pattern = Self.memberAccessPattern(for: primitive)
                guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
                let range = NSRange(code.startIndex..., in: code)
                if !expression.matches(in: code, range: range).isEmpty {
                    violations.append("\(relative) calls \(primitive)")
                }
            }
        }
        XCTAssertEqual(
            violations, [],
            """
            These methods belong to AppViewModel's implementation. Use its public entry points \
            instead of coupling an outside source to the concern files' internal helpers.
            """
        )
    }

    /// Outside source cannot take a live-state or persistence handle opened by the split.
    /// Two other controllers initialize same-named immutable defaults dependencies. Only those
    /// assignments are exempt: the compiler forbids assigning AppViewModel's lets outside its init.
    /// A self read is still checked, because Swift capture lists can rebind self to another model.
    static func escapingStateAccess(in code: String, property: String) throws -> Bool {
        let member = try NSRegularExpression(pattern: memberAccessPattern(for: property))
        let ownReceiver = try NSRegularExpression(pattern: identifierStart + #"self\s*$"#)
        let assignment = try NSRegularExpression(pattern: #"^\s*=(?!=)"#)
        return member.matches(in: code, range: NSRange(code.startIndex..., in: code)).contains { match in
            guard ["defaults", "appGroupDefaults"].contains(property) else { return true }
            let prefix = (code as NSString).substring(to: match.range.location)
            let suffix = (code as NSString).substring(from: NSMaxRange(match.range))
            return ownReceiver.firstMatch(in: prefix, range: NSRange(prefix.startIndex..., in: prefix)) == nil
                || assignment.firstMatch(in: suffix, range: NSRange(suffix.startIndex..., in: suffix)) == nil
        }
    }

    func testNoSourceOutsideTheClassReadsReferenceTypedState() throws {
        // Exclude the unrelated support types preceding AppViewModel and in its support file.
        let coreClass = try sourceBlock(in: readSource(.appViewModelCore), startingAt: "final class AppViewModel")
        let concerns = try SourceFile.appViewModelSources
            .filter { $0 != .appViewModelCore && $0 != .appViewModelSupport }
            .map(readSource).joined(separator: "\n")
        let classCode = sourceOutsideCommentsAndStrings(coreClass + "\n" + concerns)
        XCTAssertEqual(Set(Self.referenceStateThatMustNotEscape).count, Self.referenceStateThatMustNotEscape.count)
        for name in Self.referenceStateThatMustNotEscape {
            let declaration = #"(?m)^    (?:(?:lazy|static)\s+)*(?:let|var)\s+`?"# + name + "`?" + Self.identifierEnd
            XCTAssertNotNil(classCode.range(of: declaration, options: .regularExpression),
                            "Update the protected-handle inventory after renaming \(name).")
            XCTAssertTrue(try Self.escapingStateAccess(in: "let handle = viewModel.\(name)", property: name))
            XCTAssertFalse(try Self.escapingStateAccess(in: "let value = other.\(name)🦊", property: name))
        }
        for name in ["defaults", "appGroupDefaults"] {
            XCTAssertNotNil(classCode.range(of: "(?m)^    let " + name + Self.identifierEnd, options: .regularExpression),
                            "The initialization exception requires an immutable model dependency.")
        }
        XCTAssertFalse(try Self.escapingStateAccess(in: "self.defaults = defaults", property: "defaults"))
        XCTAssertTrue(try Self.escapingStateAccess(in: "{ [self = model] in self.defaults.set(true, forKey: key) }", property: "defaults"))
        XCTAssertTrue(try Self.escapingStateAccess(in: "self.defaults == defaults", property: "defaults"))
        XCTAssertTrue(try Self.escapingStateAccess(in: "self.viewModel.defaults.set(true, forKey: key)", property: "defaults"))
        XCTAssertTrue(try Self.escapingStateAccess(in: "viewModel.self.defaults", property: "defaults"))
        var violations: [String] = []
        let sources = try Self.appTargetSourcesOutsideTheClass()
        XCTAssertGreaterThan(sources.count, 50, "the walk found almost nothing — this pin is vacuous")
        for (relative, text) in sources {
            let code = sourceOutsideCommentsAndStrings(text)
            for property in Self.referenceStateThatMustNotEscape {
                guard code.contains(property) else { continue }
                if try Self.escapingStateAccess(in: code, property: property) {
                    violations.append("\(relative) reads \(property)")
                }
            }
        }
        XCTAssertEqual(
            violations, [],
            """
            A reference-typed property read from outside the class is a handle on live tunnel \
            state — the holder can stop the tunnel or rewrite the profile with the model none the \
            wiser. Route the operation through the model instead.
            """
        )
    }

    /// App orchestration uses named APIs instead of operator overloads. An operator can mutate
    /// an inout argument without spelling either & or = at the call site, so its definition is
    /// the reliable review boundary. No outside app-target file defines an operator today.
    static func definesOutsideOperator(in source: String) -> Bool {
        let code = sourceOutsideCommentsAndStrings(source)
        let expression = try! NSRegularExpression(pattern: Self.identifierStart + #"func\s+"# + operatorCharacterPattern + "+")
        return expression.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    /// Reserve `mutating` implementations for package value types. No outside app source uses
    /// the keyword today; keeping the whole family there avoids enumerating Swift accessor kinds.
    /// This is a conservative architecture boundary, including contextual uses of that name.
    static func declaresOutsideValueMutation(in source: String) -> Bool {
        let code = sourceOutsideCommentsAndStrings(source)
        let expression = try! NSRegularExpression(pattern: identifierStart + "mutating" + identifierEnd)
        return expression.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil
    }

    func testOutsideAppSourcesUseExplicitMutationAPIs() throws {
        let violations = try Self.appTargetSourcesOutsideTheClass().compactMap { path, text in
            Self.definesOutsideOperator(in: text) || Self.declaresOutsideValueMutation(in: text) ? path : nil
        }
        XCTAssertEqual(violations, [], "Use named model APIs; keep operator overloads and mutating value implementations in package types.")
        XCTAssertTrue(Self.declaresOutsideValueMutation(in:
            "extension DomainRuleSet { var resetCount: Int { mutating get { self = .init(); return 0 } } }"))
        XCTAssertTrue(Self.declaresOutsideValueMutation(in: "var value: Int { mutating /* note */ _read { yield count } }"))
        XCTAssertFalse(Self.declaresOutsideValueMutation(in: "var value: Int { get { count } }"))
        XCTAssertFalse(Self.declaresOutsideValueMutation(in: "func mutatingGetter() {} // mutating get"))
        XCTAssertTrue(Self.declaresOutsideValueMutation(in: "mutating func filter() { self = .init() }"))
        XCTAssertTrue(Self.declaresOutsideValueMutation(in: "mutating func filter🦊() {}"))
        XCTAssertTrue(Self.declaresOutsideValueMutation(in: "var value: Int { mutating unsafeAddress { pointer } }"))
        XCTAssertFalse(Self.declaresOutsideValueMutation(in: "func filter🦊() {}"))
        XCTAssertTrue(Self.definesOutsideOperator(in:
            "infix operator ⊕: AssignmentPrecedence\nfunc ⊕ (lhs: inout Int, rhs: Int) { lhs += rhs }"))
        XCTAssertTrue(Self.definesOutsideOperator(in:
            "func + (lhs: inout Int, rhs: Int) { lhs += rhs }"))
        XCTAssertFalse(Self.definesOutsideOperator(in: "func apply(_ value: inout Int) {}"))
    }

    /// The pin is worthless if a write form slips past it, so prove each one is CAUGHT. Every case
    /// is a real write the compiler would have refused before the split; the awkward ones were
    /// found by review, not by imagination (Codex, PR #652).
    func testThePredicateCatchesEveryWriteFormAndNoRead() {
        func isCaught(_ source: String) -> Bool { !Self.writeViolations(in: source).isEmpty }
        for source in Self.writeForms {
            XCTAssertTrue(isCaught(source), "the encapsulation pin does not see this write: \(source)")
        }
        // And it must not fire on a READ, or it would be unusable and get weakened away.
        for source in Self.readForms {
            XCTAssertFalse(isCaught(source), "the encapsulation pin misreads this read as a write: \(source)")
        }
    }

    /// Every listed name is still a stored property of the class, so a rename cannot quietly empty
    /// the list above and leave the pin passing over nothing.
    ///
    /// Scans the whole class, not just the core file: instance state lives there, but the mutable
    /// TYPE-level state sits in the concern that owns it (`isWarmPassInFlight` in +TunnelHealth).
    func testEveryWidenedSetterStillNamesAStoredPropertyOfTheClass() throws {
        let core = try readAppViewModelSource()
        for property in Self.internallySettableState {
            XCTAssertNotNil(
                core.range(of: "var \(property)" + Self.identifierEnd, options: .regularExpression),
                "\(property) is no longer declared in the AppViewModel class — update widenedSetters"
            )
        }
        XCTAssertFalse(Self.internallySettableState.isEmpty)
    }

    /// The declarations that KEPT `private(set)` must stay that way: only the core file writes them,
    /// so the split gives no reason to widen them.
    func testEveryPropertyThatKeptPrivateSetStillHasIt() throws {
        let core = try readSource(.appViewModelCore)
        for property in Self.keptPrivateSetters {
            XCTAssertNotNil(
                core.range(of: "private\\(set\\)[^\\n]*" + Self.identifierStart + property + Self.identifierEnd, options: .regularExpression),
                "\(property) lost its private setter; only the core file writes it, so it does not need one"
            )
        }
        XCTAssertEqual(
            sourceOccurrenceCount(of: "private(set)", in: core), Self.keptPrivateSetters.count,
            "the class has a private(set) declaration this suite does not account for"
        )
    }
}
