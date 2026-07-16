import Foundation
import SwiftUI
import ClaudeUsageCore

@MainActor
final class MenuBarViewModel: ObservableObject {
    enum State {
        case loading
        case loaded(UsageSnapshot)
        case failed(String)
    }

    @Published private(set) var state: State = .loading
    @Published private(set) var lastUpdated: Date?
    /// Non-nil when the most recent refresh failed. Retained even while stale data is
    /// still shown, so the UI can flag "showing last known values".
    @Published private(set) var lastError: String?
    /// True while a fetch is in flight (drives the header spinner; prevents overlap).
    @Published private(set) var isRefreshing = false

    /// Poll cadence in seconds. Persisted; changing it re-arms the poller immediately.
    @Published var refreshInterval: TimeInterval {
        didSet {
            guard refreshInterval != oldValue else { return }
            UserDefaults.standard.set(refreshInterval, forKey: Self.intervalKey)
            start()
        }
    }

    /// When true, the status menu shows every window plus account/spend details at once.
    @Published var detailed: Bool {
        didSet { UserDefaults.standard.set(detailed, forKey: Self.detailedKey) }
    }

    private static let intervalKey = "refresh.interval"
    private static let detailedKey = "menu.detailed"

    private let repository: UsageRepositoryProtocol
    private var pollTask: Task<Void, Never>?
    private var consecutiveFailures = 0
    private var retryAfterHint: TimeInterval?

    init(repository: UsageRepositoryProtocol = UsageRepository()) {
        self.repository = repository
        self.detailed = UserDefaults.standard.bool(forKey: Self.detailedKey)
        let saved = UserDefaults.standard.double(forKey: Self.intervalKey)
        self.refreshInterval = saved > 0 ? saved : 300 // 5 minutes default
        start()
    }

    /// (Re)starts the background poll loop with adaptive spacing.
    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let delay = self.nextDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Refresh only if the data is missing or older than the poll interval — used when
    /// the menu opens so the user sees current numbers without extra background traffic.
    func refreshIfStale() {
        let threshold = min(refreshInterval, 60)
        let stale = lastUpdated.map { Date().timeIntervalSince($0) > threshold } ?? true
        if stale { Task { await refresh() } }
    }

    func refresh() async {
        guard !isRefreshing else { return } // collapse overlapping requests
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let snapshot = try await repository.currentUsage()
            state = .loaded(snapshot)
            lastUpdated = snapshot.capturedAt
            lastError = nil
            consecutiveFailures = 0
            retryAfterHint = nil
        } catch {
            consecutiveFailures += 1
            if case .rateLimited(let retryAfter) = error as? APIError {
                retryAfterHint = retryAfter
            }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            lastError = message
            // Graceful degradation: keep the last good snapshot on screen; only show the
            // full error state when we have never loaded successfully.
            if case .loaded = state { /* retain stale data */ } else {
                state = .failed(message)
            }
        }
    }

    /// Adaptive delay: honor a server `Retry-After`, otherwise exponential backoff on
    /// consecutive failures (capped at 30 min), with ±10% jitter to avoid lockstep.
    private func nextDelay() -> TimeInterval {
        let base: TimeInterval
        if consecutiveFailures == 0 {
            base = refreshInterval
        } else if let hint = retryAfterHint {
            base = max(refreshInterval, hint)
        } else {
            let factor = pow(2.0, Double(min(consecutiveFailures, 5)))
            base = min(refreshInterval * factor, 1800)
        }
        let jitter = base * Double.random(in: -0.1...0.1)
        return max(5, base + jitter)
    }

    deinit {
        pollTask?.cancel()
    }
}
