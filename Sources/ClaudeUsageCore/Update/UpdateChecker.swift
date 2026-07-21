import Foundation

/// The app's own version, read from the bundle's Info.plist. Falls back to "0.0.0"
/// for unbundled dev runs (`swift run`), which callers should treat as "don't
/// auto-install" (see `AppVersion.isBundledApp`).
public enum AppVersion {
    /// Compile-time version, kept in sync with the repo-root `VERSION` file (the release
    /// pipeline's single source of truth). Used as the fallback for the bare CLI binary,
    /// which has no Info.plist — without it, version comparison would read "0.0.0" and
    /// treat *every* release as newer.
    public static let packaged = "0.4.0"

    /// This build's version: the bundle's `CFBundleShortVersionString` when running as a
    /// `.app`, otherwise the compiled `packaged` value.
    public static var current: String {
        if let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
           v != "0.0.0", !v.isEmpty {
            return v
        }
        return packaged
    }

    /// True when running from a real `.app` bundle (vs. a bare SPM binary). In-place
    /// replacement + relaunch only makes sense for a bundled app.
    public static var isBundledApp: Bool {
        Bundle.main.bundlePath.hasSuffix(".app")
    }
}

/// Dot-separated numeric version comparison ("0.10.2" > "0.9.9"). Non-numeric
/// suffixes are ignored component-wise ("1.2.3-beta" compares as 1.2.3).
public enum SemanticVersion {
    public static func parse(_ s: String) -> [Int] {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "vV \n"))
            .split(separator: ".")
            .map { part in Int(part.prefix(while: { $0.isNumber })) ?? 0 }
    }

    /// True when `candidate` is strictly newer than `current`.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parse(candidate), b = parse(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

/// A GitHub release, decoded from `GET /repos/{owner}/{repo}/releases/latest`.
public struct ReleaseInfo: Codable, Sendable, Hashable {
    public let tagName: String
    /// Release title, e.g. "v0.4.0 — Widget, tokens, prediction, Prometheus".
    public let name: String?
    /// Markdown release notes.
    public let body: String?
    public let htmlURL: URL?
    public let publishedAt: Date?
    public let assets: [Asset]

    public struct Asset: Codable, Sendable, Hashable {
        public let name: String
        public let size: Int?
        public let browserDownloadURL: URL
        public let contentType: String?
        /// GitHub-provided content digest ("sha256:<hex>"), when present.
        public let digest: String?

        enum CodingKeys: String, CodingKey {
            case name, size, digest
            case browserDownloadURL = "browser_download_url"
            case contentType = "content_type"
        }

        public init(name: String, size: Int?, browserDownloadURL: URL,
                    contentType: String?, digest: String? = nil) {
            self.name = name
            self.size = size
            self.browserDownloadURL = browserDownloadURL
            self.contentType = contentType
            self.digest = digest
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, body, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case publishedAt = "published_at"
    }

    public init(tagName: String, name: String?, body: String?, htmlURL: URL?,
                publishedAt: Date?, assets: [Asset] = []) {
        self.tagName = tagName
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    /// "v0.4.0" → "0.4.0".
    public var version: String {
        tagName.hasPrefix("v") || tagName.hasPrefix("V")
            ? String(tagName.dropFirst()) : tagName
    }

    /// The installable DMG for this release, if one was published.
    public var dmgAsset: Asset? {
        assets.first { $0.name.lowercased().hasSuffix(".dmg") }
    }

    /// Key changes pulled from the markdown body: the first `max` top-level bullet
    /// lines, with markdown emphasis/links stripped — suitable for a notification body
    /// or a compact "what's new" list.
    public func highlights(max count: Int = 4) -> [String] {
        guard let body else { return [] }
        var out: [String] = []
        // Split on any newline so CRLF release bodies (GitHub often serves \r\n) work.
        for rawLine in body.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("- ") || line.hasPrefix("* ") else { continue }
            let text = Self.stripMarkdown(String(line.dropFirst(2)))
            if !text.isEmpty { out.append(text) }
            if out.count >= count { break }
        }
        return out
    }

    /// Removes the markdown syntax that reads poorly in plain text: emphasis markers,
    /// inline code ticks, and `[title](url)` links (kept as just the title).
    static func stripMarkdown(_ s: String) -> String {
        var t = s
        // [text](url) → text
        while let open = t.range(of: "["), let mid = t.range(of: "](", range: open.upperBound..<t.endIndex),
              let close = t.range(of: ")", range: mid.upperBound..<t.endIndex) {
            let text = String(t[open.upperBound..<mid.lowerBound])
            t.replaceSubrange(open.lowerBound..<close.upperBound, with: text)
        }
        for token in ["**", "__", "`", "*"] {
            t = t.replacingOccurrences(of: token, with: "")
        }
        return t.trimmingCharacters(in: .whitespaces)
    }
}

/// Checks GitHub Releases for a newer version of this app.
///
/// Talks only to the pinned repository over HTTPS (`api.github.com`), unauthenticated
/// (public repo; 60 req/h is far above our 6-hourly cadence). Callers decide what to do
/// with the result — the checker itself never installs anything.
public actor UpdateChecker {
    public static let defaultRepo = "JK-skt/claude-usage-monitor"

    private let repo: String
    private let session: URLSession

    public init(repo: String = UpdateChecker.defaultRepo, session: URLSession = .shared) {
        self.repo = repo
        self.session = session
    }

    public enum UpdateError: LocalizedError {
        case badResponse(Int)
        case decoding(String)

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code): return "GitHub API returned HTTP \(code)."
            case .decoding(let detail):  return "Couldn't read the release feed: \(detail)"
            }
        }
    }

    /// The latest published (non-draft, non-prerelease) release.
    public func latestRelease() async throws -> ReleaseInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageMonitor-UpdateChecker", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.badResponse(http.statusCode)
        }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(ReleaseInfo.self, from: data)
        } catch {
            throw UpdateError.decoding("\(error)")
        }
    }

    /// Convenience: the latest release only if it is strictly newer than `currentVersion`.
    public func availableUpdate(currentVersion: String) async throws -> ReleaseInfo? {
        let latest = try await latestRelease()
        return SemanticVersion.isNewer(latest.version, than: currentVersion) ? latest : nil
    }
}
