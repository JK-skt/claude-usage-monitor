import SwiftUI
import AppKit
import ClaudeUsageCore

/// Which tab the menu is showing. Tabs replace the old accordions so the popover keeps a
/// stable height instead of growing as sections expand (handoff §00).
enum MenuTab: String, CaseIterable {
    case overview = "Overview", analytics = "Analytics", settings = "Settings"
}

/// The menu-bar popover: header → update banner → tab bar → tab body → footer.
/// The popover sizes itself to whichever tab is showing — nothing is clipped and nothing
/// scrolls; the height simply follows the content.
struct MenuContentView: View {
    @ObservedObject var model: MenuBarViewModel
    @ObservedObject var updates: UpdateManager
    @StateObject private var loginItem = LoginItemManager()
    @State private var tab: MenuTab

    init(model: MenuBarViewModel, updates: UpdateManager, initialTab: MenuTab = .overview) {
        self.model = model
        self.updates = updates
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            updateBanner
            tabBar

            Group {
                switch tab {
                case .overview:  overviewBody
                case .analytics: AnalyticsTab(model: model)
                case .settings:  SettingsTab(model: model, updates: updates, loginItem: loginItem)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)

            Divider()
            footer
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            model.refreshIfStale()
            loginItem.refresh()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("Claude Usage").font(.system(size: 13, weight: .bold))

            if case .loaded(let s) = model.state {
                Text(s.planName)
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: Capsule())
                    .foregroundStyle(Color.orange)
            }

            Spacer(minLength: 4)

            if let updated = model.lastUpdated, !model.isRefreshing {
                Text(agoText(updated))
                    .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
            }
            Button {
                Task { await model.refresh() }
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.10))
                    if model.isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 10))
                    }
                }
                .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help("Refresh now")
        }
    }

    // MARK: Update banner — one line

    @ViewBuilder
    private var updateBanner: some View {
        if let r = updates.available {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 11)).foregroundStyle(Color.blue)
                Text("\(r.version) available").font(.system(size: 11)).lineLimit(1)

                if updates.isInstalling {
                    Spacer(minLength: 4)
                    if let status = updates.installStatus {
                        Text(status).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ProgressView().controlSize(.mini)
                } else {
                    Button("notes") {
                        if let url = r.htmlURL { NSWorkspace.shared.open(url) }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10)).foregroundStyle(Color.blue)

                    Spacer(minLength: 4)

                    Button {
                        Task { await updates.install(r) }
                    } label: {
                        Text("Update")
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 9).padding(.vertical, 2)
                            .background(Color.blue, in: RoundedRectangle(cornerRadius: 5))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button { updates.skip(r) } label: {
                        Image(systemName: "xmark").font(.system(size: 9))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 7))
        }
    }

    // MARK: Tab bar

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(MenuTab.allCases, id: \.self) { t in
                Text(t.rawValue)
                    .font(.system(size: 11, weight: tab == t ? .semibold : .regular))
                    .foregroundStyle(tab == t ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(tab == t ? Color.primary.opacity(0.14) : .clear,
                                in: RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { tab = t }
            }
        }
        .padding(2)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Overview body (state-dependent)

    @ViewBuilder
    private var overviewBody: some View {
        switch model.state {
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading usage…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 8)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                Label("Couldn't load usage", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .loaded(let snapshot):
            OverviewTab(model: model, snapshot: snapshot)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            footerButton("Refresh", "arrow.clockwise") { Task { await model.refresh() } }
            footerButton("Copy report", "doc.on.doc") { copyUsage() }
            Button { open("https://claude.ai") } label: {
                Text("claude.ai ↗").font(.system(size: 10.5)).foregroundStyle(Color.blue)
            }
            .buttonStyle(.plain)

            Spacer()

            Button { NSApp.terminate(nil) } label: {
                Text("Quit").font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .onAppear { loginItem.refresh() }
    }

    private func footerButton(_ title: String, _ icon: String,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title).font(.system(size: 10.5))
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Helpers

    private func agoText(_ date: Date) -> String {
        let secs = Int(Date().timeIntervalSince(date))
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(secs / 60)m ago" }
        return "\(secs / 3600)h ago"
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyUsage() {
        guard case .loaded(let s) = model.state else { return }
        var lines = ["Plan: \(s.planName)",
                     "Remaining: \(s.percentRemaining(pinnedID: model.headlineMetricID))%"]
        for m in s.metrics {
            if m.isMetered {
                lines.append("\(m.label): \(m.spendText ?? "$0.00") spent")
            } else {
                lines.append("\(m.label): \(m.percentUsed)% used")
            }
        }
        if let spend = s.meteredSpend {
            lines.append("Metered spend: \(ModelPricing.formatUSD(spend))")
        }
        lines.append("Next reset: \(Formatting.absolute(s.nextReset))")
        lines.append("Captured: \(Formatting.absolute(s.capturedAt))")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}
