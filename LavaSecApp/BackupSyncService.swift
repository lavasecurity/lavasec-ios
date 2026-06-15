import Foundation
import LavaSecCore

struct BackupAccountSession: Equatable, Sendable {
    let userID: String
    let accessToken: String
}

struct SupabaseAppConfiguration: Equatable, Sendable {
    let projectURL: URL
    let anonKey: String

    static func load(bundle: Bundle = .main) -> SupabaseAppConfiguration? {
        let urlString = bundle.object(forInfoDictionaryKey: "LavaSupabaseURL") as? String
        let anonKey = bundle.object(forInfoDictionaryKey: "LavaSupabaseAnonKey") as? String

        guard let urlString,
              let projectURL = URL(string: urlString),
              let anonKey,
              !anonKey.isEmpty
        else {
            return nil
        }

        return SupabaseAppConfiguration(projectURL: projectURL, anonKey: anonKey)
    }
}

protocol BackupSyncServicing: Sendable {
    func upload(_ envelope: ZeroKnowledgeBackupEnvelope, session: BackupAccountSession) async throws
    func fetchLatest(session: BackupAccountSession) async throws -> ZeroKnowledgeBackupEnvelope?
    func markRestored(session: BackupAccountSession) async throws
    func deleteRemote(session: BackupAccountSession) async throws
}

enum BackupSyncServiceError: Error, LocalizedError, Equatable {
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "The backup server response was not valid."
        case .requestFailed(let statusCode):
            Self.friendlyMessage(forStatusCode: statusCode)
        }
    }

    private static func friendlyMessage(forStatusCode statusCode: Int) -> String {
        switch statusCode {
        case 401:
            "Sign in again to sync encrypted backup."
        case 403:
            "This backup is not available for this account."
        case 404:
            "No encrypted backup was found for this account."
        case 409:
            "Backup sync conflict. Try Back Up Now again."
        case 429:
            "Too many backup attempts. Wait a minute, then try again."
        case 500..<600:
            "Lava backup service is temporarily unavailable. Try again later."
        default:
            "Encrypted backup sync failed. Try again."
        }
    }
}

struct SupabaseBackupSyncService: BackupSyncServicing {
    let configuration: SupabaseAppConfiguration
    var urlSession: URLSession = .shared

    func upload(_ envelope: ZeroKnowledgeBackupEnvelope, session: BackupAccountSession) async throws {
        var request = try makeRequest(
            path: "user_backups",
            queryItems: [URLQueryItem(name: "on_conflict", value: "user_id")],
            session: session
        )
        request.httpMethod = "POST"
        request.setValue("resolution=merge-duplicates", forHTTPHeaderField: "Prefer")
        request.httpBody = try Self.makeJSONEncoder().encode(UserBackupUpsert(envelope: envelope, userID: session.userID))

        let (_, response) = try await urlSession.data(for: request)
        try validateMutationResponse(response)
    }

    func fetchLatest(session: BackupAccountSession) async throws -> ZeroKnowledgeBackupEnvelope? {
        var request = try makeRequest(
            path: "user_backups",
            queryItems: [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "user_id", value: "eq.\(session.userID)"),
                URLQueryItem(name: "disabled_at", value: "is.null"),
                URLQueryItem(name: "limit", value: "1")
            ],
            session: session
        )
        request.httpMethod = "GET"

        let (data, response) = try await urlSession.data(for: request)
        try validateReadResponse(response)

