[
  # Gettext.Backend expands into code that constructs %Expo.PluralForms{}
  # literals inline; that struct is @opaque in Expo, so dialyzer flags the
  # generated call to Gettext.Plural.plural/2 as a call_without_opaque
  # mismatch. Known upstream false positive (gettext >= 0.26) — the plural
  # forms work correctly. (Surfaced once et/ru plural translations were added,
  # which is when the backend emits the plural code path. Mirrors the same
  # ignore in phoenix_kit_staff / phoenix_kit_billing / phoenix_kit_catalogue
  # / phoenix_kit_projects.)
  {"lib/phoenix_kit_ecommerce/gettext.ex", :call_without_opaque},

  # `phoenix_kit_catalogue` is an OPTIONAL dependency this fork never
  # declares at all (unlike `phoenix_kit_ai`, which dev/test genuinely
  # installs — see mix.exs's comment block by the `pk_dep(:phoenix_kit_ai,
  # ...)` line for why, and the sibling note for catalogue right below
  # it): the compiler's `@compile {:no_warn_undefined, ...}` tags quieten
  # its own xref check, but dialyzer has no equivalent knob and correctly
  # reports every call into `PhoenixKitCatalogue.*` as unknown — the module
  # (and its `Item`/`Category` types) simply isn't in this build's PLT.
  # `ProductSource.current/0` only ever returns this adapter once a host
  # actually declares the dependency, so these calls are live code, not
  # dead code; the real integration tests (Tasks 5-6 of the block 3 plan)
  # run where both `phoenix_kit_catalogue` and its PLT entry exist.
  {"lib/phoenix_kit_ecommerce/product_source/catalogue.ex", :unknown_function},
  {"lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex", :unknown_function},
  {"lib/phoenix_kit_ecommerce/product_source/catalogue/query.ex", :unknown_type},
  {"lib/phoenix_kit_ecommerce/product_source/catalogue/view.ex", :unknown_function},
  # Same reasoning, Block 3 "sync 6a": `Writer` and `Shopify.Sync`'s
  # catalogue-dispatch branch call into `PhoenixKitCatalogue.Catalogue`
  # (`update_item/2`, `create_item/2`, `get_item!/1`, `Slugs.from_title/2`)
  # and reference `Item.t()` in specs — same undeclared-optional-dependency
  # shape as the adapter files above.
  {"lib/phoenix_kit_ecommerce/catalogue/writer.ex", :unknown_function},
  {"lib/phoenix_kit_ecommerce/catalogue/writer.ex", :unknown_type},
  {"lib/phoenix_kit_ecommerce/catalogue/value_resolver.ex", :unknown_function},
  {"lib/phoenix_kit_ecommerce/shopify/sync.ex", :unknown_function},
  {"lib/phoenix_kit_ecommerce/shopify/collection_sync.ex", :unknown_function},
  {"lib/phoenix_kit_ecommerce/workers/shopify_media_sync_worker.ex", :unknown_function}
]
