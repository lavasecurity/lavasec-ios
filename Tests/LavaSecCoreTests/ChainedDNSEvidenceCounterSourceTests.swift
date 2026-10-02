import XCTest

@testable import LavaSecCore

/// The decision-3 evidence counters (S9): the TC-answer and per-domain silent-timeout rates
/// the deferred TCP-retry enablement is gated on.
///
/// Pinned rather than executed because both halves live outside the SPM package —
/// `EnergyCounters` is compiled into the app/tunnel targets by pbxproj membership, and the
/// bump sites are in the provider. What the pins protect is the part a later edit would drop
/// silently: that the counters form rates at all (a numerator needs its denominator, in the
/// same window), that each rate's numerator is the population it claims to be, and that the
/// distinct-name tracking stays bounded and per-session.
final class ChainedDNSEvidenceCounterSourceTests: XCTestCase {
    func testTheFiveCountersExistInsideTheQAGate() throws {
        let source = try readSource(.appGroup)
        for counter in [
            "case chainedDNSResolution", "case chainedDNSTruncatedAnswer",
            "case chainedDNSTruncatedUnresolved", "case chainedDNSSilentTimeout",
            "case chainedDNSUnparseableTimeout",
        ] {
            XCTAssertTrue(source.contains(counter), "\(counter) is missing")
        }
        // Inside the gate that compiles the whole harness out of Release, like every other
        // counter — the plan's rule is that nothing here ships in a production build.
        let gate = try XCTUnwrap(source.range(of: "#if DEBUG || LAVA_QA_TOOLS\nenum EnergyCounter"))
        let chained = try XCTUnwrap(source.range(of: "case chainedDNSResolution"))
        XCTAssertLessThan(gate.lowerBound, chained.lowerBound)
    }

