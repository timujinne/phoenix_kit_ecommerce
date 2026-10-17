# Follow-up — PR #93

| Finding | Severity | Resolution |
|---|---|---|
| Category delete never reindexed its products | BUG - MEDIUM | `Subscriber` rebuilds on `:category_deleted`; test added. |
| Base-currency change left old-base prices in the index | BUG - MEDIUM | `Subscriber` subscribes to `{:currencies_changed, _}` and rebuilds; test added. |
| Image downloader kept Req's default retry (uncapped `Retry-After`) | BUG - MEDIUM | `retry: false`. |
| `WarehouseSourceKind` queried the catalogue table without the schema prefix | BUG - MEDIUM | Prefix from `:phoenix_kit, :prefix`. |
| `list_item` output schema required fields `fields` can drop | BUG - MEDIUM | Only `id` required. |
| Merged assistant carts never pruned | IMPROVEMENT - MEDIUM | Prune covers `merged`; test added. |
| `set_prices` accepted a price with no currency anywhere | IMPROVEMENT - MEDIUM | Row refused; tests added. |
| `set_availability` wrote without the item lock / re-plan | IMPROVEMENT - MEDIUM | `write_if_unchanged/4` with its planner. |
| Cart settings form: no audit row / stale form on a partial write | IMPROVEMENT - LOW | Each stored value audited; form reassigned. |
| V4 / V5 SQL not digest-pinned | IMPROVEMENT - MEDIUM | Digests added (V4, V5 claims table). |
| Doc drift (danger functions, cache clearers, claim page revision) | NITPICK | Fixed in AGENTS.md and moduledocs. |
| Claim merge 99-per-line cap | NITPICK | Left: two tests pin it as intended. |
| Everything else in "Not changed, on record" | see review | Left for the maintainer; reasons in `CLAUDE_REVIEW.md`. |

## Codex second pass

See `CODEX_REVIEW.md` for evidence and validation.

| Finding | Severity | Resolution |
|---|---|---|
| Write tools bypass the catalogue editor's extra permission | BUG - HIGH | All four registered write handlers check the key owner's live catalogue access, including dry runs and confirmed calls; real executor tests cover denial and revocation. |
| A slow origin can renew the image receive timeout indefinitely | BUG - MEDIUM | One monotonic response deadline; a loopback test trickles bytes to verify expiry and connection closure. |
| Non-finite stored prices can abort search rebuilding | IMPROVEMENT - MEDIUM | Reuse the finite Decimal reader; test both price fields with NaN and either infinity. |
| The explicit catalogue test bridge does not override transitive paths | BUG - MEDIUM | Both test-only path declarations use `override: true`; resolve and run against the API-enabled catalogue. |
| Availability publishing depends on a price read before its row lock | Regression coverage | A committed-connection race verifies that removing the price while publishing waits leaves the product a draft. |
| Per-field price confirmation policy | Documentation | README explicitly documents independent field checks; the established rule and the 99-item claim merge cap remain. |
