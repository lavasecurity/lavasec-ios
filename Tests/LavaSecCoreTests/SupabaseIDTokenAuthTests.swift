import Foundation
@testable import LavaSecCore
@testable import LavaSecKit
import XCTest

final class SupabaseIDTokenAuthTests: XCTestCase {
    func testTokenRequestUsesSupabaseAuthEndpointAndIDTokenPayload() throws {
        let configuration = SupabaseIDTokenAuthConfiguration(
            projectURL: try XCTUnwrap(URL(string: "https://example.supabase.co")),
            publishableKey: "sb_publishable_test"
        )

        let request = try SupabaseIDTokenAuth.makeTokenRequest(
            configuration: configuration,
            provider: "apple",
            idToken: "apple-id-token",
            nonce: "raw-nonce"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/auth/v1/token?grant_type=id_token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object["provider"], "apple")
        XCTAssertEqual(object["id_token"], "apple-id-token")
        XCTAssertEqual(object["nonce"], "raw-nonce")
    }

    func testTokenRequestSupportsGoogleIDTokenAccessTokenAndNoncePayload() throws {
        let configuration = SupabaseIDTokenAuthConfiguration(
            projectURL: try XCTUnwrap(URL(string: "https://example.supabase.co")),
            publishableKey: "sb_publishable_test"
        )

        let request = try SupabaseIDTokenAuth.makeTokenRequest(
            configuration: configuration,
            provider: "google",
            idToken: "google-id-token",
            accessToken: "google-access-token",
            nonce: "raw-google-nonce"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/auth/v1/token?grant_type=id_token")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object["provider"], "google")
        XCTAssertEqual(object["id_token"], "google-id-token")
        XCTAssertEqual(object["access_token"], "google-access-token")
        XCTAssertEqual(object["nonce"], "raw-google-nonce")
    }

    func testRefreshRequestUsesSupabaseAuthRefreshGrant() throws {
        let configuration = SupabaseIDTokenAuthConfiguration(
            projectURL: try XCTUnwrap(URL(string: "https://example.supabase.co")),
            publishableKey: "sb_publishable_test"
        )

        let request = try SupabaseIDTokenAuth.makeRefreshTokenRequest(
            configuration: configuration,
            refreshToken: "refresh-token"
        )

        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.supabase.co/auth/v1/token?grant_type=refresh_token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "apikey"), "sb_publishable_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object["refresh_token"], "refresh-token")
    }

    func testDecodeSessionMapsSupabaseAuthResponse() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://example.supabase.co/auth/v1/token")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = """
        {
          "access_token": "access-token",
          "refresh_token": "refresh-token",
          "expires_in": 3600,
          "expires_at": 1779100000,
          "user": {
            "id": "user-123",
            "email": "user@example.com",
            "app_metadata": {
              "provider": "google"
            }
          }
        }
        """.data(using: .utf8)!

        let session = try SupabaseIDTokenAuth.decodeSession(data: data, response: response)

        XCTAssertEqual(session.accessToken, "access-token")
        XCTAssertEqual(session.refreshToken, "refresh-token")
        XCTAssertEqual(session.expiresIn, 3600)
        XCTAssertEqual(session.expiresAt, 1_779_100_000)
        XCTAssertEqual(session.user.id, "user-123")
        XCTAssertEqual(session.user.email, "user@example.com")
        XCTAssertEqual(session.user.provider, "google")
    }

    func testDecodeSessionMapsLinkedIdentityProviders() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://example.supabase.co/auth/v1/token")),
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = """
        {
          "access_token": "access-token",
          "refresh_token": "refresh-token",
          "user": {
            "id": "user-123",
            "email": "user@example.com",
            "app_metadata": {
              "provider": "apple",
              "providers": ["apple", "google"]
            },
            "identities": [
              { "provider": "apple" },
              { "provider": "google" }
            ]
          }
        }
        """.data(using: .utf8)!

        let session = try SupabaseIDTokenAuth.decodeSession(data: data, response: response)

        XCTAssertEqual(session.user.provider, "apple")
        XCTAssertEqual(session.user.providers, ["apple", "google"])
    }

    func testDecodeSessionSurfacesSupabaseErrorDescription() throws {
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://example.supabase.co/auth/v1/token")),
            statusCode: 400,
            httpVersion: nil,
            headerFields: nil
        ))
        let data = """
        {
          "error": "invalid_grant",
          "error_description": "Invalid Apple identity token"
        }
        """.data(using: .utf8)!

        XCTAssertThrowsError(try SupabaseIDTokenAuth.decodeSession(data: data, response: response)) { error in
            XCTAssertEqual(
                error as? SupabaseIDTokenAuthError,
                .requestFailed(statusCode: 400, message: "Invalid Apple identity token")
            )
        }
    }
}
