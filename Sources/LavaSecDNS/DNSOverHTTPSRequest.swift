import Foundation
import LavaSecKit

public enum DNSOverHTTPSRequest {
    public enum Error: Swift.Error, Equatable, Sendable {
        case nonHTTPResponse
        case httpStatus(Int)
        case invalidContentType(String?)
        case emptyBody
        case malformedDNSResponse
    }

    public static func makePOSTRequest(
        endpoint: URL,
        query: Data,
        timeoutSeconds: TimeInterval
    ) -> URLRequest {
        var request = URLRequest(
            url: endpoint,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: timeoutSeconds
        )
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.httpBody = DNSWireMessage.clearingTransactionID(in: query)
        // Prefer DoH3: try HTTP/3 without waiting for Alt-Svc discovery. The
        // loader falls back to H2/H1 natively, so this never makes a resolver
        // unreachable that wasn't already.
        request.assumesHTTP3Capable = true
        return request
    }

    public static func validatedDNSResponse(
        body: Data,
        response: URLResponse,
        originalQuery: Data
    ) throws -> Data {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw Error.nonHTTPResponse
        }

        guard 200..<300 ~= httpResponse.statusCode else {
            throw Error.httpStatus(httpResponse.statusCode)
        }

        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type")
        let mediaType = contentType?
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard mediaType == "application/dns-message" else {
            throw Error.invalidContentType(contentType)
        }

        guard !body.isEmpty else {
            throw Error.emptyBody
        }

        guard body.count >= 12 else {
            throw Error.malformedDNSResponse
        }

        try validateDNSResponse(body, matches: originalQuery)

        return DNSWireMessage.replacingTransactionID(in: body, from: originalQuery)
    }

    private static func validateDNSResponse(_ response: Data, matches query: Data) throws {
        guard DNSWireMessage.isValidResponse(
            response,
            matching: query,
            requiresMatchingTransactionID: false
        )
        else {
            throw Error.malformedDNSResponse
        }
    }
}
