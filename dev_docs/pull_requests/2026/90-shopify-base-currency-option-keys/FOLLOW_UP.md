# Follow-up — PR #90

| Finding | Severity | Resolution |
|---|---|---|
| Orphaned `executing` job makes later runs snooze | NITPICK | Not changed: the old uniqueness refused the enqueue in the same state; rescue is the host's Lifeline configuration. |
| No CHANGELOG entry for the PR | IMPROVEMENT - MEDIUM | Added an `## Unreleased` entry; the version is not bumped. |
| An old label could impersonate a current option key | BUG - MEDIUM | Unknown labels in a keyed option resolve to `nil`; legacy and catalogue schema options retain their identity. Covered by unit and LiveView regression tests. |
| Product notices could show another cart line's price | BUG - MEDIUM | Exact matching includes the selection format and the full selection. The page prefers a current keyed line before an old label match; the success flash uses the exact line. |
| Bandit 1.12.5 failed the security gate | BUG - HIGH | Updated the lock to Bandit 1.13.1 and Thousand Island 1.6.0; no dependency requirement changes. |
| Default-delay test imposed an unreliable maximum runtime | IMPROVEMENT - MEDIUM | Retained the minimum pagination-delay assertion and removed the scheduler-sensitive 900 ms upper bound after a full-suite failure. |
