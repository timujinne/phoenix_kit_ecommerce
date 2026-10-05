# PR #71: Reuse a stored picture for its re-encoded copies on import

- **Author:** Tymofii Shapovalov
- **Reviewer:** Claude
- **Merged as:** `fd21f45`
- **Verdict:** correct as merged. One gap in how an operator reaches the
  feature was closed after the merge; four limits are recorded and
  deliberately not changed.

## Scope

- `ImageFingerprint`: a 256-bit luma dHash plus a 4×4 RGB grid from one
  ImageMagick call (step 1), and `same_picture?/2`, a 256×256 grey local
  difference over the two images (step 2).
- `ImageDownloader.download_and_store/3` reuses an active file for the same
  bytes and name, then for a fingerprint match confirmed by step 2, restores
  a trashed row core's dedup hands back, and records a reused URL in
  `metadata["source_url_aliases"]`. `backfill_fingerprints/0` stamps files
  stored before.
- `Catalogue.Writer` indexes the aliases, every file's own `source_url`
  first. Core floor `2.38.0` → `2.43.0`.

Checked and found correct:

- `Storage.update_file_metadata/2` takes a `FOR UPDATE` row lock and accepts
  `:unchanged` from the function, so `remember_source_url/2` is atomic per
  file and a no-op alias write costs no update.
- `ImageProcessor.pinned_input/2` and `limit_args/0` exist in core 2.43+ with
  the arities used; `convert` is the binary core itself calls.
- `Writer` already dedupes `file_uuids` after resolving, so two Shopify
  images of one listing that now resolve to the same file attach once.
- Nothing in this module trashes or deletes a Storage file, so a file shared
  by many products cannot be removed by one product's sync.
- `restore_file_into(file, nil)` is guarded by `status == "trashed"`; the
  `:not_trashed` race is read back instead of failing.
- The candidate query is restricted to the current fingerprint version and
  `source_url`-bearing active rows; ranking is total (bits, mean, time, uuid).

## Findings

### IMPROVEMENT - HIGH: the backfill had no way to be run (fixed)

`ImageFingerprint.version/0` and the downloader docs tell the operator to run
`ImageDownloader.backfill_fingerprints/0` after deploying, but nothing
exposed it: no mix task, no UI, no worker, and a release host has no `mix`.
A library imported before this PR has no fingerprints, so step 2 finds no
candidate and every copy is fetched and stored again — the PR's whole point
silently does nothing on exactly the libraries it was written for.

**Fix:** `mix phoenix_kit_ecommerce.backfill_image_fingerprints`, a thin
wrapper that runs the backfill and reports `fingerprinted`/`failed`
(`Mix.Tasks.PhoenixKitEcommerce.BackfillImageFingerprints`), with a test.
AGENTS.md lists it; the CHANGELOG entry lands with the release commit. A host without `mix` can still call
`PhoenixKitEcommerce.Services.ImageDownloader.backfill_fingerprints/0` from
`bin/<app> rpc`.

### NITPICK: two copies downloaded concurrently are both stored (not changed)

`download_batch/3` runs up to 5 downloads at once. Two copies of one picture
that both miss step 2 before either has been stored both store, since the
lookup and the store are not one atomic step. A lock around find-and-store
would serialize every download for a rare case; the next sync's step 2 finds
the earlier copy and reuses it for any later one, so the duplicate is
bounded to one extra file per race.

### NITPICK: `source_url_aliases` grows without bound (not changed)

One banner copied onto 389 listings records 388 aliases on one file
(~40 KB of JSONB). That is the cost of the URL index answering without a
download. A cap would turn the 389th copy back into a download.

### NITPICK: `backfill_fingerprints/0` retries files ImageMagick can never read

A corrupt file, or an SVG when `shop_allow_svg_uploads` is on, fails every
run and is logged and counted each time. Marking it would need a second
metadata key that every reader must learn; the count and log line are the
signal an operator wants.

### NITPICK: only the first frame of an animation is compared

`pinned_input(path, "[0]")` fingerprints frame 0. Two different animated
GIFs or WebPs that open on the same frame read as one picture. Rare in a
product library; the doc already says what step 2 cannot see.

## Validation

`mix test` on the PR's three suites (43 tests) and the new task test pass;
`mix precommit` is clean.
