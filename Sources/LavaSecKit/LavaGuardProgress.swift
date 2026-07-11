import Foundation

/// A usage-day threshold that unlocks a Lava Guard.
public struct LavaGuardUnlockGoal: Equatable, Codable, Sendable {
    /// The identifier of the guard unlocked by this goal.
    public let guardID: String
    /// The number of qualified usage days required for the unlock.
    public let requiredUsageDays: Int

    /// Creates an unlock goal for a guard and required usage-day count.
    public init(guardID: String, requiredUsageDays: Int) {
        self.guardID = guardID
        self.requiredUsageDays = requiredUsageDays
    }
}

/// Defines the usage threshold and ordered unlock goals for Lava Guards.
public enum LavaGuardProgressPolicy {
    /// The minimum local-protection uptime, in seconds, that qualifies a usage day.
    public static let minimumUsageDayUptime: TimeInterval = 10 * 60

    /// The configured guard unlock goals in ascending usage-day order.
    public static let unlockGoals: [LavaGuardUnlockGoal] = [
        LavaGuardUnlockGoal(guardID: "emberObsidian", requiredUsageDays: 3),
        LavaGuardUnlockGoal(guardID: "purpleObsidian", requiredUsageDays: 7),
        LavaGuardUnlockGoal(guardID: "obsidian", requiredUsageDays: 14),
        LavaGuardUnlockGoal(guardID: "strawberryObsidian", requiredUsageDays: 30),
        LavaGuardUnlockGoal(guardID: "emerald", requiredUsageDays: 60),
        LavaGuardUnlockGoal(guardID: "kiwiCreme", requiredUsageDays: 90)
    ]

    /// Returns the configured unlock goal for `guardID`, if one exists.
    public static func unlockGoal(for guardID: String) -> LavaGuardUnlockGoal? {
        unlockGoals.first { $0.guardID == guardID }
    }
}

/// A timestamped record of a guard unlock.
public struct LavaGuardUnlockRecord: Codable, Equatable, Hashable, Sendable {
    /// The identifier of the unlocked guard.
    public let guardID: String
    /// The time at which the guard was unlocked.
    public let unlockedAt: Date

    /// Creates an unlock record for a guard and timestamp.
    public init(guardID: String, unlockedAt: Date) {
        self.guardID = guardID
        self.unlockedAt = unlockedAt
    }
}

/// A ledger of Lava Guard unlock records.
public struct LavaGuardAchievementLedger: Codable, Equatable, Sendable {
    /// The unlock records retained by the ledger.
    public private(set) var records: [LavaGuardUnlockRecord]

    /// Creates a ledger, retaining the earliest record for each guard.
    public init(records: [LavaGuardUnlockRecord] = []) {
        var firstRecordByGuardID: [String: LavaGuardUnlockRecord] = [:]
        for record in records {
            if let existing = firstRecordByGuardID[record.guardID],
               existing.unlockedAt <= record.unlockedAt {
                continue
            }
            firstRecordByGuardID[record.guardID] = record
        }

        self.records = firstRecordByGuardID.values.sorted { left, right in
            if left.unlockedAt == right.unlockedAt {
                return left.guardID < right.guardID
            }
            return left.unlockedAt < right.unlockedAt
        }
    }

    /// Returns whether the ledger contains an unlock for `guardID`.
    public func isUnlocked(guardID: String) -> Bool {
        records.contains { $0.guardID == guardID }
    }

    /// Records a guard unlock unless that guard is already present.
    public mutating func unlock(guardID: String, unlockedAt: Date) {
        guard !isUnlocked(guardID: guardID) else {
            return
        }

        records.append(LavaGuardUnlockRecord(guardID: guardID, unlockedAt: unlockedAt))
        records.sort { left, right in
            if left.unlockedAt == right.unlockedAt {
                return left.guardID < right.guardID
            }
            return left.unlockedAt < right.unlockedAt
        }
    }
}

/// A snapshot of progress toward one Lava Guard unlock goal.
public struct LavaGuardGoalProgress: Equatable, Sendable {
    /// The identifier of the guard represented by this progress.
    public let guardID: String
    /// The number of qualified days required by the goal.
    public let requiredUsageDays: Int
    /// The qualified usage days credited toward the goal.
    public let currentUsageDays: Int
    /// Whether the achievement ledger already contains this guard.
    public let isUnlocked: Bool

    /// The nonnegative number of additional qualified days needed.
    public var remainingUsageDays: Int {
        max(0, requiredUsageDays - currentUsageDays)
    }
}

/// Tracks local-protection usage days used to unlock Lava Guards.
public struct LavaGuardProgress: Codable, Equatable, Sendable {
    /// Calendar-day keys that have met the minimum uptime threshold.
    public private(set) var qualifiedUsageDayKeys: Set<String>
    /// Accumulated local-protection uptime, in seconds, by calendar-day key.
    public private(set) var usageByDayKey: [String: TimeInterval]
    /// The start of the currently active usage interval, if any.
    public private(set) var activeUsageStartedAt: Date?

