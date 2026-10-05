# Releases 0.5.14–0.5.17: follow-up review

- **Reviewer:** Codex
- **Date:** 2026-10-05
- **Reviewed head:** `ab657c6` (0.5.17), including PRs #68–#71 and their
  post-merge reviews.
- **Hex check:** 0.5.17 was published on 2026-10-05 at 12:40 UTC.
- **Verdict:** three reproduced correctness bugs fixed, plus a catalogue
  test-maintenance improvement. This review does not publish a release.

## BUG - HIGH: stale products bypass required-option validation (fixed)

`add_to_cart/4` validated the caller's product before the transaction, then
locked/reloaded it for pricing without validating that fresh product. A
product read before options were added could therefore be added with no
selection at its base price. A selected value removed since the read was
also accepted, even though the current product cannot supply that variant.
This leaves a gap in 0.5.15's required-option enforcement (#69).

**Reproduction:** read a product without options, update its metadata to
require liquid and cup colours, then pass the stale product to
`add_to_cart/3`. The released code inserts a 35.52 line without colours,
although its current options require a 32.00 surcharge. A second regression
removes Blue from a product after reading it; the released code still carts
the stale Blue selection.

**Fix:** validate the freshly locked/reloaded product in both pricing
transactions, before creating or incrementing a line. Preserve the public
three-element error tuples when rolling back. Thread
`skip_spec_validation: true` through both paths so the trusted-caller opt-out
still works. Validate once, against the product that supplies the price.

**Coverage:** stale empty selection through both context clauses, stale
removed value, explicit opt-out, and a real catalogue item receiving a new
required attribute-set attachment after its view was read. Catalogue reads
retain their existing limitation: the adapter provides a fresh read, not a
row lock.

## BUG - MEDIUM: first-frame matching replaces different animations (fixed)

PR #71 pinned both fingerprinting and confirmation to `[0]`. Two GIFs or
WebPs with the same opening frame and different later frames could resolve
to one Storage file. A static image could also resolve to an animation.
The recorded alias made that wrong resolution persistent in the writer's
URL index. This changes the media displayed to the customer; it is more
than the duplicate-storage nitpick recorded in Claude's review.

**Fix:** inspect the complete image's frame count using the sniffed decoder
and core's ImageMagick limits before computing a fingerprint or confirming
a candidate. Multi-frame inputs return `{:error, :multiple_frames}`;
ordinary imports store them without perceptual fingerprints. Confirmation
also checks frame counts, protecting against animation fingerprints already
written by 0.5.17. Expected animation exclusions do not produce a downloader
warning. Exact-byte reuse remains available.

**Coverage:** two-frame GIF and WebP inputs with identical first frames;
animation versus static image; single-frame GIF/WebP eligibility; real
Storage imports of different animations; a historical animation fingerprint
cannot replace a static image; exact-byte animation reuse still succeeds.

## BUG - MEDIUM: square stretching hides changed image proportions (fixed)

Both fingerprinting and confirmation resized images with `!`, forcing a
square in confirmation. A 320×240 product image stretched to 320×120 still
passed both checks: the confirming resize undid the distortion. Imports
then returned the original picture and recorded an alias for a visibly
different version.

**Fix:** confirmation fits each oriented image into 256×256 and pads with
white, preserving aspect ratio before calculating the local difference.
The stored fingerprint format remains v2; only confirmation changes, so
existing static fingerprints remain usable. Historical measurements in
the module documentation are identified as measurements of the original
square-stretching comparison.

**Coverage:** the distorted copy still passes the fingerprint candidate
filter, fails picture confirmation, and receives its own Storage file
without contaminating the original's aliases. Existing JPEG re-encode,
downscale, transparent-icon and thin-added-line regressions still pass.

## IMPROVEMENT - MEDIUM: catalogue route tests duplicate a sibling's old paths (fixed)

The optional catalogue suite exposed four assertions expecting
`/admin/catalogue/...`. The current sibling's `PhoenixKitCatalogue.Paths`
returns `/admin/catalogues/...`, which the ecommerce helper correctly
delegates to. These were stale test expectations, not broken runtime links.

**Fix:** compare the editor path with the sibling's public path helper and
continue asserting that the storefront/admin return URL is carried. This
still detects a switch to the wrong product source or record while allowing
the owning module to evolve its route prefix.

## Other release paths checked

- **0.5.14 / #68:** capped variant lists are completed before price consumers
  use them; incomplete lists are refused; the absorber construction protects
  the variant fit against Shopify's cheapest-price anchor. A deliberately
  drifted item base is surfaced separately, rather than silently called exact.
  The catalogue suite exercises the mapper/writer/worker/storefront seam.
- **0.5.16 / #70:** the category mutation paths and scheduled/manual sweep
  locking were rechecked, including the scheduled successor's insertion
  outside the tick transaction. The corresponding regression suites run in
  the standard test suite. No additional bug was verified in these paths.
- **0.5.17 backfill task:** the task reaches the context backfill and reports
  its counts. Its documentation now accounts for the frame-count check.

## Limits retained

- Concurrent imports can still store redundant copies. No lock was added
  around all image downloads.
- Source aliases remain uncapped; capping them would force later downloads
  for URLs that should already resolve from the index.
- The backfill still counts and retries unreadable or unsupported images,
  including multi-frame images excluded from perceptual matching.
- The comparison remains an approximation with a finite detail resolution.
  These changes prevent future unsafe resolutions; they do not reconstruct
  historical aliases or product attachments made by earlier false matches.

## Validation

Four new regressions failed against the released implementation before the
fixes: stale empty selection, stale removed value, animation matching and
stretched-picture matching (`31 tests, 4 failures`).

- `mix test`: **1,599 tests, 0 failures, 276 excluded**. Database-backed
  integration tests ran; the excluded tests require the catalogue bridge.
- Catalogue bridge (`PHOENIX_KIT_CATALOGUE_PATH=../phoenix_kit_catalogue`
  and `PHOENIX_KIT_ENTITIES_PATH=../phoenix_kit_entities`): **276 tests,
  0 failures**, including the new stale-attachment regression. The first
  run identified the four outdated path assertions described above.
- `mix precommit`: **passed** — forced compilation with warnings as errors,
  unused-lock check, Hex retirement audit, format check, strict Credo and
  Dialyzer (all 62 existing suppressions accounted for, none unnecessary).
- `git diff --check`: **passed**. Temporary catalogue-only dependency lock
  entries were removed; package requirements and the release version are
  unchanged.

The tests emit existing support-module redefinition and unavailable-cache
warnings. These did not prevent database integration tests or either suite
from running, and the compilation gate passed.
