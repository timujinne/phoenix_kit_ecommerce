# PR #109 — permission sweep: review record

**Author:** Max Don (with Claude)
**Reviewer:** codex; findings checked against the code by Claude before fixing
**Verdict:** every confirmed finding fixed in this PR, each with a test that fails when the fix is reverted.

## Findings

- HIGH — the product form's AI-translate events bypassed `manage_catalog` after a mid-session revoke (the tab-less form maps to base `shop` in core) → gated before the embed; test enqueues nothing.
- LOW — the mount matrix omitted TestShop → covered.
- Checked, sound: all eight route path/view/action tuples match after the move, locale handling survives, no callers of the removed route names; controllers, API and JS paths.
