# Recent changes — recheck of the Codex fixes

Reviewed 2026-11-11 against `main` at `791e34b`.
Reviewer: Claude.

Rechecked the four fixes of [CODEX_REVIEW.md](CODEX_REVIEW.md) in `791e34b`
against the code, billing 0.25.0 and core 3.3.0 as locked, and the
`phoenix_kit_emails` checkout. Applied the Ecto and Oban thinking skills.

## Confirmed

- **Stale cart line.** `update_cart_item/2` re-reads the line under the cart
  lock and decides on that row; a refusal returns from the transaction without
  rolling it back. A cart line never changes its cart, so reading it by its uuid
  alone is safe.
- **Refunded and cancelled orders.** The stored status decides. `cancelled` and
  `refunded` are billing's spellings (`Order.@valid_statuses`).
- **Product origin.** `ProductSource.Catalogue.View` is the only code that sets
  `origin: :catalogue`; a stored Legacy product answers `nil` as before.

## BUG - MEDIUM — the send runs inside the transaction that holds the order lock

`once/3` held the order's `FOR UPDATE` lock through the send and the mark. Core's
mailer calls the email provider on the same connection, and `phoenix_kit_emails`
writes its log there and rescues its own errors
(`Provider.handle_after_send/2`; a constraint error from `create_log` comes back
as a changeset). Inside a transaction, a statement that fails aborts the
transaction whether or not the error is rescued. The mail had gone, the mark's
`update_all` raised `in_failed_sql_transaction`, the job failed and Oban retried:
the same email up to ten times (`max_attempts: 10`). Before `791e34b` the send
ran in no transaction, so a failed log write cost nothing.

Reproduced with a provider whose `handle_after_send/2` runs a failing statement
and returns `:ok`: `deliver/2` raised `25P02` after the email was sent.

Fixed by claiming instead of holding. Under the row lock a delivery reads the
stored mark and status, writes a claim (`%{"claimed_at" => unix_seconds}`) and
commits; it sends outside any transaction, then writes the mark. A second
delivery that finds a claim sends nothing and answers `{:snooze, seconds}`,
which the worker passes to Oban. A send that fails or raises gives its claim
back. A claim left by a delivery that died is good for five minutes, then the
next delivery sends: a crash can still repeat an email and never loses one. The
order row is no longer locked while a mail server answers.

What the claim gives up: between the claim and the send, the order can be
refunded and the email still goes. That window is the length of one send. The
case Codex fixed, a job that waits in the queue across a refund, stays fixed.

## NITPICK — a stock read that fails in the database now fails the update

`validate_stock_for_update/2` runs inside the cart transaction, so a Warehouse
read that fails with a database error aborts it; `StockTracking.on_hand/1`
rescues the error and answers `:off`, and the next statement raises. Checkout
(`validate_line_stock/1`) and `API.CartWriter` already behave this way. Not
changed: a read that fails for another reason still counts as `:off`.

Validation is recorded in [FOLLOW_UP.md](FOLLOW_UP.md).
