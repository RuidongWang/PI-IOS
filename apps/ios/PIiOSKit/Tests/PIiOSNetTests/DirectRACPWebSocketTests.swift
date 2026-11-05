import CryptoKit
import Foundation
import Security
import XCTest

@testable import PIiOSNet

final class DirectRACPWebSocketTests: XCTestCase {
    func testEndpointRequiresExactWSSV1PathWithoutCredentialsOrQuery() throws {
        let valid = try XCTUnwrap(URL(string: "wss://localhost:9443/v1/racp/ws"))
        XCTAssertEqual(try DirectRACPWebSocket.validatedEndpoint(valid), valid)
        let ipv6 = try XCTUnwrap(URL(string: "wss://[100:64::10]/v1/racp/ws"))
        XCTAssertEqual(try DirectRACPWebSocket.validatedEndpoint(ipv6), ipv6)

        let rejected = [
            "https://localhost/v1/racp/ws",
            "wss://user@localhost/v1/racp/ws",
            "wss://localhost/v1/racp/ws/",
            "wss://localhost/other",
            "wss://localhost/v1/racp/ws?token=secret",
            "wss://localhost/v1/racp/ws#fragment",
            "wss://localhost:0/v1/racp/ws",
        ]
        for raw in rejected {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try DirectRACPWebSocket.validatedEndpoint(url), raw) { error in
                XCTAssertEqual((error as? RACPConnectionError)?.category, .endpoint)
            }
        }
    }

    func testRequestUsesBearerAuthorizationAndV1SubprotocolWithoutURLToken() throws {
        let token = "pdt" + "2.example-token"
        let endpoint = try XCTUnwrap(URL(string: "wss://localhost:9443/v1/racp/ws"))
        let request = try DirectRACPWebSocket.authorizedRequest(endpoint: endpoint, bearerToken: token)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol"), "pi-racp.v1.jsonrpc")
        XCTAssertNil(request.url?.query)
        XCTAssertEqual(request.url?.path, "/v1/racp/ws")
    }

    func testOnlyExplicitProxyStatusesAreTransportFailures() {
        for status in [502, 503, 504] {
            XCTAssertEqual(DirectRACPWebSocket.connectionError(forHTTPStatus: status).category, .tcp)
        }
        for status in [200, 500, 501, 505] {
            XCTAssertEqual(DirectRACPWebSocket.connectionError(forHTTPStatus: status).category, .internal)
        }
        XCTAssertEqual(DirectRACPWebSocket.connectionError(forHTTPStatus: 401).category, .authentication)
        XCTAssertEqual(DirectRACPWebSocket.connectionError(forHTTPStatus: 404).category, .endpoint)
        XCTAssertEqual(DirectRACPWebSocket.connectionError(forHTTPStatus: 426).category, .endpoint)
    }

    func testCloseCodeAndReasonMappingIsStable() {
        XCTAssertEqual(RACPSocketTermination(closeCode: 1008, reason: "device revoked").category, .deviceRevoked)
        XCTAssertEqual(RACPSocketTermination(closeCode: 1008, reason: "rate limited").category, .rateLimited)
        XCTAssertEqual(RACPSocketTermination(closeCode: 1009, reason: "payload too large").category, .validation)
        XCTAssertEqual(RACPSocketTermination(closeCode: 1003, reason: "text only").category, .protocol)
        XCTAssertEqual(RACPSocketTermination(closeCode: 1006, reason: "").category, .socketInterrupted)
        XCTAssertEqual(RACPSocketTermination(closeCode: 1008, reason: "unrecognized private text").category, .protocol)
        XCTAssertEqual(RACPSocketTermination(closeCode: 1000, reason: "").category, .canceled)
    }

    func testClosePayloadParsesCodeAndUTF8Reason() {
        var payload = Data([0x03, 0xF0])
        payload.append(Data("device revoked".utf8))
        let termination = RACPSocketTermination(closePayload: payload)
        XCTAssertEqual(termination.closeCode, 1008)
        XCTAssertEqual(termination.reason, "device revoked")
        XCTAssertEqual(termination.category, .deviceRevoked)
        XCTAssertEqual(RACPSocketTermination(closePayload: Data()).closeCode, 1006)
        XCTAssertEqual(RACPSocketTermination(closePayload: Data([0x03, 0xF0, 0xFF])).category, .protocol)
    }

    func testActualSingleLeafDERPinAndAnchorOnlySSLTrustAcceptsDNSAndIP() throws {
        let certificate = try Self.leafCertificate()
        let der = SecCertificateCopyData(certificate) as Data
        let pin = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let date = try Self.verificationDate("2026-11-10T00:00:00Z")
        for host in ["localhost", "127.0.0.1", "100.64.0.10"] {
            let trust = try Self.makeTrust(certificates: [certificate], host: host)
            XCTAssertNoThrow(try DirectTLSTrustEvaluator.evaluate(
                trust: trust,
                endpointHost: host,
                expectedCertificateSHA256: pin,
                verifyDate: date
            ), host)
        }
    }

    func testTLSTrustRejectsPinMismatchBeforeTrustAndRejectsWrongSAN() throws {
        let certificate = try Self.leafCertificate()
        let der = SecCertificateCopyData(certificate) as Data
        let pin = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let date = try Self.verificationDate("2026-11-10T00:00:00Z")
        let mismatchTrust = try Self.makeTrust(certificates: [certificate], host: "localhost")
        XCTAssertThrowsError(try DirectTLSTrustEvaluator.evaluate(
            trust: mismatchTrust,
            endpointHost: "localhost",
            expectedCertificateSHA256: String(repeating: "0", count: 64),
            verifyDate: date
        )) { XCTAssertEqual(($0 as? RACPConnectionError)?.category, .tlsTrust) }

        let sanTrust = try Self.makeTrust(certificates: [certificate], host: "wrong.example")
        XCTAssertThrowsError(try DirectTLSTrustEvaluator.evaluate(
            trust: sanTrust,
            endpointHost: "wrong.example",
            expectedCertificateSHA256: pin,
            verifyDate: date
        )) { XCTAssertEqual(($0 as? RACPConnectionError)?.category, .tlsTrust) }
    }

    func testTLSTrustRejectsCertificateChainCAAndInvalidValidityWindow() throws {
        let certificate = try Self.leafCertificate()
        let der = SecCertificateCopyData(certificate) as Data
        let pin = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
        let validDate = try Self.verificationDate("2026-11-10T00:00:00Z")

        let ca = try Self.caCertificate()
        let chainLeaf = try Self.certificate(named: "direct-chain-leaf")
        let chainLeafDER = SecCertificateCopyData(chainLeaf) as Data
        let chainLeafPin = SHA256.hash(data: chainLeafDER).map { String(format: "%02x", $0) }.joined()
        let chain = try Self.makeTrust(certificates: [chainLeaf, ca], host: "localhost")
        XCTAssertEqual(SecTrustSetAnchorCertificates(chain, [ca] as CFArray), errSecSuccess)
        XCTAssertEqual(SecTrustSetAnchorCertificatesOnly(chain, true), errSecSuccess)
        XCTAssertEqual(SecTrustSetVerifyDate(chain, validDate as CFDate), errSecSuccess)
        var chainError: CFError?
        _ = SecTrustEvaluateWithError(chain, &chainError)
        XCTAssertEqual(SecTrustGetCertificateCount(chain), 2, "fixture 必须形成真实叶+CA链")
        XCTAssertThrowsError(try DirectTLSTrustEvaluator.evaluate(
            trust: chain, endpointHost: "localhost", expectedCertificateSHA256: chainLeafPin, verifyDate: validDate
        ))

        let caDER = SecCertificateCopyData(ca) as Data
        let caPin = SHA256.hash(data: caDER).map { String(format: "%02x", $0) }.joined()
        let caTrust = try Self.makeTrust(certificates: [ca], host: "localhost")
        XCTAssertThrowsError(try DirectTLSTrustEvaluator.evaluate(
            trust: caTrust, endpointHost: "localhost", expectedCertificateSHA256: caPin, verifyDate: validDate
        ))

        for rawDate in ["2026-11-01T00:00:00Z", "2027-01-01T00:00:00Z"] {
            let trust = try Self.makeTrust(certificates: [certificate], host: "localhost")
            XCTAssertThrowsError(try DirectTLSTrustEvaluator.evaluate(
                trust: trust,
                endpointHost: "localhost",
                expectedCertificateSHA256: pin,
                verifyDate: try Self.verificationDate(rawDate)
            ), rawDate)
        }
    }

    func testEveryHTTPRedirectIsRejected() throws {
        let delegate = DirectRACPSessionDelegate(
            endpointHost: "localhost",
            expectedCertificateSHA256: String(repeating: "0", count: 64)
        )
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: try XCTUnwrap(URL(string: "https://localhost/start")))
        let response = try XCTUnwrap(HTTPURLResponse(
            url: try XCTUnwrap(URL(string: "https://localhost/start")),
            statusCode: 302,
            httpVersion: nil,
            headerFields: ["Location": "https://other.example/steal"]
        ))
        let redirected = URLRequest(url: try XCTUnwrap(URL(string: "https://other.example/steal")))
        var callbackCalled = false
        var forwarded: URLRequest? = redirected
        delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: redirected) {
            callbackCalled = true
            forwarded = $0
        }
        XCTAssertTrue(callbackCalled)
        XCTAssertNil(forwarded)
    }

    private static func verificationDate(_ raw: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try XCTUnwrap(formatter.date(from: raw))
    }

    private static func makeTrust(certificates: [SecCertificate], host: String) throws -> SecTrust {
        var trust: SecTrust?
        let status = SecTrustCreateWithCertificates(
            certificates as CFArray,
            SecPolicyCreateSSL(true, host as CFString),
            &trust
        )
        XCTAssertEqual(status, errSecSuccess)
        return try XCTUnwrap(trust)
    }

    private static func leafCertificate() throws -> SecCertificate {
        try certificate(named: "direct-leaf")
    }

    private static func caCertificate() throws -> SecCertificate {
        try certificate(named: "direct-ca")
    }

    private static func certificate(named name: String) throws -> SecCertificate {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "der", subdirectory: "Fixtures")
                ?? Bundle.module.url(forResource: name, withExtension: "der")
        )
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(SecCertificateCreateWithData(nil, data as CFData))
    }
}
