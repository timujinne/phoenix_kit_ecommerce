# Code Review: PR #56 — Catalogue translation control: staleness tracking, reconciliation sweep, admin page

**Reviewed:** 2026-09-15
**Reviewer:** Claude (claude-opus-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/56
**Author:** Tymofii Shapovalov (timujinne)
**Merge SHA:** 91beb8b (squash)
**Status:** Merged

## Summary

A 44-file, ~17k-line squash that turns AI translation from a per-product button
into a managed operation:

- `TranslationFingerprint`: per-field, per-language `sha256(trim(source))` in
  `metadata["_translation_fingerprints"]`, the four states
  (`missing > stale > unknown > fresh`), write-narrowing, and a
  hash-in-the-database candidate query.
- `CategoryAITranslatable`, a second adapter under the same `FOR UPDATE`
  locked merge as products, plus `stamp_reference/4` / `reset_reference/3` on
  both.
- `PromptRollout`, a content-sha rollout of the code-managed prompts that never
  clobbers an operator's hand edit.
- `TranslationSweepWorker`, a self-rescheduling Oban tick with batch and
  in-flight ceilings, and `TranslationSweepSettings`, its settings reader.
- `/admin/shop/translations` (coverage, filters, bulk and catalogue-wide verbs,
  sweep panel, diagnostics), the `shop_translations_enabled` /
  `shop_shopify_enabled` existence toggles, and the one-shot
  `backfill_translation_fingerprints` task.
- A `ProductForm` fix that stops every save erasing fingerprints (metadata is
  now merged, not replaced).

The PR itself carried many rounds of self-review (the btrim seam, the
blank-source SQL, nil-source erasure, the stall reporting, the prefix wiring).
The core model is sound. Most of what is left sits at the seams with the rest
of the shop: the catalogue product source, the shared PubSub topic, and
`enable_system/0`.

## Verification

- Read every production file in full: `translation_fingerprint.ex`, both
  adapters, `prompt_rollout.ex`, `translation_sweep_settings.ex`,
  `translation_sweep_worker.ex`, `web/translations.ex`, the backfill task, and
  the `settings.ex` / `product_form.ex` / `shopify_sync.ex` /
  `phoenix_kit_ecommerce.ex` diffs.
- Cross-checked against the installed `phoenix_kit_ai` 0.22.0:
  - `Translations.broadcast/3` sends a content-free summary to the global
    topic for every event of every module.
  - `enqueue/1` validates only argument shape and never checks for a
    registered adapter.
  - `TranslateWorker.resolve_adapter/1` discards a job whose `resource_type`
    has no registered adapter.
  - `TranslateWorker` runs on `queue: :default`.
- Confirmed `ProductSource.Legacy.list_products/1` / `list_categories/1` apply
  no default limit and support `:search`, so the page's unpaginated
  `matching_rows/1` (and therefore "stamp all matching") really covers the
  whole filtered set.
- Confirmed `Oban.cancel_all_jobs/1` returns `{:ok, count}`, which "Stop
  translations" relies on, and that `IntegrationProviders.clear_cache/0`
  exists in core 2.23.2.
- Baseline before any change: `mix test` — 1426 tests, 0 failures
  (214 excluded).

## Findings

### 1. BUG - MEDIUM — the translation feature ignores the catalogue product source — FIXED

`ai_translatables/0` returns `[]` under `shop_product_source: "catalogue"`, so
neither adapter is registered with `phoenix_kit_ai`. Nothing else knew:

- **Sweep tick.** It still ran `select_candidates/2` against the legacy shop
  tables and enqueued `shop_product` / `shop_category` jobs. `enqueue/1`
  accepts them, and `TranslateWorker` discards every one as an unknown
  resource type. The pairs stay `missing`, so the next tick enqueues them
  again, forever, reported as a healthy `ok, N jobs queued`.
- **Page.** `Shop.list_products/1` goes through `ProductSource.current()`, so
  the table listed catalogue items. Translate, stamp and reset then looked
  those uuids up in `phoenix_kit_shop_products` and found nothing.
- **Settings toggle.** It let an operator enable all of the above.

**Fix:**

- New `PhoenixKitEcommerce.translations_supported?/0` (Legacy source only),
  which `ai_translatables/0` now uses too, so the two can't disagree.
- The tick stops with a new `:product_source_unsupported` reason, placed
  before the sweep toggle so the manual "Run sweep" can't bypass it; the page
  words it in both the flash and "Last tick".
- The page mount redirects with an explanation.
- The settings toggle renders disabled with a note, and its handler refuses.

New msgids are translated in ru/de/fr/et. Tests are all `:catalogue`-tagged,
because `ProductSource.current/0` only returns Catalogue with
`phoenix_kit_catalogue` loaded: the worker gate (including
`run_manual_tick/0`), the page redirect, and the disabled, refusing settings
toggle.

The sidebar tab's `visible:` was deliberately left on
`translations_enabled?/0` alone: it runs on every sidebar render, and
`ProductSource.current/0` adds a config read there whenever catalogue is
loaded. The worst case is a visible entry that redirects with the
explanation.

### 2. IMPROVEMENT - MEDIUM — the page reloads everything on every AI translation event, from any module — FIXED

`handle_info({:ai_translation, _event, _payload}, socket)` ran `load_data/1` on
every message on `phoenix_kit:ai_translation`. Every module's `TranslateWorker`
broadcasts on that topic, `:translation_started` included.

`load_data/1` loads the filtered catalogue and then the whole catalogue again
for the coverage row. It also calls `ensure_prompt/0` for both adapters (a
prompt read, potentially a write), counts in-flight jobs, and reads 20
request-log rows. A 1330-job run from any module meant roughly 2660 such
reloads per open copy of the page.

**Fix:** reload only for `:translation_completed` / `:translation_failed`
whose `resource_type` is `shop_product` / `shop_category`. `:started` changes
nothing the page shows, because the job was already counted in flight. New
test: a completed event for another resource type, and a shop
`:translation_started`, leave an unannounced write unrendered.

### 3. IMPROVEMENT - MEDIUM — `enable_system/0` could crash on sweep scheduling — FIXED

`TranslationSweepWorker.ensure_scheduled()` was called bare after
`shop_enabled` had already been written. An Oban instance not yet running, or
an insert it refuses, raised out of the module's enable callback. The shop
was then half-enabled, and the caller saw a crash for a side concern that is
retried anyway on the translations page mount and on a sweep-settings save.

**Fix:** `recover_translation_sweep/0` logs an `{:error, _}`, a raise or an
exit, and returns `:ok`. The existing "also recovers the sweep chain" test
still pins the happy path. No failure-path test: the test harness has no
clean way to make the registered Oban instance refuse an insert, short of
stopping it for the whole suite.

### 4. IMPROVEMENT - MEDIUM — sweep head-of-line starvation on persistently failing candidates — NOT FIXED

Candidates come back sorted by uuid (categories first), and
`take_within_budget/3` takes from the head. Take a resource whose job always
fails:

- an unparseable model response, discarded after 3 attempts;
- a slug collision that `put_translation/4` returns as a changeset error;
- a source the model refuses.

Its pair stays `missing` / `stale`, so it leads the candidate list on every
tick. With the default batch of 3, three such resources hold every slot:
the sweep makes no progress on the rest of the catalogue and pays for three
failing calls per tick, while "Last tick" reads `ran, 3 jobs queued`.

Fixing it properly needs a per-pair failure ledger with backoff (or
skip-after-N) that the candidate query can consult, which is a design change
beyond a review fix. Recorded here so the limitation is visible. The
diagnostics panel is currently the only place an operator can spot it.

### 5. NITPICK — the PubSub live-status test could not fail — FIXED

It asserted `render(view) =~ "Fresh"`. The state filter always renders
`<option value="fresh">Fresh</option>`, so the assertion held before any
reload. Its fixture also kept an untranslated description, so the row itself
stayed `Missing` after the event. The test now uses a title-only product and
asserts on `#translation-row-<uuid>`, before and after.

### 6. NITPICK — the sweep tick was scheduled on the dead render too — FIXED

`SweepWorker.ensure_scheduled()` sat outside the `connected?/1` check, so
every page visit attempted the insert twice (uniqueness absorbed the second).
It now runs on the connected mount only.

### 7. NITPICK — the sweep worker runs on `default`, not `shop_imports` — NOT CHANGED, DOCUMENTED

AGENTS.md said all of this module's async work runs on `shop_imports`. The
sweep is on `default`, which is deliberate: the `TranslateWorker` jobs it
enqueues run there, its batch and ceiling defaults are sized against that
queue's concurrency, and a long CSV import on `shop_imports` must not hold up
a tick. AGENTS.md now records the exception.

### 8. NITPICK — the backfill's blankness test lacks the trim its hash uses — NOT FIXED

`field_present_clause/1` and `field_hash_expr/1` test `nullif(x, '')`, while
the hash itself uses `btrim(x, $3)`. A whitespace-only source or translation
therefore gets a fingerprint stamped. That is harmless, because
`field_state/3` treats a blank source as stateless and a blank translation as
`:missing` regardless of fingerprint. The UPDATE also writes an empty `{}` map
for a target language with nothing to stamp, which `get/3` reads as absent.
Both are cosmetic for a one-shot task. Aligning them would mean binding `$3`
in the dry-run count too.

### 9. NITPICK — client `uuids` on the bulk verbs are not cast — NOT FIXED

A malformed uuid in a `request_*` payload reaches `Repo.get` or a
`where uuid ==` query and raises `Ecto.Query.CastError`, crashing the admin
LiveView, which then reconnects. That matches the existing Products and
Categories bulk handlers, and only an admin holding `shop.manage_settings` can
send it.

### 10. NITPICK — `unknown` fields are not write-protected — NOT CHANGED (by design)

`write_decision/3` writes any field that is not `:fresh`. A "translate" on a
language with one `missing` field therefore also overwrites a sibling
`unknown` field, for example a manual translation made before the backfill.
This is design §4.4's table as written, and the operator note says to run the
backfill before first use. Worth knowing when reading a surprised operator's
report.

### 11. NITPICK — AGENTS.md not updated for the new surface — FIXED

AGENTS.md is now updated for:

- the new tab and admin LiveView, the settings keys and their wrapper;
- the `phoenix_kit_ai ~> 0.20` floor, the worker and mix task, and the new
  modules;
- which permission covers which translations-page action;
- three landmines: the Elixir/SQL fingerprint agreement, the
  catalogue-source gate, and the `ProductForm` metadata merge;
- a feature-notes row.

### 12. BUG - MEDIUM (test harness) — the global test Oban broke the `:catalogue` media-panel suite — FIXED

`test_helper.exs` now starts a suite-wide `Oban` named `Oban` for the sweep
tests. `ShopifySyncMediaPanelTest` still called
`start_supervised!({Oban, name: Oban, …})` in its setup, which cannot
register a second process under that name. All 10 of its tests failed with
`failed to start child`. A plain `mix test` excludes `:catalogue`, so the
PR's own "0 failures" runs never saw it. The test now uses the suite-wide
instance, which is also `testing: :manual` and inserts through the sandboxed
connection.

### Looked at, no change

- **`ProductForm` merges onto the mount-time snapshot, not a fresh read.** The
  PR documents the remaining race. A fresh read would actually be less
  coherent: the form also posts its own snapshot of every translation, so
  pairing fresh fingerprints with stale translation text would mark
  overwritten text `fresh`.
- **The `PromptRollout` create race and its concurrent in-place updates**
  converge on identical bytes, as documented.
- **`reschedule/0`** does cancel-then-insert without a transaction. A
  concurrent `ensure_scheduled/0` in between is absorbed by uniqueness.

## Validation

- `mix format`; `MIX_ENV=test mix compile --warnings-as-errors` clean.
- `mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy`: 3 new
  msgids, translated in ru/de/fr/et.
- `mix precommit` (compile `--warnings-as-errors`, hex.audit, format check,
  `credo --strict`, dialyzer): passed.
- `mix test`: 1427 tests, 0 failures (217 excluded — the `:catalogue`
  family, including the three new product-source tests).
- `:catalogue` suite through the path bridge
  (`PHOENIX_KIT_CATALOGUE_PATH=../phoenix_kit_catalogue
  PHOENIX_KIT_ENTITIES_PATH=../phoenix_kit_entities mix test --only catalogue`,
  `mix.lock` restored afterwards): first run 217 tests, 10 failures (finding
  12); after the fix, 217 tests, 0 failures.
