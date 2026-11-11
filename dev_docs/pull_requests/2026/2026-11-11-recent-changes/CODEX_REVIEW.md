# Recent changes — stock limits and order emails

Reviewed 2026-11-11 against `main` at `31f5342`.
Reviewer: Codex.

Compared recent PRs with existing review records. PRs #109–116 already have
Codex reviews; reviewed the newer PR #118 separately. This pass also covers
the commits since the previous review-fix batch: `769c1c0` (stock limits,
issue #82), `bdfa4cb` (order emails, issue #117), `108807a` (price-on-request
payments), `26a468f` (configuration/spec cleanup), and `31f5342` (email copies
and the shop's email language). Applied the Ecto, Oban, and Phoenix thinking
skills and read the relevant engineering contracts and resolved dependencies.

## BUG - MEDIUM — stale cart lines bypass stock limits and can hide a quantity update

`update_cart_item/2` decided whether a quantity was decreasing from the caller's
struct. After another tab reduced a line from 3 to 1, the original struct could
raise it to 2 even when only 1 remained in stock: the old 3 made it look like a
decrease. Requesting 3 with the same old struct caused a separate problem:
Ecto saw no change from the struct's quantity and left the stored quantity at 1.

Fixed by locking the active cart, re-reading the line, and validating and
changing that row. A stock refusal returns normally from the transaction,
preserving the enclosing public API transaction so it can process other lines.
Regressions reproduced both stale-struct failures before the fix. An additional
test checks that a refusal leaves the enclosing transaction usable.

## BUG - MEDIUM — the once-per-order email check trusts stale metadata

`once/3` read `_shop_emails` from its argument, and only locked the order when
marking an email after sending. Two callers that read the same unmarked order
could both send; even sequential calls with the original struct repeated the
buyer, copy, and shop emails. Oban uniqueness only governs job insertion and
does not protect overlapping deliveries or direct callers.

Fixed by locking and re-reading the order before checking its marker, holding
the lock through sending and marking. Buyer and copy sends commit separately,
so a failed copy preserves the buyer's marker. Tests reproduce stale-snapshot
duplicates, exercise four concurrent deliveries on separate real connections
with a committed order, and verify that an actual copy-send failure retries
only the copy. The race fixture removes its committed order afterwards.

The order lock now spans the mail operation in the background worker. A slow
send can delay other operations on that order; checkout still only enqueues
jobs. A process crash after the mail server accepts a message but before the
marker commits can still cause a duplicate on retry. Exactly-once delivery to
an external mail server requires a provider-side idempotency mechanism.

## BUG - MEDIUM — queued emails still confirm refunded or cancelled orders

`OrderEmailHandler` checked the order's status when queueing, but
`OrderEmailWorker` delivered later without checking it again. A payment followed
by a refund before the default queue ran still sent "paid and confirmed" to
the buyer and "New order" to the shop. A cancellation similarly failed to
suppress the queued confirmation.

The locked check now suppresses sends for refunded and cancelled orders.
Regressions cover both queued jobs and direct calls carrying the pre-transition
snapshot. The refund case failed before the fix.

## BUG - MEDIUM — Ecto persistence state is not a product's origin

`StockTracking.item_uuid/1` treated every built `%Product{}` as a catalogue item.
An unpersisted Legacy product therefore acquired a fictitious Warehouse item
identity, contradicting the rule that Legacy products have no warehouse stock.

The lookup now checks `origin: :catalogue`, retaining the shipping exemption.
The Legacy built-struct regression failed before the fix; the real-catalogue
stock tests continue to exercise the positive path.

## Other checks

- No new finding in paid-order goods-issue idempotency, shortage notification
  marking, checkout stock aggregation, or price-on-request payment deferral.
- Updated the engineering contracts for the locked quantity check, email
  delivery, and current migration/dependency ownership. No version bump,
  CHANGELOG entry, dependency change, migration SQL change, or release.
- Stock reservation, native per-variant stock, and refund restocking remain
  explicitly outside the implemented stock contract; this review does not
  claim to implement all of issue #82.

Validation is recorded in [FOLLOW_UP.md](FOLLOW_UP.md).
