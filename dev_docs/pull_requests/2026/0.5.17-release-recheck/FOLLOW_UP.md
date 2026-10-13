# Releases 0.5.14–0.5.17 recheck — follow-up

Triage of `CODEX_REVIEW.md` and `CLAUDE_REVIEW.md` against current code,
by reading (no suite run in this pass).

## Fixed (pre-existing)

- ~~**Codex, BUG - HIGH** stale products bypass required-option validation~~ —
  `validate_locked_specs!/3` (`lib/phoenix_kit_ecommerce.ex:3536`) runs on the
  locked/reloaded product in both pricing transactions (`:3024`, `:3172`);
  `{:invalid_specs, error}` is unwrapped at `:3070` and `:3216`;
  `:skip_spec_validation` is read at `:2850`.
- ~~**Codex, BUG - MEDIUM** first-frame matching replaces different animations~~ —
  `single_frame_input/1` (`services/image_fingerprint.ex:121`) returns
  `{:error, :multiple_frames}` and guards both fingerprinting (`:110`) and
  confirmation (`:264-265`); the downloader handles it at
  `services/image_downloader.ex:272`.
- ~~**Codex, BUG - MEDIUM** square stretching hides changed proportions~~ —
  confirmation fits and pads with `-extent` (`services/image_fingerprint.ex:285`).
- ~~**Codex, IMPROVEMENT - MEDIUM** catalogue route tests duplicate a sibling's
  old paths~~ — `test/phoenix_kit_ecommerce/web/storefront_admin_edit_test.exs`
  compares against `CataloguePaths.item_edit/1` / `category_edit/1`
  (`:158`, `:221`, `:273`, `:286`).

## Skipped (with rationale)

- **Limits retained** (both reviews): concurrent imports can store redundant
  copies, source aliases are uncapped, the backfill recounts animated and
  unreadable images on every run, and aliases written by 0.5.17 for a false
  match are not repaired. Recorded by the reviewers as accepted limits, not
  defects; unchanged.

## Open

None.
