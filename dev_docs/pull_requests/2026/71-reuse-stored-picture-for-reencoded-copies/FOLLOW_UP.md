# PR #71 follow-up — Reuse a stored picture for its re-encoded copies on import

## Fixed (pre-existing)

- ~~IMPROVEMENT - HIGH: the fingerprint backfill had no way to be run.~~
  `lib/phoenix_kit_ecommerce/mix_tasks/phoenix_kit_ecommerce.backfill_image_fingerprints.ex:41`
  wraps `ImageDownloader.backfill_fingerprints/0`; test in
  `test/phoenix_kit_ecommerce/mix_tasks/backfill_image_fingerprints_test.exs`;
  listed in `AGENTS.md`.

## Not changed by the reviewer (design notes, not defects)

The review recorded four limits and chose to leave each; none was re-opened
here:

- two copies downloaded concurrently can both be stored (bounded to one extra
  file per race);
- `source_url_aliases` grows with the number of listings sharing a picture;
- `backfill_fingerprints/0` retries files ImageMagick cannot read on every run;
- only the first frame of an animation is fingerprinted.

## Open

None.
