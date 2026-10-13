# PR #21 follow-up — empty-slug lockout, put_slug/3 for shipping methods

Triage of `GROK_REVIEW.md` and `phase1.md` against current code, by reading.

## Fixed (pre-existing)

- ~~**Grok #1 BUG - HIGH** core floor admitted cores without `put_slug/3` and
  V171~~ — superseded: core is `>= 2.43.0 and < 3.0.0` (`mix.exs:118`);
  `test/phoenix_kit_ecommerce/dependency_floor_test.exs:38-49` asserts
  `Slug.put_slug/3` and `ShopSlugProjection` on the resolved core.
- ~~**Grok #2 BUG - HIGH** CJK shipping-method names could not be inserted~~ —
  `LocalizedSlug.put_plain_fallback/3` follows `Slug.put_slug/3`
  (`schemas/shipping_method.ex:131-134`).
- ~~**Grok #3 BUG - HIGH** unromanizable titles had no storefront URL~~ —
  stable `item-<hash>` fallback (`localized_slug.ex:66`).
- ~~**Grok #4 BUG - MEDIUM** `SlugResolver` treated `""` as a real slug~~ —
  `present_slug/1` skips blanks (`slug_resolver.ex:621-638`).
- ~~**Grok #5 / phase1 #3** duplicate `put_generated_slug/2`~~ — both schemas
  call `LocalizedSlug.maybe_generate/2` (`schemas/product.ex:188`,
  `schemas/category.ex:127`).
- ~~**Grok #6 NITPICK** comments described the index V171 replaced~~ — gone
  from both schemas; the one remaining mention
  (`test/phoenix_kit_ecommerce/empty_slug_test.exs:7`) names it as the old
  index, which is accurate.
- ~~**phase1 delta** V171 constraint names~~ — `unique_constraint/3` names the
  projection primary keys (`schemas/product.ex:192`, `schemas/category.ex:130`).

## Skipped (with rationale)

- **phase1 #1** version bump and CHANGELOG — the maintainer's.
- **phase1 #2** no one-off migration to scrub existing `""` slugs — deferred by
  the PR on purpose; legacy rows self-heal on their next save, and the reader
  no longer emits a blank slug (Grok #4).
- **phase1 nitpicks** comment length, reduce argument order — moot, the code
  moved into `LocalizedSlug`.

## Open

None.
