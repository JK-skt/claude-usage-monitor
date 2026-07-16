import Foundation

public enum APIError: Error, LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, body: String)
    case transport(Error)
    case decoding(Error)
    case offline

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "Authentication expired or rejected (401). The token may need to be refreshed."
        case .rateLimited(let retry):
            let s = retry.map { " Retry after \(Int($0))s." } ?? ""
            return "Rate limited by the usage endpoint (429).\(s)"
        case .http(let status, _):
            return "Usage endpoint returned HTTP \(status)."
        case .transport(let error):
            return "Network error: \(error.localizedDescription)"
        case .decoding:
            return "Could not decode the usage response (schema may have changed)."
        case .offline:
            return "No network connection."
        }
    }
}

/// The reverse-engineered `anthropic-ratelimit-unified-*` headers, captured as a
/// fallback data source when the JSON body schema drifts.
public struct UnifiedRateLimitHeaders: Sendable, Equatable {
    public var status: String?
    public var remaining: Double?
    public var reset: Date?

    public var isEmpty: Bool { status == nil && remaining == nil && reset == nil }
}

/// Client for `GET https://api.anthropic.com/api/oauth/usage`.
///
/// Auth: `Authorization: Bearer <accessToken>` plus the headers Claude Code sends so
/// the request is indistinguishable from the official client.
public actor UsageAPIClient {
    public static let defaultBaseURL = URL(string: "https://api.anthropic.com")!
    /// Anthropic API version pinned by Claude Code. Overridable if it changes.
    public static let anthropicVersion = "2023-06-01"

    private let baseURL: URL
    private let session: URLSession
    private let betaHeader: String

    public init(
        baseURL: URL = UsageAPIClient.defaultBaseURL,
        session: URLSession = .shared,
        betaHeader: String = "oauth-2025-04-20"
    ) {
        self.baseURL = baseURL
        self.session = session
        self.betaHeader = betaHeader
    }

    /// Parses either a numeric epoch (seconds or milliseconds) or an ISO-8601 string,
    /// with or without fractional seconds. Free function so the `@Sendable` decoding
    /// closure captures nothing non-Sendable.
    nonisolated static func parseFlexibleDate(_ container: SingleValueDecodingContainer) throws -> Date {
        if let num = try? container.decode(Double.self) {
            return Date(timeIntervalSince1970: num > 1_000_000_000_000 ? num / 1000 : num)
        }
        let s = try container.decode(String.self)
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = withFraction.date(from: s) ?? plain.date(from: s) { return date }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Bad date: \(s)")
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            try parseFlexibleDate(try d.singleValueContainer())
        }
        return decoder
    }

    public struct Result: Sendable {
        public let usage: UsageResponse
        public let headers: UnifiedRateLimitHeaders
    }

    /// Returns the undecoded response body — for diagnostics / schema discovery.
    public func fetchRawUsage(accessToken: String) async throws -> Data {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/oauth/usage"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        let (data, _) = try await session.data(for: request)
        return data
    }

    public func fetchUsage(accessToken: String) async throws -> Result {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/oauth/usage"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            throw APIError.offline
        } catch {
            throw APIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw APIError.http(status: -1, body: "")
        }

        switch http.statusCode {
        case 200..<300:
            let headers = Self.parseHeaders(http)
            do {
                let usage = try Self.makeDecoder().decode(UsageResponse.self, from: data)
                return Result(usage: usage, headers: headers)
            } catch {
                throw APIError.decoding(error)
            }
        case 401, 403:
            throw APIError.unauthorized
        case 429:
            let retry = (http.value(forHTTPHeaderField: "retry-after")).flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retry)
        default:
            throw APIError.http(status: http.statusCode,
                                body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    static func parseHeaders(_ http: HTTPURLResponse) -> UnifiedRateLimitHeaders {
        func header(_ name: String) -> String? {
            http.value(forHTTPHeaderField: name)
        }
        var out = UnifiedRateLimitHeaders()
        out.status = header("anthropic-ratelimit-unified-status")
        out.remaining = header("anthropic-ratelimit-unified-remaining").flatMap(Double.init)
        if let reset = header("anthropic-ratelimit-unified-reset") {
            if let epoch = Double(reset) {
                out.reset = Date(timeIntervalSince1970: epoch)
            } else {
                out.reset = ISO8601DateFormatter().date(from: reset)
            }
        }
        return out
    }
}
