# PR #108 — host-supplied cart images

Reviewed 2026-10-22 at draft head `dabab781354edad559ea82d8f2204593d26334b3`.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/108

Read the complete diff and its cart/checkout call sites in an isolated worktree.
No functional defect found: a product photo takes priority; an absent or empty
photo uses the configured MFA callback; invalid configuration, non-string/empty
answers, and raised exceptions retain the icon. Cart links, image alt text, and
checkout summary behavior are preserved.

The callback is invoked during rendering and should remain cheap; host code owns
that callback. Its documented contract promises exception recovery, not recovery
from arbitrary process termination. No change to that contract is needed.

The PR remains a draft and is not merged or modified by this review.
Validation results are recorded in `FOLLOW_UP.md`.
