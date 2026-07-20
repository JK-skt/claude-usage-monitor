import Foundation

/// Shared filesystem locations for the app + CLI.
public enum AppPaths {
    /// `~/Library/Application Support/ClaudeUsageMonitor`
    public static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("ClaudeUsageMonitor", isDirectory: true)
    }

    public static var historyFile: URL {
        supportDirectory.appendingPathComponent("history.jsonl")
    }

    @discardableResult
    public static func ensureSupportDirectory() -> URL {
        let dir = supportDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

/// Append-only JSONL history of usage samples. Portable and dependency-free (readable by
/// the app, CLI, exporters, and tests alike) — the app can additionally mirror into
/// SwiftData for on-device charting, but this is the source of truth.
public actor UsageHistoryStore {
    private let fileURL: URL
    /// Hard cap on retained lines; the oldest are dropped on append past this.
    private let maxRecords: Int

    public init(fileURL: URL? = nil, maxRecords: Int = 20_000) {
        self.fileURL = fileURL ?? AppPaths.historyFile
        self.maxRecords = maxRecords
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Appends one record as a JSON line. Best-effort pruning keeps the file bounded.
    public func append(_ record: UsageRecord) throws {
        AppPaths.ensureSupportDirectory()
        let line = try Self.encoder.encode(record)
        var blob = line
        blob.append(0x0A) // newline

        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: blob)
        } else {
            try blob.write(to: fileURL, options: .atomic)
        }

        try pruneIfNeeded()
    }

    /// Convenience: derive and append a record from a live snapshot.
    public func record(_ snapshot: UsageSnapshot) throws {
        try append(UsageRecord(from: snapshot))
    }

    /// Loads records, optionally only those at/after `since`, newest-last. `limit` keeps
    /// the most recent N.
    public func load(since: Date? = nil, limit: Int? = nil) throws -> [UsageRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        var records: [UsageRecord] = []
        records.reserveCapacity(1024)
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let rec = try? Self.decoder.decode(UsageRecord.self, from: Data(line)) {
                if let since, rec.timestamp < since { continue }
                records.append(rec)
            }
        }
        records.sort { $0.timestamp < $1.timestamp }
        if let limit, records.count > limit {
            records = Array(records.suffix(limit))
        }
        return records
    }

    public func clear() throws {
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func pruneIfNeeded() throws {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count > maxRecords else { return }
        let kept = lines.suffix(maxRecords)
        var out = Data()
        for line in kept { out.append(contentsOf: line); out.append(0x0A) }
        try out.write(to: fileURL, options: .atomic)
    }
}
