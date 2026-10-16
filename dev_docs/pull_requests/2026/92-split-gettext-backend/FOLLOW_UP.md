# Follow-up — PR #92

| Finding | Severity | Resolution |
|---|---|---|
| Nothing pinned the split layout | NITPICK | `gettext_backend_test.exs` asserts the parent beam dispatches to one `T_<locale>_default` module per shipped locale, plus lookups and the unknown locale/domain fallback. |
| `:domain` splits nothing while only `default.po` exists | NITPICK | Left as is. A second domain would compile in parallel without another change. |
