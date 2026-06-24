import AppIntents

public struct PauseLavaProtectionIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for your chosen length.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseConfigured)
        return .result()
    }
}

public struct PauseLavaProtectionFiveMinutesIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection for 5 Minutes"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for five minutes.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseFiveMinutes)
        return .result()
    }
}

public struct PauseLavaProtectionTenMinutesIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection for 10 Minutes"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for ten minutes.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseTenMinutes)
        return .result()
    }
}

public struct AuthenticatedPauseLavaProtectionFiveMinutesIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection for 5 Minutes"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for five minutes.")
    nonisolated(unsafe) public static var isDiscoverable = false
    nonisolated(unsafe) public static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseFiveMinutes)
        return .result()
    }
}

public struct AuthenticatedPauseLavaProtectionTenMinutesIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Pause Lava Protection for 10 Minutes"
    nonisolated(unsafe) public static var description = IntentDescription("Pause Lava protection for ten minutes.")
    nonisolated(unsafe) public static var isDiscoverable = false
    nonisolated(unsafe) public static var authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.pauseTenMinutes)
        return .result()
    }
}

public struct ResumeLavaProtectionIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Resume Lava Protection"
    nonisolated(unsafe) public static var description = IntentDescription("Resume Lava protection now.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.resume)
        return .result()
    }
}

public struct ReconnectLavaProtectionIntent: AppIntent, LiveActivityIntent {
    nonisolated(unsafe) public static var title: LocalizedStringResource = "Reconnect Lava Protection"
    nonisolated(unsafe) public static var description = IntentDescription("Reconnect Lava protection now.")
    nonisolated(unsafe) public static var isDiscoverable = false

    public init() {}

    public func perform() async throws -> some IntentResult {
        try await LavaProtectionCommandService.perform(.reconnect)
        return .result()
    }
}
