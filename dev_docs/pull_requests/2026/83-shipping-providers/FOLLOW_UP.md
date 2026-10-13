# PR #83 follow-up

How each finding was resolved.

| Finding | Source | Resolution |
|---|---|---|
| Tuple `service_error` crashes the picker | Claude | Fixed (`CartQuote.error_reason/1`) |
| Credentials in crash reasons | Claude | Fixed, then widened after Codex (below) |
| Cached quote outlives `expires_at` | Claude | Fixed (`Cache` `clamp_ttl:`) |
| Provider lists not type-checked | Claude | Fixed |
| Shopper-driven quotes unthrottled; picker events without a service | Claude | Fixed (per-picker throttle, service guards); no global quote budget |
| Admin locality pick by index; small nitpicks | Claude | Fixed |
| Credentials via malformed return and escaped values | Codex, BUG - HIGH | Fixed: shape-only `bad_return`, escaped and short values redacted, redacted log |
| Wrong carrier's quote after a provider switch | Codex, BUG - HIGH | Fixed: stored quote and in-flight persist bound to the provider; entries without it are stale |
| JPY double rounding | Codex, BUG - MEDIUM | Fixed: `Pricing.final_amount/5` rounds once; tests for JPY and cents |
| Changelog omits the feature | Codex, IMPROVEMENT - MEDIUM | Fixed: `Added` entries |
| Carrier lookups under the cart lock; fallback on unclassified errors; no global quote budget; uncached service timeouts | Both | Not changed: design follow-ups, recorded in `CLAUDE_REVIEW.md` |
