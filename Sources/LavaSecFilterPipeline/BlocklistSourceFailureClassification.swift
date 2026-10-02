import Foundation

/// Whether a blocklist source's failure is worth retrying, or whether the source is simply
/// unusable until something outside the device changes.
///
/// WHY THE DISTINCTION HAS TO EXIST. A snapshot prepare is all-or-nothing: one enabled source
/// that cannot be fetched throws the whole compile away, so the artifact is never rewritten,
/// `coversEnabledBlocklists` never holds again, and the tunnel serves fail-closed block-all
/// with no path back. Measured on a device: five hours, 183 compile errors, no artifact.
///
/// Retrying is the right answer for a timeout and the wrong answer for a 404. The device that
/// wedged had a source that was 1.5x the byte cap — no number of retries was ever going to
/// make that download fit, and every retry cost a 45 MB transfer through a VPN tunnel first.
///
/// 🔴 WHY THIS IS CONSERVATIVE, AND MUST STAY SO. Classifying a TRANSIENT failure as permanent
/// drops a list the user asked for, on a device that would have recovered by itself. The
/// bootstrap deadlock this codebase already documents looks exactly like a source failure —
/// while the resident snapshot is fail-closed, the app's own `getaddrinfo` returns the
/// block-all address, so an ordinary catalog fetch fails with `cannotFindHost` against a
/// perfectly healthy upstream. Treating THAT as permanent would quarantine every source on
/// the device during the exact window the repair runs in. Nothing name-resolution-shaped,
/// nothing timeout-shaped, and nothing server-side-5xx-shaped may ever be permanent.
///
/// Only three things qualify, and each is a fact about the RESOURCE rather than about the
/// network between us and it.
public enum BlocklistSourceFailureClassification: Equatable, Sendable {
    /// Retry later. The source may well be fine.
    case transient
    /// The source cannot be used as configured, however many times it is fetched.
    /// The payload is a stable log identifier, never user copy.
    case permanent(reason: String)

    /// Classify a sync failure.
    ///
    /// Defaults to `.transient` for anything unrecognised, deliberately: an unknown error is
    /// a reason to try again, not a reason to silently stop enforcing one of the user's
    /// lists. The safe direction of this decision is "keep the list".
    public static func classify(_ error: any Error) -> BlocklistSourceFailureClassification {
        guard let syncError = error as? BlocklistCatalogSyncError else {
            return .transient
        }

        switch syncError {
        case .invalidHTTPStatus(let statusCode):
            // 404/410 only: the origin saying the resource is not there and, for 410, that
            // it is not coming back.
            //
            // 🔴 403 WAS HERE AND IS NOT ANY MORE. It reads as "this origin will not serve
            // you", but the 403-shaped failures these hosts actually produce are mostly
            // SELF-HEALING: WAF challenges, rate limits, geo-blocks, an expired signed URL,
            // a CDN having a bad day. Quarantining on those drops a list the user chose
            // because a provider throttled us for ten minutes. (Kilo, #535.)
            //
            // 5xx is not here for the same reason, more obviously: a server error is the
            // most retry-worthy failure there is.
            switch statusCode {
            case 404, 410: return .permanent(reason: "http-\(statusCode)")
            default: return .transient
            }

        case .blocklistTooLarge(_, let byteSize):
            // The resource is bigger than the process can admit; retrying re-downloads it to
            // reach the same conclusion.
            //
            // 🔴 NOT the path the chimmy outage took, despite the shared cause — an earlier
            // version of this comment claimed it was. That device blew the cap MID-TRANSFER,
            // which throws `BlocklistDownloadSizeLimitExceeded` from the streaming fetcher,
            // and that type is internal to LavaSecNetworking so it never reaches this switch.
            // See the gap note at the bottom of this file: until the catalog path wraps a
            // foreign fetch error the way the custom path does, an over-cap source fetched by
            // streaming is retried rather than quarantined. (Kilo, #535.)
            return .permanent(reason: "over-byte-cap-\(byteSize)")

        case .blocklistExceedsRuleLimit(_, let ruleLimit):
            // Over the TIER's rule cap. Also permanent, and for a stronger reason than size:
            // admitting it would breach INV-TIER-1, so there is no configuration of this
            // device on which the fetch could succeed.
            return .permanent(reason: "over-rule-cap-\(ruleLimit)")

        case .invalidBlocklistEncoding(let sourceID):
            // The bytes arrived and are not text we can parse. A re-fetch of the same bytes
            // parses the same way.
            return .permanent(reason: "unparseable-\(sourceID)")

        case .checksumMismatch, .noAcceptedSourceHashes:
            // 🔴 TRANSIENT, and this one is worth stating because it looks permanent.
            // A hash the curation pipeline has not accepted yet is a fact about OUR catalog
            // being behind the upstream, not about the source being broken. It resolves when
            // curation catches up, with no user action and no change on the device — so
            // dropping the list in the meantime would under-block for a lag we introduced.
            return .transient

        case .invalidCatalog, .noCachedCatalog, .noRulesAvailable, .missingEnabledBlocklistSource,
            .customBlocklistUnavailable:
            // None of these describe a single source's resource being unusable.
            // `customBlocklistUnavailable` in particular WRAPS an underlying reason as a
            // string, so its cause is not recoverable by type here — see the note below.
            return .transient
        }
    }

    /// Whether this classification should drop the source from the effective set.
    public var isPermanent: Bool {
        if case .permanent = self { return true }
        return false
    }

    /// The stable log identifier, or nil when the failure is transient.
    public var logReason: String? {
        if case .permanent(let reason) = self { return reason }
        return nil
    }
}

// KNOWN GAP, recorded rather than papered over.
//
// The streaming download abort — `BlocklistDownloadSizeLimitExceeded`, thrown by
// `PinnedPublicHTTPSFetcher` when a body crosses the cap mid-transfer — is INTERNAL to
// LavaSecNetworking by deliberate design, so this type cannot match on it and classifies it
// `.transient`. That is the wrong answer for the exact failure observed on device.
//
// It is not fixed here because the honest fix is upstream of classification: the per-source
// catalog path should wrap a foreign fetch error into `blocklistTooLarge(sourceID:byteSize:)`
// the way the CUSTOM path already wraps into `customBlocklistUnavailable`, which also gives
// the error the sourceID it currently lacks. Once that lands, this classifier needs no change
// — the case is already handled above. Until then, an over-cap source fetched through the
// streaming path is retried rather than quarantined: wasteful, and strictly the SAFE
// direction of the two.
