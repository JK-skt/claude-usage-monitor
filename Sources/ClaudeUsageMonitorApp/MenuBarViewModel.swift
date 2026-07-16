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
    @Published var refreshInterval: TimeInterval = 300 // 5 minutes default

    /// When true, the status menu shows every window (session, weekly, each model such
    /// as Fable) plus account/spend details at once. Persisted across launches.
    @Published var detailed: Bool {
        didSet { UserDefaults.standard.set(detailed, forKey: Self.detailedKey) }
    }

    private static let detailedKey = "menu.detailed"

    private let repository: UsageRepositoryProtocol
    private var pollTask: Task<Void, Never>?

    init(repository: UsageRepositoryProtocol = UsageRepository()) {
        self.repository = repository
        self.detailed = UserDefaults.standard.bool(forKey: Self.detailedKey)
        start()
    }

    func start() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.refresh()
                let interval = await MainActor.run { self.refreshInterval }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh() async {
        do {
            let snapshot = try await repository.currentUsage()
            state = .loaded(snapshot)
            lastUpdated = snapshot.capturedAt
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            // Keep showing the last good snapshot if we have one; only flip to
            // .failed when we've never loaded successfully.
            if case .loaded = state {
                // graceful degradation: retain data, note the error in lastUpdated tooltip
                return
            }
            state = .failed(message)
        }
    }

    deinit {
        pollTask?.cancel()
    }
}
