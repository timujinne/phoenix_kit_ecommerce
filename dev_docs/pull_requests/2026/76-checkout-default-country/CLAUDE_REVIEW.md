# PR #76: Start checkout on the shop's country instead of a hardcoded EE

- **Author:** Tymofii Shapovalov (timujinne)
- **Reviewer:** Claude
- **Merge:** `a3a4ac9` on `main`
- **Verdict:** approve. No bugs found.

## Summary

A new cart with no shipping country opened checkout on `"EE"`, so a shop
whose shipping methods cover another country offered no method. The new
`PhoenixKitEcommerce.default_checkout_country/0` takes the country from the
shop's own settings, in order: company country, `shop_default_tax_country`,
the one country every active shipping method shares, the first
`country_select_priority` entry. It stays `"EE"` only when none names one.

## Findings

- **NITPICK - the DB source runs on every checkout mount.**
  `shipping_methods_country/0` lists the active methods, but only when the
  cart has no `shipping_country` (the call sits behind `||`), and the other
  three sources are cached settings reads. Not worth caching.
- **Checked, correct.** A method with no countries (worldwide) yields
  `[[]]`, which neither matches `[[country]]` nor lets another method's
  single country count - so the source says nothing, as intended. A method
  listing its country twice is de-duplicated. Every source is rescued and
  logged, and a value that is not a known ISO code is ignored, in any case.
- **Checked, correct.** The settings reads go through `Policy`
  (`default_tax_country/0`), not directly, as AGENTS.md requires.

## Tests

`checkout_default_country_test.exs` covers each source, the order between
them, the invalid-code and failing-source skips. Passes.