    func testTheDistinctNameTrackingIsBoundedAndNameless() throws {
        let source = try readSource(.appGroup)
        // BOUNDED: the driver caps its own distinct-name set at 2 because an unbounded one
        // is a memory surface a chosen-traffic attacker fills for free (INV-MEM-1). This
        // set answers a different question and so needs more slots, but it needs the same
        // ceiling — a saturating insert, never an unbounded Set.
        XCTAssertTrue(source.contains("private static let chainedDNSDistinctNameSlots = 8"))
        XCTAssertTrue(
            source.contains(
                "if chainedDNSSilentTimeoutNameKeys.count < Self.chainedDNSDistinctNameSlots {"),
            "the distinct-name set must saturate rather than grow")
        // NAMELESS: the caller passes the driver's opaque key, so no queried domain is ever
        // held or emitted — the debug-log privacy audit holds by construction.
        XCTAssertTrue(source.contains("case named(nameKey: UInt64)"))
        // And it is cleared with the WINDOW, or one busy minute would poison every later
        // one. SCOPED TO `flushIfDue` deliberately: this was a bare file-wide `contains`,
        // which the per-session reset added beside it silently disarmed — two byte-identical
        // lines, so deleting the per-window clear still matched the `activate()` copy and
        // the suite stayed green while a saturated set was reported in every later window
        // for the life of the session. A fix that disables an existing pin is a regression
        // in the pin, found by the pre-push panel and confirmed by deleting the flush-side
        // clear and watching the suite pass.
        let flush = try sourceBlock(
            in: source,
            startingAt: "func flushIfDue(now: Date = Date()) {",
            endingBefore: "// The QA-only `EnergySignpost` helper")
        XCTAssertTrue(
            flush.contains("chainedDNSSilentTimeoutNameKeys.removeAll(keepingCapacity: true)"),
            "the distinct-name set must be cleared with the window it describes")
        // Both resets, and no third: an extra copy elsewhere would re-open the same hole by
        // making either scoped assertion satisfiable by the wrong line.
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "chainedDNSSilentTimeoutNameKeys.removeAll(keepingCapacity: true)",
                in: source),
            2, "expected exactly the per-session and per-window resets")
    }

    func testTheDistinctNameSetIsResetPerSession() throws {
        let source = try readSource(.appGroup)
        let activate = try sourceBlock(
            in: source, startingAt: "func activate() {", endingBefore: "func recordSQLiteWindow")
        // `activate()` exists to isolate each tunnel session's measurement, and it resets
        // every other per-session field. This set was added without it, so a stop/start
        // inside one un-killed extension process carried the previous session's names into
        // the next session's first window — where a single new timeout could be reported
        // against an already-saturated set, the ceiling read as a measurement (Codex, Kilo).
        XCTAssertTrue(
            activate.contains("chainedDNSSilentTimeoutNameKeys.removeAll(keepingCapacity: true)"),
            "the distinct-name set must be reset per session like every count beside it")
    }

    func testEveryTermOfOneResolutionMovesUnderOneLock() throws {
        let source = try readSource(.appGroup)
        let record = try sourceBlock(
            in: source,
            startingAt: "func recordChainedDNSResolution(",
            endingBefore: "func recordDoQHandshake")
        // ONE LOCK ACROSS ALL TERMS is what makes a rate computable: a flush landing
        // between two separate record calls splits one resolution's denominator from its
        // numerator across two `nrg-counters` lines, which is the same defect as counting
        // the denominator at entry, only narrower.
        let denominator = try XCTUnwrap(
            record.range(of: "counts[.chainedDNSResolution, default: 0] += 1"))
        let truncated = try XCTUnwrap(
            record.range(of: "counts[.chainedDNSTruncatedAnswer, default: 0] += 1"))
        let timeout = try XCTUnwrap(
            record.range(of: "counts[.chainedDNSSilentTimeout, default: 0] += 1"))
        let insert = try XCTUnwrap(
            record.range(of: "chainedDNSSilentTimeoutNameKeys.insert(nameKey)"))
        let unlock = try XCTUnwrap(record.range(of: "lock.unlock()"))
        for (name, term) in [
            ("denominator", denominator), ("truncation", truncated), ("timeout", timeout),
            ("distinct name", insert),
        ] {
            XCTAssertLessThan(
                term.lowerBound, unlock.lowerBound,
                "the \(name) term must be recorded before the lock is released")
        }
    }

    func testTheUnresolvedTruncationIsCountedInsideTheTruncatedPopulation() throws {
        let source = try readSource(.appGroup)
        let record = try sourceBlock(
            in: source,
            startingAt: "func recordChainedDNSResolution(",
            endingBefore: "func recordDoQHandshake")
        // `chainedDNSTruncatedUnresolved` is a SUBSET of `chainedDNSTruncatedAnswer`, and
        // the subset relationship has to be structural: if the unresolved branch stopped
        // bumping the outer counter, a reader adding the two together would double-count
        // the same resolution and one that subtracted them would get the rescued count
        // wrong in the other direction.
        let unresolvedBranch = try sourceBlock(
            in: record, startingAt: "case .unresolved:", endingBefore: "switch timeout {")
        XCTAssertTrue(
            unresolvedBranch.contains("counts[.chainedDNSTruncatedAnswer, default: 0] += 1"),
            "an unresolved truncation must also count in the population it is a subset of")
        XCTAssertTrue(
            unresolvedBranch.contains("counts[.chainedDNSTruncatedUnresolved, default: 0] += 1"))
    }

    /// The reply-shape counters (PR #588), under the same QA gate as the rest of the harness.
    func testTheEmptyAnswerCountersExistInsideTheQAGate() throws {
        let source = try readSource(.appGroup)
        for counter in ["case chainedDNSEmptyAnswer", "case chainedDNSUnbackedEmptyAnswer"] {
            XCTAssertTrue(source.contains(counter), "\(counter) is missing")
        }
        let gate = try XCTUnwrap(source.range(of: "#if DEBUG || LAVA_QA_TOOLS\nenum EnergyCounter"))
        let empty = try XCTUnwrap(source.range(of: "case chainedDNSEmptyAnswer"))
        XCTAssertLessThan(gate.lowerBound, empty.lowerBound)
    }

    /// `chainedDNSUnbackedEmptyAnswer` is a SUBSET of `chainedDNSEmptyAnswer`, and the subset
    /// relationship has to be structural for the same reason the truncation one does: a reader
    /// adding the two would double-count one resolution, and one subtracting them would get the
    /// ordinary-NODATA count wrong in the other direction. The unbacked count is the signal here,
    /// so the containment is what keeps the backed count readable beside it.
    func testTheUnbackedEmptyAnswerIsCountedInsideTheEmptyAnswerPopulation() throws {
        let source = try readSource(.appGroup)
        let record = try sourceBlock(
            in: source,
            startingAt: "func recordChainedDNSResolution(",
            endingBefore: "func recordDoQHandshake")
        let unbackedBranch = try sourceBlock(
            in: record, startingAt: "case .unbacked:", endingBefore: "switch truncation {")
        XCTAssertTrue(
            unbackedBranch.contains("counts[.chainedDNSEmptyAnswer, default: 0] += 1"),
            "an unbacked empty answer must also count in the population it is a subset of")
        XCTAssertTrue(
            unbackedBranch.contains("counts[.chainedDNSUnbackedEmptyAnswer, default: 0] += 1"))
    }

    /// The shape term comes from the RESOLUTION's verdict, not from a provider-side re-read of
    /// the response bytes — the RFC 2308 §2.2 split needs the wire message and lives where it has
    /// executable tests (`TunnelledPlainDNSResolutionTests`), exactly like the rescue decision.
    func testTheEmptyAnswerTermComesFromTheVerdict() throws {
        let provider = try readPacketTunnelProviderSource()
        let executor = try sourceBlock(
            in: provider,
            startingAt: "func resolveTunnelledPlainDNS(",
            endingBefore: "/// Submits a tunnel-DNS observation")
        XCTAssertTrue(
            executor.contains("verdict.sawUnbackedEmptyAnswer"),
            "the unbacked term must be the resolution's own decision")
        XCTAssertTrue(executor.contains("verdict.sawEmptyAnswer"))
        // ...and it travels through the SAME lifecycle-gated seam as every other term, so a
        // torn-down lifecycle's in-flight resolution cannot move it into the next session's window.
        let seam = try XCTUnwrap(executor.range(of: "recordChainedDNSEvidence("))
        let term = try XCTUnwrap(executor.range(of: "emptyAnswer: verdict.sawUnbackedEmptyAnswer"))
        XCTAssertLessThan(seam.lowerBound, term.lowerBound)
    }

    func testAnUnparseableTimeoutStaysOutOfThePerDomainRate() throws {
        let source = try readSource(.appGroup)
        let record = try sourceBlock(
            in: source,
            startingAt: "func recordChainedDNSResolution(",
            endingBefore: "func recordDoQHandshake")
        let unparseable = try sourceBlock(
            in: record, startingAt: "case .unparseableQuery:", endingBefore: "lock.unlock()")
        // Its own counter, and NEITHER the per-domain count nor a distinct-name slot.
        // Folding these into a shared key (the first shape of this code used key 0) builds
        // exactly the many-timeouts-on-one-name signature the measurement exists to detect,
        // so a burst of malformed packets would read as the fragmenting-domain trap (Codex).
        XCTAssertTrue(
            unparseable.contains("counts[.chainedDNSUnparseableTimeout, default: 0] += 1"))
        XCTAssertFalse(
            unparseable.contains("chainedDNSSilentTimeout,"),
            "an unparseable query must not enter the per-domain timeout count")
        XCTAssertFalse(
            unparseable.contains("chainedDNSSilentTimeoutNameKeys"),
            "an unparseable query has no name and must not consume a distinct-name slot")
    }

    func testEveryExitRecordsItsOwnResolutionAndNothingCountsAtEntry() throws {
        let provider = try readPacketTunnelProviderSource()
        let executor = try sourceBlock(
            in: provider,
            startingAt: "func resolveTunnelledPlainDNS(",
            endingBefore: "/// Submits a tunnel-DNS observation")

        // NOTHING AT ENTRY. The denominator used to be bumped on the way in, which put it
        // in the flush window the resolution STARTED in while its outcome landed in the
        // window it FINISHED in — a failover loop spending a UDP timeout per silent
        // resolver crosses a 60 s boundary readily, so a window could report a numerator
        // larger than its own denominator (Codex P1). The denominator now moves only
        // through the recorder, which carries the outcome with it.
        XCTAssertFalse(
            executor.contains("bump(.chainedDNSResolution)"),
            "the denominator must not be counted separately from the outcome it belongs to")

        // NOTHING RECORDS UNVALIDATED. Both exits go through the provider's own
        // `recordChainedDNSEvidence`, which checks the route's tokens and records in one
        // section; a direct `EnergyCounters` call here would record the terms of a
        // lifecycle that has already ended into the window `activate()` just reset for the
        // next one (Codex, PR #520).
        XCTAssertFalse(
            executor.contains("EnergyCounters.shared.recordChainedDNSResolution("),
            "the executor must record through the token-validated seam, not the counters directly")

        // EXACTLY TWO RECORDING CALLS — one per exit, no third.
        //
        // Forbidding only the OLD SPELLING was not the property. The first version of this
        // test asserted no `bump(.chainedDNSResolution)` and then checked ordering with
        // `range(of:)`, which returns the FIRST match — so restoring the entry count in the
        // NEW spelling passed every assertion while counting each wire resolution twice and
        // straddling the window all over again. Placement pins that never count occurrences
        // are the same weakness that let round 1's pin survive its own mutation; the
        // pre-push panel found this one, and deleting the exit-1 call to re-add it at the
        // top was confirmed green before this assertion existed.
        XCTAssertEqual(
            sourceOccurrenceCount(of: "recordChainedDNSEvidence(", in: executor),
            2, "each of the two exits records exactly once — no entry count, no duplicate")

        // ...and the first of them sits BELOW the backoff consult, which is what actually
        // forbids the entry placement: pinned from both sides (after the route is derived,
        // before the all-backed-off return) the only legal home is the refusal branch.
        let addressComputation = try XCTUnwrap(
            executor.range(of: "let addressesForAttempt = orderedResolverAddressesForAttempt("))
        let firstRecord = try XCTUnwrap(executor.range(of: "recordChainedDNSEvidence("))
        XCTAssertGreaterThan(
            firstRecord.lowerBound, addressComputation.lowerBound,
            "a resolution counted before the route is derived is the entry count again")

        // EXIT 1 — refused before the wire. Still a resolution the carry was asked for, so
        // it belongs in the denominator; no wire traffic, so no outcome terms. It must be
        // recorded BEFORE the return, which is the only thing that makes this exit counted
        // at all.
        let refusalRecord = try XCTUnwrap(
            executor.range(of: "truncation: .notSeen, timeout: nil,"))
        let earlyReturn = try XCTUnwrap(
            executor.range(
                of: "ResolverAttempt(address: $0, outcome: .backedOff, transport: .plainDNS)"))
        XCTAssertLessThan(
            refusalRecord.lowerBound, earlyReturn.lowerBound,
            "a fully suppressed route must be counted before it returns, or it drops out of "
                + "the population the rate is about")

        // EXIT 2 — reached the wire, so its terms come from the verdict, and there is
        // exactly ONE recording call for them.
        let wireRecord = try XCTUnwrap(
            executor.range(of: "truncation: truncation, timeout: timeout,"))
        XCTAssertLessThan(earlyReturn.lowerBound, wireRecord.lowerBound)

        // ...and it is derived and recorded before the observation is reported, so the
        // terms come from the verdict this resolution actually produced.
        let report = try XCTUnwrap(executor.range(of: "switch verdict.observation {"))
        XCTAssertLessThan(wireRecord.lowerBound, report.lowerBound)
    }

    /// The tunnelled T0 executor records NO T1 terms, because it never sees the rung.
    ///
    /// It used to carry `fallbackRescue`/`fallbackAttempted`/`fallbackAnswered` off the verdict,
    /// which derived them from the route's T1 subset. The rung egresses on the physical
    /// interface (PR #590), so those terms were permanently false and the subset itself is
    /// deleted (the plan's S3) — the rung reports its own through
    /// `recordChainedTierOneRungEvidence`, pinned below.
    ///
    /// The property PR #575 established survives the deletion and is what this still guards: the
    /// provider must never re-derive tier membership itself, because a raw membership test counts
    /// an all-SERVFAIL soft failure and a conf/fallback overlap address as rescues (Codex, Kilo).
    func testTheTunnelledExecutorRecordsNoTierOneTerms() throws {
        let provider = try readPacketTunnelProviderSource()
        let executor = try sourceBlock(
            in: provider,
            startingAt: "func resolveTunnelledPlainDNS(",
            endingBefore: "/// Submits a tunnel-DNS observation")
        for term in ["fallbackRescue:", "fallbackAttempted:", "fallbackAnswered:"] {
            XCTAssertFalse(
                executor.contains(term),
                "\(term) describes a T1 this executor never carries")
        }
        XCTAssertFalse(
            executor.contains("verdict.failedOver"),
            "rescue must not be derived from the failover framing")
        XCTAssertFalse(
            executor.contains("route.fallbackResolverAddresses"),
            "the provider must not re-derive membership (misses the real-answer + effective-set rules)")
        let route = try sourceBlock(
            in: provider,
            startingAt: "func currentTunnelledPlainDNSRoute()",
            endingBefore: "func chainedTunnelledDNSSurvivesPhysicalPathChange()")
        XCTAssertFalse(
            route.contains("fallbackResolverAddresses"),
            "the tunnelled route carries T0 only; the rung is on the physical interface")
    }

    /// The evidence seam validates the route's tokens and records in ONE section.
    ///
    /// A validating read that RETURNS "the tokens are current" and records afterwards
    /// leaves a gap the lifecycle can end inside — the same shape that was a P1 on the
    /// observation report (PR #518), here costing a contaminated measurement rather than
    /// safety. The check must therefore be *inside* the closure that records, and the
    /// counters must not be reachable from that function by any other route.
    func testTheEvidenceRecordIsValidatedAndRecordedInOneSection() throws {
        let provider = try readPacketTunnelProviderSource()
        let seam = try sourceBlock(
            in: provider,
            startingAt: "private func recordChainedDNSEvidence(",
            endingBefore: "func orderedResolverAddressesForAttempt")
        // All three token conditions, not a subset: an epoch alone does not say the
        // lifecycle is still running, and a generation alone does not say the latch is the
        // one the route was derived under.
        for condition in [
            "self.tunnelLifecycleIsActive", "generation == self.tunnelLifecycleGeneration",
            "latchEpoch == self.tunnelDataPathLatchEpoch",
        ] {
            XCTAssertTrue(seam.contains(condition), "\(condition) is missing from the guard")
        }
        // The guard and the record are the same closure — the record must come after the
        // guard's `else { return }` and before the closure ends, never as a returned verdict.
        let guardEnd = try XCTUnwrap(seam.range(of: "else { return }"))
        let record = try XCTUnwrap(
            seam.range(of: "EnergyCounters.shared.recordChainedDNSResolution("))
        XCTAssertLessThan(
            guardEnd.lowerBound, record.lowerBound,
            "the tokens must be validated before the terms are recorded, in one section")
        XCTAssertFalse(
            seam.contains("-> Bool"),
            "the seam must record inside the check, never return whether it may")
        // Dual-entry, like every other dnsStateQueue door in this file: a `sync` from code
        // already on the queue would deadlock (INV-QUEUE-1).
        XCTAssertTrue(seam.contains("DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey) == true"))
        XCTAssertTrue(seam.contains("dnsStateQueue.sync(execute: record)"))
    }

    func testTruncationIsSplitByWhetherTheResolutionCompleted() throws {
        let provider = try readPacketTunnelProviderSource()
        let executor = try sourceBlock(
            in: provider,
            startingAt: "func resolveTunnelledPlainDNS(",
            endingBefore: "/// Submits a tunnel-DNS observation")
        // `udpTruncated` is `sawTruncation` across the WHOLE failover loop, so it stays
        // true when a later resolver returns a complete response — that resolution
        // resolved, and no TCP retry would have helped it. Deriving the split from the
        // response is what keeps the retry gate from being inflated by however well
        // failover is already working (Codex P2). The response is the distinction; the
        // observation cannot supply it, because a TC answer classifies `.answered`.
        XCTAssertTrue(
            executor.contains(
                "truncation = verdict.result.response == nil ? .unresolved : .rescuedByFailover"),
            "a truncation rescued by a later resolver must not count toward the retry gate")
        XCTAssertTrue(
            executor.contains("if verdict.result.udpTruncated {"),
            "the truncation term must be read from the result, not the observation")
    }

    /// The silent-timeout term is derived from the RESULT, never from the observation.
    ///
    /// The observation is a liveness verdict — a TC answer paired with another resolver's
    /// silence classifies `.answered` on purpose, so the outage budget is not spent on one
    /// large-response domain. Reading silence off it inherits that rule, and the
    /// TC-plus-timeout resolution recorded no timeout at all despite a resolver going quiet
    /// and nothing resolving (Codex, PR #520).
    ///
    /// This pin REPLACES one that asserted the opposite. Last round I argued the observation
    /// was the right source and pinned that; the argument was wrong in a way this shape makes
    /// obvious, and the same reasoning was already written down one screen up for truncation.
    func testTheSilentTimeoutTermIsDerivedFromTheResultNotTheObservation() throws {
        let provider = try readPacketTunnelProviderSource()
        let executor = try sourceBlock(
            in: provider,
            startingAt: "func resolveTunnelledPlainDNS(",
            endingBefore: "/// Submits a tunnel-DNS observation")
        // Did not complete AND a resolver's budget elapsed — both halves, or a timeout
        // rescued by a later resolver would count as a silent domain.
        XCTAssertTrue(
            executor.contains("if verdict.result.response == nil,"),
            "a resolution that completed is not a silent timeout")
        XCTAssertTrue(
            executor.contains(
                "verdict.result.attempts.contains(where: { $0.outcome == .timeout })"),
            "an all-local-failure resolution never had a resolver go quiet")
        // And the name comes from the verdict's own field rather than the observation's
        // payload, which only exists on the `.unanswered` classification.
        XCTAssertTrue(executor.contains("if let name = verdict.unresolvedQueryName {"))
        XCTAssertFalse(
            executor.contains("if case .unanswered(let name) = verdict.observation {"),
            "deriving the timeout term from the liveness verdict is the defect this replaced")
    }

    func testTheFlushEmitsTheDistinctNameFigureOnlyWhenThereWereTimeouts() throws {
        let source = try readSource(.appGroup)
        XCTAssertTrue(source.contains("details[\"chainedDNSSilentTimeoutNames\"]"))
        // Saturation is reported, not hidden: a capped window means "at least this many",
        // and a reader that could not tell would mistake the ceiling for a measurement.
        XCTAssertTrue(source.contains("details[\"chainedDNSSilentTimeoutNamesSaturated\"]"))
        // Emitted only when the window saw timeouts — a zero in a quiet window reads like a
        // measurement of something rather than the absence of anything to measure.
        XCTAssertTrue(
            source.contains("if snapshot[.chainedDNSSilentTimeout, default: 0] > 0 {"))
    }
    /// `Shared/AppGroup.swift` is outside the package, so nothing here compiles the writer — only
    /// a pin can keep the raw log's sub-second display precision from silently regressing.
    func testTheDeviceLogKeepsMillisecondDisplayTimestamps() throws {
        let source = try readSource(.appGroup)

        // The monotonic observation token orders reports; this wall stamp remains millisecond
        // precise so a person reading the unsanitized local log can see brief stalls and backlog.
        XCTAssertTrue(source.contains("[.withInternetDateTime, .withFractionalSeconds]"))
        XCTAssertTrue(source.contains("timestampFormatter.string(from: observation.observedAt)"))
        // NOT the shared default-configured instance, which emits whole seconds.
        XCTAssertFalse(
            source.contains("SharedDateFormatting.iso8601.string(from: observation.observedAt)"))
    }

    func testTheDeviceLogWritesObservationOrderAsStructuralMetadata() throws {
        let append = try sourceBlock(
            in: try readSource(.appGroup),
            startingAt: "static func append(",
            endingBefore: "private static func appendLine")

        // Production mutations caught: putting observationOrder in caller details makes it
        // privacy-allowlist data (and eligible for `_withheld` accounting), while stamping Date()
        // here records the drain instead of the observation paired with the monotonic token.
        XCTAssertTrue(
            append.contains("observation: DeviceLogObservation = DeviceLogObservationClock.capture()"))
        XCTAssertTrue(
            append.contains("timestampFormatter.string(from: observation.observedAt)"))
        XCTAssertTrue(
            append.contains("payload[\"observationOrder\"] = observation.order?.serialized"),
            "the raw ordering token must be an optional top-level structural string")
        XCTAssertFalse(
            append.contains("details[\"observationOrder\"]"),
            "observationOrder is not an allowlisted detail and must not count as withheld detail")
    }

    /// ONE copy of the fallback-counter rules, shared by both evidence sources.
    ///
    /// T0's verdict and the physical T1 rung now both move `chainedFallbackAttemptCount`
    /// and its siblings. Two copies of the served ⊆ answered ⊆ attempted nesting would let the
    /// panel mean different things depending on which tier moved the counter, and the streaks —
    /// the only terms that can FALL — are where that divergence would be invisible.
    func testBothEvidenceSourcesShareOneFallbackCounterBlock() throws {
        let provider = try readPacketTunnelProviderSource()
        let shared = try sourceBlock(
            in: provider,
            startingAt: "private func applyChainedFallbackEvidenceOnQueue(",
            endingBefore: "/// Records a physical T1 rung")
        for term in [
            "self.health.chainedFallbackAttemptCount += 1",
            "self.health.chainedFallbackAnswerCount += 1",
            "self.health.chainedFallbackRescueCount += 1",
            "self.health.chainedFallbackUnansweredStreak += 1",
            "self.health.chainedFallbackUnhelpfulReplyStreak += 1"
        ] {
            XCTAssertTrue(shared.contains(term), "\(term) must live in the shared block")
            XCTAssertEqual(
                provider.components(separatedBy: term).count - 1, 1,
                "\(term) must appear exactly once — a second copy is a counter that can drift")
        }
    }

    /// The physical rung moves the fallback counters, under the same lifecycle guard as T0.
    ///
    /// This is the ONLY counter path for T1. The tunnelled route carries no T1 addresses
    /// and its verdict no longer carries T1 terms at all, so without this recorder every
    /// rung — rescues included — leaves the panel on "Ready — not needed yet" and the field
    /// telemetry at zero (Codex, PR #590).
    func testThePhysicalRungMovesTheFallbackCounters() throws {
        let recorder = try sourceBlock(
            in: try readPacketTunnelProviderSource(),
            startingAt: "func recordChainedTierOneRungEvidence(",
            endingBefore: "#endif")
        XCTAssertTrue(
            recorder.contains("applyChainedFallbackEvidenceOnQueue("),
            "the rung must move the SAME counters T0 does, not a parallel set")
        // The nesting, supplied rather than assumed: `notForwarded` is attempts-without-answers
        // and `answeringWithoutResolving` is answers-without-rescues, so all three terms matter.
        XCTAssertTrue(recorder.contains("attempted: true"))
        XCTAssertTrue(recorder.contains("rescue: outcome == .served"))
        XCTAssertTrue(
            recorder.contains("outcome == .answered || outcome == .served"),
            "served must nest inside answered, or a rescue would clear no streak")
        // THE CARRIED TOKENS, not a fresh read. Re-deriving the route at completion produces the
        // CURRENT session's tokens and compares them against the current session, so the guard
        // can never reject — and a rung from an ended session credits the live one (Codex, PR #590).
        XCTAssertTrue(
            recorder.contains("evidence.originatingLifecycle == self.tunnelLifecycleGeneration"))
        XCTAssertTrue(
            recorder.contains("evidence.originatingLatchEpoch == self.tunnelDataPathLatchEpoch"))
        XCTAssertFalse(
            recorder.contains("currentTunnelledPlainDNSRoute()"),
            "re-deriving the route here is a guard that compares the live session with itself")
        // INV-QUEUE-1: reached from resolver queues, so it cannot bare-`sync`.
        XCTAssertTrue(recorder.contains("DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey)"))
    }

    /// BOTH orchestrator entry points record the rung, because both can produce one.
    ///
    /// The forwarding path and the smoke probe each return their own merged result. Wiring only
    /// one would make the counters describe a subset of the rungs that actually ran, which is the
    /// same class of under-count as not recording them at all — harder to spot, because the
    /// numbers move.
    func testBothOrchestratorEntryPointsRecordTheRung() throws {
        let provider = try readPacketTunnelProviderSource()
        XCTAssertEqual(
            provider.components(separatedBy: "self?.recordTierOneRungIfPresent(").count - 1, 2,
            "resolveUpstream and resolvePrimaryUpstream must both record")
        let gate = try sourceBlock(
            in: provider,
            startingAt: "private func recordTierOneRungIfPresent(",
            endingBefore: "func resolverLatchIsCurrent(")
        XCTAssertTrue(
            gate.contains("guard let evidence = result.tierOneRung else { return }"),
            "a resolution with no rung must cost nothing — the latch read is not on the common path")
    }

    /// The FORWARDING credit is taken past `completeForward`'s delivery gate, not before it.
    ///
    /// That guard is the only place that knows this answer reaches the client rather than being
    /// discarded, and the credit's whole claim is that the USER got an answer. Crediting earlier
    /// counted results the guard then threw away; re-checking the runtime earlier still raced it,
    /// because the check and `completeForward` are two separate hops onto the same queue
    /// (Codex P2, PR #639, twice).
    func testTheForwardingCreditWaitsForTheDeliveryGate() throws {
        let provider = try readPacketTunnelProviderSource()
        let forward = try sourceBlock(
            in: provider,
            startingAt: "func completeForward(",
            endingBefore: "let upstreamResponse = result.response")
        let gate = try XCTUnwrap(
            forward.range(of: "guard isActiveResolverRuntime("),
            "the delivery gate must still be the first thing this function decides")
        let credit = try XCTUnwrap(
            forward.range(of: "reportTierOneRungRescue("),
            "the forwarding path must credit the rung here — its record site defers to this")
        XCTAssertLessThan(
            gate.lowerBound, credit.lowerBound,
            "the credit must come AFTER the guard, or it counts answers the client never gets")
        XCTAssertTrue(
            forward.contains("if let rung = result.tierOneRung, rung.ladderServed {"),
            "and only for a rung that served, on the ladder's own client-servable verdict")
        // The forwarding path and probe state which shape they are, so a new one cannot default into
        // crediting before a gate it does not know about.
        XCTAssertEqual(
            provider.components(separatedBy: "rungCreditTiming: .deferredToDelivery").count - 1, 1,
            "all valid client queries share completeForward's delivery gate")
        XCTAssertEqual(
            provider.components(separatedBy: "rungCreditTiming: .noClient(").count - 1, 1,
            "and exactly one has no client at all: the smoke probe, fenced on the runtime")
    }

    func testTruncatedHeadersCannotStartAnUntrackedResolution() throws {
        let provider = try readPacketTunnelProviderSource()
        let rejection = try sourceBlock(in: provider,
            startingAt: "guard let cacheKey = DNSCacheKey(",
            endingBefore: "let lifetime = DNSResolutionLifetime")
        XCTAssertTrue(rejection.contains("truncated-dns-header"))
        XCTAssertTrue(rejection.contains("return"))
        XCTAssertFalse(rejection.contains("resolveUpstream("))
        XCTAssertFalse(rejection.contains("runBoundedResolverWork("))
    }

    /// A SERVED rung credits the outage driver, in EVERY build, along an unbroken chain.
    ///
    /// The tunnel-DNS cause's only disarming observation was a served answer from T0, so a
    /// split-tunnel upstream whose `DNS =` answers its own namespace and drops the rest held the
    /// outage open to the budget and surrendered a session whose DNS the rung was serving
    /// (field 2026-09-01; `ChainedOutageDriver.reportTierOneRungRescue`).
    ///
    /// ASSERTED AS A CHAIN, not as two ends. A pin that checks the rung is fetched and separately
    /// that the driver is called says nothing about the middle — which is exactly how PR #636's
    /// mis-scoped self-assignment reached `main` behind two green pins. So the ORDER and the
    /// SCOPE are asserted here: the fetch precedes the QA gate, the credit follows `#endif`, and
    /// the tokens the credit validates are the ones the fetch carried.
    func testAServedRungCreditsTheOutageDriverInEveryBuild() throws {
        let provider = try readPacketTunnelProviderSource()
        let gate = try sourceBlock(
            in: provider,
            startingAt: "private func recordTierOneRungIfPresent(",
            endingBefore: "func resolverLatchIsCurrent(")

        // LINK 1: the rung is fetched BEFORE the QA gate. Leaving the fetch inside it puts the
        // credit inside it too, which ships the defect to every user and fixes it only for us.
        let fetch = try XCTUnwrap(
            gate.range(of: "guard let evidence = result.tierOneRung else { return }"))
        let qaGate = try XCTUnwrap(gate.range(of: "#if DEBUG || LAVA_QA_TOOLS"))
        let qaEnd = try XCTUnwrap(gate.range(of: "#endif"))
        XCTAssertLessThan(fetch.lowerBound, qaGate.lowerBound)
        XCTAssertLessThan(qaGate.lowerBound, qaEnd.lowerBound)

        // LINK 2: the credit is gated on the LADDER's verdict and sits OUTSIDE the QA gate — a
        // Release build must take it.
        //
        // `ladderServed`, never `outcome == .served`: `outcome` is the SELECTION's verdict, so
        // gating on it withholds the credit from a user whose T1 was dark and whose own
        // configured T2 answered — surrendering chaining on behalf of someone who was never
        // blackholed, which is the opposite of what enabling that fallback asked for.
        XCTAssertFalse(
            gate.contains("evidence.outcome == .served"),
            "the credit must not read the selection's verdict — a T2 rescue is still an answer")
        let served = try XCTUnwrap(
            gate.range(of: "guard evidence.ladderServed else { return }"),
            "the credit arm must read the ladder's own client-servable verdict")
        XCTAssertLessThan(
            qaEnd.lowerBound, served.lowerBound,
            "the outage credit is inside `#if DEBUG || LAVA_QA_TOOLS` — Release keeps the defect")

        // LINK 3: the credit carries the EVIDENCE's tokens into the report, not a fresh read —
        // asserted on the ARM between the `.served` test and the reporter's own declaration, so
        // a call that dropped them could not pass by matching text elsewhere in the block.
        let reporterDeclaration = try XCTUnwrap(
            gate.range(of: "func reportTierOneRungRescue("))
        let creditArm = gate[served.lowerBound..<reporterDeclaration.lowerBound]
        XCTAssertLessThan(served.lowerBound, reporterDeclaration.lowerBound)
        for term in [
            "reportTierOneRungRescue(",
            "forLifecycle: evidence.originatingLifecycle",
            "latchEpoch: evidence.originatingLatchEpoch"
        ] {
            XCTAssertTrue(
                creditArm.contains(term),
                "\(term) is missing from the credit arm — a rung from an ended session would "
                    + "disarm the LIVE session's cause")
        }

        // LINK 4: the reporter validates those tokens and submits the report in ONE section, the
        // same shape `reportTunnelDNSObservation` carries — a read that returns "current" and
        // reports afterwards leaves a gap the lifecycle can end inside (P1, PR #518).
        let reporter = try sourceBlock(
            in: gate, startingAt: "func reportTierOneRungRescue(")
        let submit = try XCTUnwrap(reporter.range(of: "let submit = {"))
        for term in [
            "generation == self.tunnelLifecycleGeneration",
            "latchEpoch == self.tunnelDataPathLatchEpoch",
            "self.tunnelLifecycleIsActive",
            "driver.reportTierOneRungRescue()"
        ] {
            let found = try XCTUnwrap(
                reporter.range(of: term), "\(term) is missing — the chain is broken at the door")
            XCTAssertLessThan(
                submit.lowerBound, found.lowerBound,
                "\(term) must be INSIDE the single validated section, not before it")
        }
        XCTAssertFalse(
            reporter.contains("currentTunnelledPlainDNSRoute()"),
            "a fresh route read compares the live session with itself and can never reject (PR #590)")

        // LINK 5: WHEN the credit may be taken is the caller's to state, and both callers are
        // handled explicitly. `resolverRuntimeGeneration` advances on a protection-policy change
        // or a device-DNS recapture without touching either lifecycle token, so the pair above
        // cannot stand in for it — and the callers answer that differently (Codex P2,
        // PR #639, three rounds). The switch is exhaustive, so a new path must decide rather than
        // inherit whichever rule happens to be first.
        for arm in [
            "case .deferredToDelivery:",
            "case .noClient(let admittedAtRuntimeGeneration):"
        ] {
            XCTAssertTrue(
                gate.contains(arm), "\(arm) is missing — a path would inherit another's rule")
        }
        // Neither forwarding nor probes may bypass their delivery/evidence gate.
        XCTAssertFalse(
            provider.contains("deliveredUnconditionally"),
            "a credit-immediately arm returned — show the path has no delivery gate first")
        XCTAssertTrue(
            gate.contains("currentResolverRuntimeGeneration() == admittedAtRuntimeGeneration"),
            "the clientless path must fence on the runtime it was admitted under, or a probe "
                + "that outlived a reset clears failures the NEW runtime accumulated")
        // AND THE REPORTER DOES NOT RE-CHECK THE RUNTIME, deliberately. An earlier shape did, and
        // it still left a gap: that check runs a `dnsStateQueue.sync` while `completeForward` is
        // enqueued onto the same queue afterwards, so a reset landing between them passed there
        // and failed here. Deferring to the guard that decides delivery is what makes the claim
        // structural instead of a timing argument.
        XCTAssertFalse(
            reporter.contains("isActiveResolverRuntime"),
            "re-checking the runtime before the delivery gate is a race, not a guard")
        // INV-QUEUE-1: reached from `resolverQueue` and the smoke-probe queue, so it cannot
        // bare-`sync` — the specific-key re-entrancy check is load-bearing, not decorative.
        XCTAssertTrue(reporter.contains("DispatchQueue.getSpecific(key: dnsStateQueueSpecificKey)"))
    }
}