    /// Creates progress from qualified days, per-day usage, and optional active usage.
    public init(
        qualifiedUsageDayKeys: Set<String> = [],
        usageByDayKey: [String: TimeInterval] = [:],
        activeUsageStartedAt: Date? = nil
    ) {
        self.qualifiedUsageDayKeys = qualifiedUsageDayKeys
        self.usageByDayKey = usageByDayKey
        self.activeUsageStartedAt = activeUsageStartedAt
    }

    /// The number of qualified usage days.
    public var usageDayCount: Int {
        qualifiedUsageDayKeys.count
    }

    /// Adds a nonempty day key and writes any newly eligible unlocks to `ledger`.
    public mutating func recordQualifiedUsageDay(
        _ dayKey: String,
        unlockedAt: Date = Date(),
        ledger: inout LavaGuardAchievementLedger
    ) {
        let trimmedKey = dayKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            return
        }

        qualifiedUsageDayKeys.insert(trimmedKey)
        writeEligibleUnlocks(unlockedAt: unlockedAt, ledger: &ledger)
    }

    /// Replaces qualified day keys with trimmed nonempty values and applies eligible unlocks.
    public mutating func replaceQualifiedUsageDayKeys(
        _ dayKeys: Set<String>,
        unlockedAt: Date = Date(),
        ledger: inout LavaGuardAchievementLedger
    ) {
        qualifiedUsageDayKeys = Set(
            dayKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        writeEligibleUnlocks(unlockedAt: unlockedAt, ledger: &ledger)
    }

    /// Clears qualified days, accumulated uptime, and any active usage interval.
    public mutating func clearUsageProgress() {
        qualifiedUsageDayKeys.removeAll(keepingCapacity: true)
        usageByDayKey.removeAll(keepingCapacity: true)
        activeUsageStartedAt = nil
    }

    /// Updates tracked uptime and running state at `date`, then applies eligible unlocks.
    public mutating func synchronizeLocalProtectionUsage(
        isRunning: Bool,
        at date: Date = Date(),
        calendar: Calendar = .current,
        unlockedAt: Date = Date(),
        ledger: inout LavaGuardAchievementLedger
    ) {
        if isRunning {
            if let activeUsageStartedAt {
                recordUsage(from: activeUsageStartedAt, to: date, calendar: calendar)
            }
            activeUsageStartedAt = date
        } else if let activeUsageStartedAt {
            recordUsage(from: activeUsageStartedAt, to: date, calendar: calendar)
            self.activeUsageStartedAt = nil
        }

        writeEligibleUnlocks(unlockedAt: unlockedAt, ledger: &ledger)
    }

    /// Returns progress for a configured guard goal, or `nil` for an unknown guard.
    public func progress(
        for guardID: String,
        ledger: LavaGuardAchievementLedger
    ) -> LavaGuardGoalProgress? {
        guard let goal = LavaGuardProgressPolicy.unlockGoal(for: guardID) else {
            return nil
        }

        return LavaGuardGoalProgress(
            guardID: guardID,
            requiredUsageDays: goal.requiredUsageDays,
            currentUsageDays: min(usageDayCount, goal.requiredUsageDays),
            isUnlocked: ledger.isUnlocked(guardID: guardID)
        )
    }

    private func writeEligibleUnlocks(
        unlockedAt: Date,
        ledger: inout LavaGuardAchievementLedger
    ) {
        for goal in LavaGuardProgressPolicy.unlockGoals where usageDayCount >= goal.requiredUsageDays {
            ledger.unlock(guardID: goal.guardID, unlockedAt: unlockedAt)
        }
    }

    private mutating func recordUsage(from startDate: Date, to endDate: Date, calendar: Calendar) {
        guard endDate > startDate else {
            return
        }

        var cursor = startDate
        while cursor < endDate {
            let dayStart = calendar.startOfDay(for: cursor)
            guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
                break
            }

            let segmentEnd = min(endDate, dayEnd)
            let key = Self.dayKey(for: cursor, calendar: calendar)
            usageByDayKey[key, default: 0] += max(0, segmentEnd.timeIntervalSince(cursor))
            if usageByDayKey[key, default: 0] >= LavaGuardProgressPolicy.minimumUsageDayUptime {
                qualifiedUsageDayKeys.insert(key)
            }
            cursor = segmentEnd
        }
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return "\(year)-\(month)-\(day)"
    }
}

/// Evaluates whether a Lava Guard is available under entitlement and unlock rules.
public enum LavaGuardAvailabilityPolicy {
    /// Returns whether any original, entitlement, achievement, or courtesy condition allows the guard.
    public static func isAvailable(
        guardID: String,
        isOriginal: Bool,
        hasLavaSecurityPlus: Bool,
        ledger: LavaGuardAchievementLedger,
        courtesyGuardID: String?
    ) -> Bool {
        isOriginal
            || hasLavaSecurityPlus
            || ledger.isUnlocked(guardID: guardID)
            || courtesyGuardID == guardID
    }
}
