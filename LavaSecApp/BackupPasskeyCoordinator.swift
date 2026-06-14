@preconcurrency import AuthenticationServices
import Foundation
import Security
import UIKit

enum BackupSetupPasskeyMode: Equatable {
    case withPasskey
    case withoutPasskey
}

enum BackupPasskeyConfiguration {
    static let relyingPartyIdentifier = "lavasecurity.app"
    static let displayName = "Lava Security"
}

struct BackupPasskeyRegistrationRecord: Equatable {
    let credentialID: String
    let relyingPartyIdentifier: String
    let credential: BackupPasskeyRegistrationCredential
}

struct BackupPasskeyAssertionRecord: Equatable {
    let credentialID: String
    let credential: BackupPasskeyAssertionCredential
}

struct BackupPasskeyCredentialClientExtensionResults: Codable, Equatable {}

struct BackupPasskeyRegistrationCredential: Codable, Equatable {
    let id: String
    let rawID: String
    let response: BackupPasskeyRegistrationCredentialResponse
    let clientExtensionResults: BackupPasskeyCredentialClientExtensionResults
    let type: String

    enum CodingKeys: String, CodingKey {
        case id
        case rawID = "rawId"
        case response
        case clientExtensionResults
        case type
    }
}

struct BackupPasskeyRegistrationCredentialResponse: Codable, Equatable {
    let clientDataJSON: String
    let attestationObject: String
    let transports: [String]
}

struct BackupPasskeyAssertionCredential: Codable, Equatable {
    let id: String
    let rawID: String
    let response: BackupPasskeyAssertionCredentialResponse
    let clientExtensionResults: BackupPasskeyCredentialClientExtensionResults
    let type: String

    enum CodingKeys: String, CodingKey {
        case id
        case rawID = "rawId"
        case response
        case clientExtensionResults
        case type
    }
}

struct BackupPasskeyAssertionCredentialResponse: Codable, Equatable {
    let clientDataJSON: String
    let authenticatorData: String
    let signature: String
    let userHandle: String?
}

enum BackupPasskeyError: Error, LocalizedError {
    case alreadyInProgress
    case authorizationFailed
    case canceled
    case invalidChallenge
    case invalidCredentialID
    case missingAccount
    case noMatchingCredential
    case randomBytesFailed(OSStatus)
    case unsupportedCredential
    case webCredentialsAssociationUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyInProgress:
            "Passkey setup is already in progress."
        case .authorizationFailed:
            "Passkey could not be used. Try again, or continue without Passkey."
        case .canceled:
            "Passkey was canceled."
        case .invalidChallenge:
            "The passkey challenge could not be read. Try again."
        case .invalidCredentialID:
            "The saved passkey could not be read. Set up Passkey again."
        case .missingAccount:
            "Sign in before creating a passkey."
        case .noMatchingCredential:
            "No matching passkey was found. Use Recovery or set up Passkey again."
        case .randomBytesFailed(let status):
            "Could not prepare a secure passkey challenge. Security returned status \(status)."
        case .unsupportedCredential:
            "iOS did not return a passkey credential."
        case .webCredentialsAssociationUnavailable:
            "Passkey is not ready on this device yet. Delete and reinstall the latest app build, then try again, or set up without Passkey."
        }
    }
}

@MainActor
final class BackupPasskeyCoordinator: NSObject {
    private enum ActivePasskeyRequest {
        case registration(CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialRegistration, Error>)
        case assertion(CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>)
    }

    private var activeAuthorizationController: ASAuthorizationController?
    private var activeRequest: ActivePasskeyRequest?

    func registerPasskey(userID: String, name: String, challenge: String) async throws -> BackupPasskeyRegistrationRecord {
        guard activeRequest == nil else {
            throw BackupPasskeyError.alreadyInProgress
        }

        guard let challengeData = Self.base64URLDecoded(challenge) else {
            throw BackupPasskeyError.invalidChallenge
        }

        let userIDData = Data(userID.utf8)
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: BackupPasskeyConfiguration.relyingPartyIdentifier
        )
        let request = provider.createCredentialRegistrationRequest(
            challenge: challengeData,
            name: name,
            userID: userIDData
        )

        let registration = try await performRegistration(request)
        guard let attestationObject = registration.rawAttestationObject else {
            throw BackupPasskeyError.unsupportedCredential
        }
        let credentialID = Self.base64URLEncoded(registration.credentialID)
        let credential = BackupPasskeyRegistrationCredential(
            id: credentialID,
            rawID: credentialID,
            response: BackupPasskeyRegistrationCredentialResponse(
                clientDataJSON: Self.base64URLEncoded(registration.rawClientDataJSON),
                attestationObject: Self.base64URLEncoded(attestationObject),
                transports: ["internal"]
            ),
            clientExtensionResults: BackupPasskeyCredentialClientExtensionResults(),
            type: "public-key"
        )

