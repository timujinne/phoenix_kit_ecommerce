# PR #96 — language-domain API links

Reviewed 2026-10-24 against `88a98ad`, including Claude's test-helper fix.
PR: https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/96

No new functional finding. Product and category presenters pass the answer's
language to `Context.absolute/3`, which calls core's canonical URL helper once
when available and otherwise retains the request-host fallback. Checked core's
producer for mount-prefix and base-language segment handling and the wrapper
that restores the request currency and domain-default language.

The canonical URL compatibility exclusions are now included in ExUnit's actual
configuration. The Dialyzer suppression names the optional missing function.

Validation is recorded in [the recheck](../2026-10-24-merged-prs-recheck/CODEX_REVIEW.md).