        let records = try Self.makeJSONDecoder().decode([UserBackupRecord].self, from: data)
        return records.first?.envelope()
    }

    func markRestored(session: BackupAccountSession) async throws {
        var request = try makeRequest(
            path: "user_backups",
            queryItems: [URLQueryItem(name: "user_id", value: "eq.\(session.userID)")],
            session: session
        )
        request.httpMethod = "PATCH"
        request.httpBody = try Self.makeJSONEncoder().encode(UserBackupRestorePatch(lastRestoredAt: Date()))

        let (_, response) = try await urlSession.data(for: request)
        try validateMutationResponse(response)
    }

    // Hard delete (not a `disabled_at` soft flag): per our zero-knowledge stance,
    // clearing/disabling backup must remove the stored row entirely so nothing the
    // server holds can be a decrypting copy. RLS scopes the delete to the row owner.
    func deleteRemote(session: BackupAccountSession) async throws {
        var request = try makeRequest(
            path: "user_backups",
            queryItems: [URLQueryItem(name: "user_id", value: "eq.\(session.userID)")],
            session: session
        )
        request.httpMethod = "DELETE"
        request.setValue("return=minimal", forHTTPHeaderField: "Prefer")

        let (_, response) = try await urlSession.data(for: request)
        try validateMutationResponse(response)
    }

    private func makeRequest(
        path: String,
        queryItems: [URLQueryItem],
        session: BackupAccountSession
    ) throws -> URLRequest {
        let restURL = configuration.projectURL.appending(path: "rest/v1/\(path)")
        guard var components = URLComponents(url: restURL, resolvingAgainstBaseURL: false) else {
            throw BackupSyncServiceError.invalidResponse
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw BackupSyncServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue(configuration.anonKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func validateMutationResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw BackupSyncServiceError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw BackupSyncServiceError.requestFailed(httpResponse.statusCode)
        }
    }

    private func validateReadResponse(_ response: URLResponse) throws {
        try validateMutationResponse(response)
    }

    private static func makeJSONEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private struct UserBackupUpsert: Encodable {
    let userID: String
    let backupVersion: Int
    let envelopeVersion: Int
    let ciphertext: String
    let metadata: BackupEnvelopeMetadata
    let ciphertextByteSize: Int

    enum CodingKeys: String, CodingKey {
        case userID = "user_id"
        case backupVersion = "backup_version"
        case envelopeVersion = "envelope_version"
        case ciphertext
        case metadata
        case ciphertextByteSize = "ciphertext_byte_size"
    }

    init(envelope: ZeroKnowledgeBackupEnvelope, userID: String) {
        self.userID = userID
        backupVersion = envelope.schemaVersion
        envelopeVersion = envelope.envelopeVersion
        ciphertext = envelope.payloadCiphertext
        metadata = BackupEnvelopeMetadata(envelope: envelope)
        ciphertextByteSize = envelope.ciphertextByteSize
    }
}

private struct UserBackupRecord: Decodable {
    let backupVersion: Int
    let envelopeVersion: Int
    let ciphertext: String
    let metadata: BackupEnvelopeMetadata
    let ciphertextByteSize: Int

    enum CodingKeys: String, CodingKey {
        case backupVersion = "backup_version"
        case envelopeVersion = "envelope_version"
        case ciphertext
        case metadata
        case ciphertextByteSize = "ciphertext_byte_size"
    }

    func envelope() -> ZeroKnowledgeBackupEnvelope {
        ZeroKnowledgeBackupEnvelope(
            schemaVersion: backupVersion,
            envelopeVersion: envelopeVersion,
            cipher: metadata.cipher,
            payloadCiphertext: ciphertext,
            keySlots: metadata.keySlots,
            serverRecoveryShare: metadata.serverRecoveryShare,
            ciphertextByteSize: ciphertextByteSize,
            createdAt: metadata.createdAt
        )
    }
}

private struct UserBackupRestorePatch: Encodable {
    let lastRestoredAt: Date

    enum CodingKeys: String, CodingKey {
        case lastRestoredAt = "last_restored_at"
    }
}

private struct BackupEnvelopeMetadata: Codable {
    let cipher: String
    let keySlots: [ZeroKnowledgeBackupKeySlot]
    let serverRecoveryShare: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case cipher
        case keySlots = "key_slots"
        case serverRecoveryShare = "server_recovery_share"
        case createdAt = "created_at"
    }

    init(envelope: ZeroKnowledgeBackupEnvelope) {
        cipher = envelope.cipher
        keySlots = envelope.keySlots
        serverRecoveryShare = envelope.serverRecoveryShare
        createdAt = envelope.createdAt
    }
}
