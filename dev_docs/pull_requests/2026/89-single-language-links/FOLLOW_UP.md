# Follow-up: PR #89 review (2026-10-13)

| # | Finding | Resolution |
|---|---------|------------|
| 1 | `page_path/3` drops the query: My Orders filter and pagination never applied | Fixed: `page_path/3` appends the encoded query; `user_orders_query_test.exs` |

## Gate

`mix test`: 3037 tests, 1 failure — `TranslationsTest` "a tick whose enqueues
all failed…", unrelated to #89: `phoenix_kit_ai 0.25.5` now refuses a bad
endpoint override before enqueuing, so the test's door no longer led to an
all-failed tick.

Resolved afterwards: the test now provokes the tick through a prompt row that
holds the product prompt's name under another slug (`create_prompt/1` loses to
the unique name). That exposed a production bug in `PromptRollout.create/3`:
the sweep tick runs in a transaction, and the failed insert aborted it so the
re-read raised `in_failed_sql_transaction`. The insert now runs in a
savepoint; `prompt_rollout_test.exs` pins it (fails without the fix).