        return BackupPasskeyRegistrationRecord(
            credentialID: credentialID,
            relyingPartyIdentifier: BackupPasskeyConfiguration.relyingPartyIdentifier,
            credential: credential
        )
    }

    func assertPasskey(credentialID: String, challenge: String) async throws -> BackupPasskeyAssertionRecord {
        guard activeRequest == nil else {
            throw BackupPasskeyError.alreadyInProgress
        }

        guard let credentialIDData = Self.base64URLDecoded(credentialID) else {
            throw BackupPasskeyError.invalidCredentialID
        }

        guard let challengeData = Self.base64URLDecoded(challenge) else {
            throw BackupPasskeyError.invalidChallenge
        }

        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: BackupPasskeyConfiguration.relyingPartyIdentifier
        )
        let request = provider.createCredentialAssertionRequest(challenge: challengeData)
        request.allowedCredentials = [
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: credentialIDData)
        ]

        let assertion = try await performAssertion(request)
        let assertedCredentialID = Self.base64URLEncoded(assertion.credentialID)
        let userHandle = assertion.userID.isEmpty ? nil : Self.base64URLEncoded(assertion.userID)
        let credential = BackupPasskeyAssertionCredential(
            id: assertedCredentialID,
            rawID: assertedCredentialID,
            response: BackupPasskeyAssertionCredentialResponse(
                clientDataJSON: Self.base64URLEncoded(assertion.rawClientDataJSON),
                authenticatorData: Self.base64URLEncoded(assertion.rawAuthenticatorData),
                signature: Self.base64URLEncoded(assertion.signature),
                userHandle: userHandle
            ),
            clientExtensionResults: BackupPasskeyCredentialClientExtensionResults(),
            type: "public-key"
        )

        return BackupPasskeyAssertionRecord(
            credentialID: assertedCredentialID,
            credential: credential
        )
    }

    static func makeChallenge() throws -> Data {
        try randomBytes(count: 32)
    }

    private func performRegistration(
        _ request: ASAuthorizationPlatformPublicKeyCredentialRegistrationRequest
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialRegistration {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialRegistration, Error>) in
            self.activeRequest = .registration(continuation)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            activeAuthorizationController = controller
            controller.performRequests()
        }
    }

    private func performAssertion(
        _ request: ASAuthorizationPlatformPublicKeyCredentialAssertionRequest
    ) async throws -> ASAuthorizationPlatformPublicKeyCredentialAssertion {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<ASAuthorizationPlatformPublicKeyCredentialAssertion, Error>) in
            self.activeRequest = .assertion(continuation)
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            activeAuthorizationController = controller
            controller.performRequests()
        }
    }

    private static func randomBytes(count: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw BackupPasskeyError.randomBytesFailed(status)
        }

        return Data(bytes)
    }

    private static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func base64URLDecoded(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        return Data(base64Encoded: base64)
    }

    private static func mapAuthorizationError(_ error: Error) -> Error {
        let nsError = error as NSError
        let failureReason = (nsError.userInfo[NSLocalizedFailureReasonErrorKey] as? String) ?? nsError.localizedDescription
        if nsError.domain == "com.apple.AuthenticationServices.AuthorizationError",
           nsError.code == ASAuthorizationError.Code.notInteractive.rawValue,
           failureReason.localizedCaseInsensitiveContains("webcredentials association") {
            return BackupPasskeyError.webCredentialsAssociationUnavailable
        }

        guard nsError.domain == "com.apple.AuthenticationServices.AuthorizationError" else {
            return BackupPasskeyError.authorizationFailed
        }

        switch nsError.code {
        case ASAuthorizationError.Code.canceled.rawValue:
            return BackupPasskeyError.canceled
        case ASAuthorizationError.Code.notHandled.rawValue:
            return BackupPasskeyError.noMatchingCredential
        case ASAuthorizationError.Code.failed.rawValue,
             ASAuthorizationError.Code.invalidResponse.rawValue,
             ASAuthorizationError.Code.notInteractive.rawValue,
             ASAuthorizationError.Code.unknown.rawValue:
            return BackupPasskeyError.authorizationFailed
        default:
            return BackupPasskeyError.authorizationFailed
        }
    }
}

extension BackupPasskeyCoordinator: ASAuthorizationControllerDelegate {
    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        Task { @MainActor in
            activeAuthorizationController = nil

            guard let activeRequest else {
                return
            }

            self.activeRequest = nil

            switch activeRequest {
            case .registration(let continuation):
                guard let registration = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
                    continuation.resume(throwing: BackupPasskeyError.unsupportedCredential)
                    return
                }

                continuation.resume(returning: registration)
            case .assertion(let continuation):
                guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
                    continuation.resume(throwing: BackupPasskeyError.unsupportedCredential)
                    return
                }

                continuation.resume(returning: assertion)
            }
        }
    }

    nonisolated func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        Task { @MainActor in
            activeAuthorizationController = nil

            guard let activeRequest else {
                return
            }

            self.activeRequest = nil
            let mappedError = Self.mapAuthorizationError(error)
            switch activeRequest {
            case .registration(let continuation):
                continuation.resume(throwing: mappedError)
            case .assertion(let continuation):
                continuation.resume(throwing: mappedError)
            }
        }
    }
}

extension BackupPasskeyCoordinator: ASAuthorizationControllerPresentationContextProviding {
    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let windowScenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            return windowScenes
                .flatMap(\.windows)
                .first(where: \.isKeyWindow)
                ?? windowScenes.first?.windows.first
                ?? ASPresentationAnchor()
        }
    }
}
