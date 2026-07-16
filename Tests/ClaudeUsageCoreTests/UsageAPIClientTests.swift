import Testing
import Foundation
@testable import ClaudeUsageCore

/// Stubs the network layer so the client is tested without a live token/endpoint.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var responder: (@Sendable (URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let responder = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = responder(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

@Suite("UsageAPIClient")
struct UsageAPIClientTests {

    @Test("200 → decodes windows and sends the Bearer + anthropic headers")
    func happyPath() async throws {
        let body = """
        { "five_hour": { "utilization": 42, "resets_at": "2026-07-16T22:00:00Z" },
          "seven_day": { "utilization": 10, "resets_at": "2026-07-23T00:00:00Z" } }
        """
        StubURLProtocol.responder = { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok-123")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") != nil)
            #expect(request.url?.path == "/api/oauth/usage")
            let resp = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["anthropic-ratelimit-unified-status": "allowed"])!
            return (resp, Data(body.utf8))
        }
        let client = UsageAPIClient(session: StubURLProtocol.session())
        let result = try await client.fetchUsage(accessToken: "tok-123")
        #expect(result.usage.fiveHour?.percentUsed == 42)
        #expect(result.headers.status == "allowed")
    }

    @Test("401 → APIError.unauthorized")
    func unauthorized() async {
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let client = UsageAPIClient(session: StubURLProtocol.session())
        await #expect(throws: APIError.self) {
            _ = try await client.fetchUsage(accessToken: "bad")
        }
    }

    @Test("429 → APIError.rateLimited with retry-after")
    func rateLimited() async throws {
        StubURLProtocol.responder = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                headerFields: ["retry-after": "30"])!, Data())
        }
        let client = UsageAPIClient(session: StubURLProtocol.session())
        do {
            _ = try await client.fetchUsage(accessToken: "x")
            Issue.record("expected throw")
        } catch let APIError.rateLimited(retryAfter) {
            #expect(retryAfter == 30)
        }
    }
}
