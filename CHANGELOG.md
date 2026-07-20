# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.2.0]: https://github.com/JK-skt/claude-usage-monitor/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/JK-skt/claude-usage-monitor/releases/tag/v0.1.0
