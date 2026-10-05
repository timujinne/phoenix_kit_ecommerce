# Releases 0.5.14–0.5.17: recheck of Codex's follow-up (`2dc90d7`)

- **Reviewer:** Claude
- **Verdict:** all three fixes are correct; nothing to change. Shipped as 0.5.18.

## Checked

- **Stale cart options.** `validate_locked_specs!/3` runs on the product
  `lock_or_reload_product/2` returns, before any cart write in both
  transactions, so a rollback leaves nothing behind. The
  `{:invalid_specs, error}` wrapper is unwrapped in both result `case`es, so
  `add_to_cart/3,4` still return the public three-element
  `{:error, :missing_required_option, key}` tuples. `skip_spec_validation`
  reaches both paths. The caller's possibly stale product is no longer
  validated at all, which is the point: the product that supplies the price
  is the one that is checked.
- **Animations.** `single_frame_input/1` reads `%n` through the pinned
  decoder with `-ping`. ImageMagick prints `%n` once per frame, so a
  two-frame GIF answers `22`, not `2`: the exact `{"1", 0}` match is right,
  and anything else is refused. Confirmed against a real single- and
  two-frame GIF here (`1` / `22`).
- **Stretched pictures.** `-resize 256x256` (fit) then `-gravity center
  -extent` pads with the white `-background` set earlier in the same
  command, after the grey conversion, so both sides keep their aspect ratio
  and a pad is white on both.

## Residual notes (not changed)

- `backfill_fingerprints/0` now logs a warning and counts a failure for
  every animated image on every run. Harmless, noisy on a library with many
  GIFs; the limit is already recorded in Codex's review.
- Aliases and attachments written by 0.5.17 for a false match are not
  repaired; they need a manual look.

## Validation

`mix test`: 1,599 tests, 0 failures with `PGPOOL=5 mix test --max-cases 4`.
At `PGPOOL=10` on the shared Postgres two runs failed 97 and then 77 tests,
all `queue_timeout` connection errors; the count changed between runs and
nothing else failed. The 276 catalogue tests were not rerun here; Codex
reports them green through the path bridge.
