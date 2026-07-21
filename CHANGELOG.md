# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-07-21

### Added

- **Configurable main-usage window.** A new Settings picker ("Main usage") lets you pin
  the headline % (menu-bar label, hero gauge, trend) to a specific window — e.g. the
  5-hour session — instead of the default "most-consumed" auto behavior. `UsageSnapshot`
  gains `headlineMetric(pinnedID:)` / `percentRemaining(pinnedID:)` / `severity(pinnedID:)`;
  the pin is shared to the widget via the App Group so both surfaces agree.
- **Trend graph time range.** The in-menu sparkline now annotates the window it covers
  (`past 5h`), the sampling cadence (`~5m samples`), and start/end axis labels — switching
  to date labels for multi-day spans — so the x-axis unit (hourly vs daily) is explicit.
- **Automatic updates from GitHub Releases**, with change-summary notifications.
  - `UpdateChecker` (core): polls the pinned repo's latest release every 6 hours,
    compares semantically, and extracts the key changes from the release notes.
  - `UpdateManager` (app): a once-per-version notification listing the top changes, an
    in-menu banner (Update / Release notes / Skip), and optional auto-install.
  - Auto-install pipeline: download DMG → verify **sha256 digest + code signature** →
    mount → **atomic** in-place swap (rollback on failure) → relaunch. Installs are
    **refused without a trust anchor** (a published checksum, or a matching Developer-ID
    team when the running app has one); heavy I/O runs off the main actor.
  - CLI: `claude-monitor --check-update` (exit code 10 when an update is available).
- **About info** in the details section: app **version**, **license**, and a **source**
  link.

### Changed

- The headline gauge/label honor the pinned "Main usage" window when one is selected
  (auto/most-consumed remains the default).

### Security

- The auto-updater verifies each download's authenticity (GitHub-published sha256 and
  the staged bundle's code signature) before replacing the installed app, and refuses to
  install anything it cannot authenticate.

## [0.2.0] - 2026-07-20

### Added

- **Fable pay-as-you-go (metered) billing support.** Reflects the 2026-07 policy change
  where Fable is billed per token — **$10 / 1M input, $50 / 1M output** — instead of a
  session/weekly quota.
  - New `ModelPricing` type: the single source of truth for metered rates, with a
    `cost(inputTokens:outputTokens:)` calculator (computed in `Decimal` to avoid
    floating-point drift) returning an input/output `CostBreakdown`, plus a
    case-insensitive `forModel(_:)` registry.
  - Decodes the dollar-denominated fields already present in the `/api/oauth/usage`
    schema — `used_dollars` / `limit_dollars` / `remaining_dollars` on windows and the
    top-level `spend` object (minor-unit money → dollars) — so accrued Fable spend
    surfaces automatically once the server reports it.
  - `UsageMetric` gains `isMetered`, `pricing`, `usedDollars`, and `spendText`;
    `UsageSnapshot` gains `meteredMetrics` and `meteredSpend`.

### Changed

- Metered metrics are now shown as a **dollar amount** (`$X.XX spent` plus the per-token
  rate) rather than a quota bar, in both the CLI and the menu-bar app.
- Fable's row label is now `Fable (metered)` (was `Fable (weekly)`).
- The headline **"% remaining"** gauge now considers **quota metrics only** — metered
  metrics (Fable) have no quota and no longer distort the headline; their pressure is
  reported as spend via `meteredSpend`.

## [0.1.0] - 2026-07-16

### Added

- Initial release: verified data layer (Keychain OAuth → `/api/oauth/usage` →
  `UsageSnapshot`), SwiftUI `MenuBarExtra` app, and the `claude-monitor` CLI
  (`--json`, `--raw`, `--selftest`).
- `.app` bundle + generated icon + DMG packaging, and Launch-at-login via `SMAppService`.

[0.5.0]: https://github.com/JK-skt/claude-usage-monitor/compare/v0.4.0...v0.5.0
[0.2.0]: https://github.com/JK-skt/claude-usage-monitor/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/JK-skt/claude-usage-monitor/releases/tag/v0.1.0
