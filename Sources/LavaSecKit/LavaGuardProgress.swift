import Foundation

public struct LavaGuardUnlockGoal: Equatable, Codable, Sendable {
    public let guardID: String
    public let requiredUsageDays: Int

    public init(guardID: String, requiredUsageDays: Int) {
        self.guardID = guardID
        self.requiredUsageDays = requiredUsageDays
    }
}

public enum LavaGuardProgressPolicy {
    public static let minimumUsageDayUptime: TimeInterval = 10 * 60

    public static let unlockGoals: [LavaGuardUnlockGoal] = [
        LavaGuardUnlockGoal(guardID: "emberObsidian", requiredUsageDays: 3),
        LavaGuardUnlockGoal(guardID: "purpleObsidian", requiredUsageDays: 7),
        LavaGuardUnlockGoal(guardID: "obsidian", requiredUsageDays: 14),
        LavaGuardUnlockGoal(guardID: "strawberryObsidian", requiredUsageDays: 30),
        LavaGuardUnlockGoal(guardID: "emerald", requiredUsageDays: 60),
        LavaGuardUnlockGoal(guardID: "kiwiCreme", requiredUsageDays: 90)
    ]

    public static func unlockGoal(for guardID: String) -> LavaGuardUnlockGoal? {
        unlockGoals.first { $0.guardID == guardID }
    }
}

public struct LavaGuardUnlockRecord: Codable, Equatable, Hashable, Sendable {
    public let guardID: String
    public let unlockedAt: Date

    public init(guardID: String, unlockedAt: Date) {
        self.guardID = guardID
        self.unlockedAt = unlockedAt
    }
}

public struct LavaGuardAchievementLedger: Codable, Equatable, Sendable {
    public private(set) var records: [LavaGuardUnlockRecord]

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

    public func isUnlocked(guardID: String) -> Bool {
        records.contains { $0.guardID == guardID }
    }

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

public struct LavaGuardGoalProgress: Equatable, Sendable {
    public let guardID: String
    public let requiredUsageDays: Int
    public let currentUsageDays: Int
    public let isUnlocked: Bool

    public var remainingUsageDays: Int {
        max(0, requiredUsageDays - currentUsageDays)
    }
}

public struct LavaGuardProgress: Codable, Equatable, Sendable {
    public private(set) var qualifiedUsageDayKeys: Set<String>
    public private(set) var usageByDayKey: [String: TimeInterval]
    public private(set) var activeUsageStartedAt: Date?

    public init(
        qualifiedUsageDayKeys: Set<String> = [],
        usageByDayKey: [String: TimeInterval] = [:],
        activeUsageStartedAt: Date? = nil
    ) {
        self.qualifiedUsageDayKeys = qualifiedUsageDayKeys
        self.usageByDayKey = usageByDayKey
        self.activeUsageStartedAt = activeUsageStartedAt
    }

    public var usageDayCount: Int {
        qualifiedUsageDayKeys.count
    }

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

    public mutating func clearUsageProgress() {
        qualifiedUsageDayKeys.removeAll(keepingCapacity: true)
        usageByDayKey.removeAll(keepingCapacity: true)
        activeUsageStartedAt = nil
    }

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

public enum LavaGuardAvailabilityPolicy {
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
