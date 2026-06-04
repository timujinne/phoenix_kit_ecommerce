# Follow-up Items for PR #4

Triaged against `main` on 2026-06-04 as part of the quality sweep.
Reviews: `CLAUDE_REVIEW.md` (Claude Opus 4.7), `MISTRAL_REVIEW.md`,
`PINCER_REVIEW.md` (all 2026-05-09). All three agree the PR is a clean,
well-scoped i18n-infrastructure addition.

## No new findings this sweep

Every actionable finding was already resolved by the post-merge
follow-up commit the reviews reference (`b42899c`, "Broaden i18n test
coverage and refresh mix.lock"), which landed before this sweep. The
only open item is the explicitly out-of-scope body-string backend
migration (see `## Open`). No production code was changed for this PR
during the 2026-06-04 sweep.

## Fixed (pre-existing)

Re-verified against current `test/phoenix_kit_ecommerce/i18n_test.exs`:

- ~~**Wiring test only iterated `admin_tabs/0` (3 of 10 sites
  unverified)**~~ (CLAUDE/MISTRAL/PINCER, all Low/Observation) — the
  follow-up extended iteration to `admin_tabs/0` + `settings_tabs/0` +
  `user_dashboard_tabs/0` and added a `length(tabs) == 10` sanity guard.
  Fixed pre-existing (commit `b42899c`).
- ~~**All translation assertions routed through `Tab.localized_label/1`
  (catalogue regression could be masked)**~~ — the follow-up added
  direct `Gettext.gettext(EcommerceGettext, ...)` assertions that hit the
  backend independently of the helper. Fixed pre-existing (commit
  `b42899c`).
- ~~**Redundant `alias PhoenixKitEcommerce` no-op**~~ — removed; repeated
  `Enum.find(...)` lookup extracted to a helper. Fixed pre-existing
  (commit `b42899c`).

## Skipped / Deferred (with rationale)

- **Manual `.pot`/`.po` maintenance burden** (CLAUDE/PINCER "Info") —
  inherent to keeping labels as plain `Tab.new!(label: ...)` strings
  (`mix gettext.extract` can't see them). The `.pot` header already
  documents the two-step "add a tab → run `mix gettext.merge`" workflow.
  Worth a release-checklist line, not a code change.
- **`extra_application: [:gettext]` ships all of `priv/`** (CLAUDE "Note
  on blast radius") — desirable for an Ecto-using package; no defect.

## Files touched

None this sweep.

## Verification

`mix precommit` green — compile (warnings-as-errors), `mix format`,
`credo --strict`, and `dialyzer` (0 errors). `mix test` — 126 tests, 0
failures (the i18n smoke tests run against the local `phoenix_kit` which
ships the `gettext_backend` Tab API, so they are no longer auto-excluded).

## Open

- **Body-string gettext backend migration (deferred — separate, larger
  PR).** `lib/phoenix_kit_ecommerce/web/shop_web.ex` still injects
  `PhoenixKitWeb.Gettext` (the parent app's backend) into LiveViews and
  controllers via `__using__`, so the ~25+ body-string `gettext()` calls
  across `web/` (e.g. `gettext("Edit")`, `gettext("Delete")`,
  `gettext("My Orders")`) resolve against the parent's catalogue rather
  than this module's `PhoenixKitEcommerce.Gettext`. This was flagged
  out-of-scope in the PR description and confirmed out-of-scope by all
  three reviews. Migrating it means: switch the `__using__` injection,
  audit every HEEx/LiveView `gettext()` call, extract + translate
  hundreds of msgids into `priv/gettext/<locale>/LC_MESSAGES/default.po`,
  and verify no consumer relies on parent-catalogue lookup. Surfaced for
  Max as a dedicated follow-up PR — too large and behavior-affecting to
  fold into a quality sweep. Also tracked in `AGENTS.md` under "Deferred
  from the 2026-06-04 quality sweep".
