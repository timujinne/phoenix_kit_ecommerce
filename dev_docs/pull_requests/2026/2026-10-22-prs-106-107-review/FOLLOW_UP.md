# Follow-up: PRs #106, #107 review (2026-10-22)

Resolutions for `CLAUDE_REVIEW.md`.

| Finding | Resolution |
|---|---|
| #107 second service listing after a failed one | Fixed: `snapshot_choices/3` answers `[]` for a failed listing other than `:unknown_service`; test in `service_choice_test.exs`; CHANGELOG |
| #106 Billing link vs recipients without billing access | Open — one link for all recipients; a per-recipient link needs a permission check that covers Owner and `"*"` holders |
| #107 carrier call under the cart-row lock | Open — consistent with the destination setters, documented in the docstring |
| #107 new method ticks every offered service | Open — intended by the PR |
