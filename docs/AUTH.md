# Authentication & Usage Data — Reverse-Engineering Notes

> Findings verified on macOS 26.5, Claude Code 2.1.121, Claude Desktop (Electron).
> Everything here is derived from the **local machine's own** installed clients for
> interoperability. No credentials are transmitted anywhere; all reads are local.

## Data sources

| What | Where | Secret? | Used by this app |
|------|-------|:-------:|:----------------:|
| OAuth tokens (Claude Code) | Keychain generic-password `Claude Code-credentials`, account = macOS user | **yes** | ✅ primary |
| OAuth tokens (Claude Desktop) | `~/Library/Application Support/Claude/config.json` → `oauth:tokenCacheV2`, AES-encrypted via Keychain key `Claude Safe Storage` (Electron `safeStorage`) | **yes** | fallback (planned) |
| Account/plan metadata | `~/.claude.json` → `oauthAccount` | no | ✅ enrichment |

### Keychain item (primary)

```
kSecClass       = kSecClassGenericPassword
kSecAttrService = "Claude Code-credentials"
kSecAttrAccount = <macOS short username>
```

Secret payload (JSON):

```json
{ "claudeAiOauth": {
    "accessToken":  "…",
    "refreshToken": "…",
    "expiresAt":    1777385989340,          // epoch MILLISECONDS
    "scopes":       ["user:inference", "user:profile"],
    "subscriptionType": "max"
} }
```

Modeled by [`OAuthCredentials`](../Sources/ClaudeUsageCore/Auth/OAuthCredentials.swift).

#### Keychain authorization (important UX constraint)

The item's ACL is owned by Claude Code. Reading the **secret** from any other binary
triggers a one-time macOS *"Allow / Always Allow"* dialog. Reading only the
**attributes** does not. Consequences:

- The GUI app reads on a background queue; the user clicks **Always Allow** once.
- `kSecUseAuthenticationUIFail` does **not** suppress this classic ACL dialog (it only
  governs biometric/`LAContext` UI). Therefore `KeychainCredentialStore` time-bounds
  the blocking call (`CredentialError.timedOut`) so headless callers never wedge.
- After a one-time grant, even `claude-monitor --no-ui` reads silently.

### `~/.claude.json` → `oauthAccount` (no secrets)

Relevant keys: `organizationType` (`claude_max` → plan), `organizationRateLimitTier`
(`default_claude_max_20x` → the "20×" multiplier), `organizationUuid`, `accountUuid`,
`billingType`, `displayName`, `organizationName`. Modeled by
[`AccountInfo`](../Sources/ClaudeUsageCore/Models/AccountInfo.swift).

## Live usage endpoint

Extracted from the Claude Code 2.1.121 binary (`strings`):

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <accessToken>
anthropic-version: 2023-06-01
anthropic-beta: oauth-2025-04-20
```

Response body (reverse-engineered field set — decoded defensively):

```json
{
  "five_hour":      { "utilization": 0.42, "remaining": …, "resets_at": "…Z" },
  "seven_day":      { "utilization": 0.10, "remaining": …, "resets_at": "…Z" },
  "seven_day_opus": { "utilization": 0.88, "remaining": …, "resets_at": "…Z" },
  "overage":        { "status": "disabled", "resets_at": null }
}
```

`utilization` is a fraction (`0…1`); the code also tolerates a `0…100` form.

### Fallback: response headers

Every authenticated API response also carries:

```
anthropic-ratelimit-unified-status
anthropic-ratelimit-unified-remaining
anthropic-ratelimit-unified-reset
anthropic-ratelimit-unified-overage-status / -overage-reset
```

Captured by `UnifiedRateLimitHeaders` as a schema-drift safety net.

## Assumptions & risks

- **Undocumented endpoint.** `/api/oauth/usage` is not a public/stable API. Schema may
  change; all decoding is optional-tolerant, and the header fallback exists.
- **Token refresh** (when `expiresAt` passes) is not yet implemented — the app surfaces
  `APIError.unauthorized` and asks the user to run `claude` once. The OAuth refresh flow
  (token endpoint + Claude Code public client id) is the next auth task.
- **No credential is ever written or transmitted.** The token is read, used for the
  single GET to `api.anthropic.com`, and never persisted by this app.

## Related endpoints seen in the binary (not yet used)

`/api/oauth/profile`, `/api/oauth/organizations/{uuid}`, `/api/oauth/account/settings`,
`/api/claude_code/policy_limits`.
