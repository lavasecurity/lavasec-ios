import Foundation
import LavaSecCore

struct BackupPasskeyChallenge: Decodable, Equatable {
    let challenge: String
}

struct BackupPasskeyRecoveryService {
    var urlSession: URLSession = .shared

    func registrationChallenge(session: BackupAccountSession) async throws -> BackupPasskeyChallenge {
        try await post(
            path: "registration-challenge",
            session: session,
            body: EmptyPasskeyRequest(),
            responseType: BackupPasskeyChallenge.self
        )
    }

    func registerPasskey(
        session: BackupAccountSession,
        credential: BackupPasskeyRegistrationCredential
    ) async throws {
        _ = try await post(
            path: "register",
            session: session,
            body: BackupPasskeyRegistrationRequest(credential: credential),
            responseType: BackupPasskeyCredentialResponse.self
        )
    }

    func storeRecoverySecret(
        session: BackupAccountSession,
        credentialID: String,
        recoverySecret: String
    ) async throws {
        _ = try await post(
            path: "recovery-secret",
            session: session,
            body: BackupPasskeyRecoverySecretRequest(
                credentialID: credentialID,
                recoverySecret: recoverySecret
            ),
            responseType: BackupPasskeyCredentialResponse.self
        )
    }

    func assertionChallenge(
        session: BackupAccountSession,
        credentialID: String
    ) async throws -> BackupPasskeyChallenge {
        try await post(
            path: "assertion-challenge",
            session: session,
            body: BackupPasskeyAssertionChallengeRequest(credentialID: credentialID),
            responseType: BackupPasskeyChallenge.self
        )
    }

    func recover(
        session: BackupAccountSession,
        credential: BackupPasskeyAssertionCredential
    ) async throws -> String {
        let response = try await post(
            path: "recover",
            session: session,
            body: BackupPasskeyRecoveryRequest(credential: credential),
            responseType: BackupPasskeyRecoveryResponse.self
        )
        return response.recoverySecret
    }

    private func post<Body: Encodable, Response: Decodable>(
        path: String,
        session: BackupAccountSession,
        body: Body,
        responseType: Response.Type
    ) async throws -> Response {
        let bodyData = try JSONEncoder().encode(body)
        var lastError: Error?
        var lastServiceError: BackupPasskeyRecoveryServiceError?

        for endpoint in Self.endpointURLs(path: path) {
            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
                request.httpBody = bodyData

                let (data, response) = try await urlSession.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw BackupPasskeyRecoveryServiceError(message: "The passkey recovery server response was not valid.")
                }

                guard 200..<300 ~= httpResponse.statusCode else {
                    throw BackupPasskeyRecoveryServiceError(
                        message: Self.friendlyMessage(forStatusCode: httpResponse.statusCode)
                    )
                }

                return try JSONDecoder().decode(Response.self, from: data)
            } catch let error as BackupPasskeyRecoveryServiceError {
                lastServiceError = error
                lastError = error
            } catch {
                lastError = error
            }
        }

        if let lastServiceError {
            throw lastServiceError
        }

        throw Self.friendlyMessage(forTransportError: lastError)
    }

    private static func endpointURLs(path: String) -> [URL] {
        [LavaSecAPI.productionBaseURL, LavaSecAPI.fallbackBaseURL].map {
            $0
                .appendingPathComponent("v1")
                .appendingPathComponent("backup")
                .appendingPathComponent("passkeys")
                .appendingPathComponent(path)
        }
    }

    private static func friendlyMessage(forStatusCode statusCode: Int) -> String {
        switch statusCode {
        case 400, 422:
            "Passkey verification failed. Try again, or use Recovery."
        case 401:
            "Sign in again, then try Passkey."
        case 403:
            "This backup is not available for this account. Sign in with the account that created it."
        case 404:
            "No Passkey recovery was found. Use Recovery instead."
        case 409:
            "Passkey setup expired. Try again."
        case 429:
            "Too many attempts. Wait a minute, then try again."
        case 500..<600:
            "Lava backup service is temporarily unavailable. Try again later."
        default:
            "Passkey recovery failed. Try again, or use Recovery."
        }
    }

    private static func friendlyMessage(forTransportError error: Error?) -> BackupPasskeyRecoveryServiceError {
        if error is URLError {
            return BackupPasskeyRecoveryServiceError(message: "Could not reach Lava. Check your connection and try again.")
        }

        if error is DecodingError {
            return BackupPasskeyRecoveryServiceError(message: "The passkey recovery response was not valid. Try again later.")
        }

        return BackupPasskeyRecoveryServiceError(message: "Could not reach Lava. Check your connection and try again.")
    }
}

private struct EmptyPasskeyRequest: Encodable {}

private struct BackupPasskeyRegistrationRequest: Encodable {
    let credential: BackupPasskeyRegistrationCredential
}

private struct BackupPasskeyAssertionChallengeRequest: Encodable {
    let credentialID: String

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
    }
}

private struct BackupPasskeyRecoverySecretRequest: Encodable {
    let credentialID: String
    let recoverySecret: String

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
        case recoverySecret = "recovery_secret"
    }
}

private struct BackupPasskeyRecoveryRequest: Encodable {
    let credential: BackupPasskeyAssertionCredential
}

private struct BackupPasskeyCredentialResponse: Decodable {
    let credentialID: String

    enum CodingKeys: String, CodingKey {
        case credentialID = "credential_id"
    }
}

private struct BackupPasskeyRecoveryResponse: Decodable {
    let recoverySecret: String

    enum CodingKeys: String, CodingKey {
        case recoverySecret = "recovery_secret"
    }
}

private struct BackupPasskeyRecoveryServiceError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}
