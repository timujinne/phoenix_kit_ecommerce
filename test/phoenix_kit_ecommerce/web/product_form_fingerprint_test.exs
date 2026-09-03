defmodule PhoenixKitEcommerce.Web.ProductFormFingerprintTest do
  @moduledoc """
  Pins design §4.1's fingerprint store surviving a plain product-form save.

  `Web.ProductForm`'s save path rebuilds `metadata` from its OWN inputs
  (`_option_values`, `_price_modifiers`, `_image_mappings`, the price
  display key) and, before this fix, wrote that map wholesale via
  `Product.changeset/2`'s `cast(attrs, [..., :metadata, ...])` — a plain
  `cast` on a `:map` field REPLACES it entirely with whatever is present
  under `attrs["metadata"]`. Since the form renders no input for
  `_translation_fingerprints` (the form doesn't even know the key
  exists), every save silently erased it — not just the narrow
  form-open-during-translation race design §4.1 knowingly accepted, but
  EVERY save through the admin form, whether or not a translation was
  ever in flight.

  The consequence named in the task: a product edited through the form
  loses its fingerprints, its state folds to `:unknown` (design's four
  states), and `:unknown` is never picked up by the sweep (§4.3 never
  queues `:unknown`) — the most ordinary editing path produces no
  re-translation, directly against requirement 3 of §1.

  ## Why the fixture leaves the English description blank at mount

  `Web.ProductForm` has a SEPARATE, pre-existing defect (not this task's
  target, left alone here): `@product_translations` is snapshotted once
  at mount from the stored product and never refreshed for the DEFAULT
  language — `merge_translations_to_attrs/5` layers that stale snapshot
  on TOP of the main form's freshly-submitted default-language value
  whenever the snapshot already has an entry for that field, silently
  reverting the edit. It only has an entry for a field that was
  non-empty in the database at mount. Leaving `description` blank at
  creation keeps it out of that stale snapshot, so submitting a new
  `product[description]` through the live form actually lands — letting
  this test exercise a REAL save of REAL new source text, which is what
  the task asks to pin ("editing the English description through the
  form").
  """

  use PhoenixKitEcommerce.LiveCase, async: true

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.TranslationFingerprint, as: FP

  @source_lang "en"
  @target_lang "de"

  setup %{conn: conn} do
    scope = fake_scope()
    {:ok, conn: put_test_scope(conn, scope)}
  end

  defp repo, do: PhoenixKit.RepoHelper.repo()

  # A product that already carries a German translation of its
  # description and a fingerprint recorded for it (design §4.1: a
  # fingerprint is `sha256(trim(source as it was read at translation
  # time))`) — the description itself is left blank in "en" at creation
  # (see moduledoc) so the live form's own unrelated bug doesn't mask
  # this fix's effect.
  defp product_with_stamped_translation(fingerprinted_source) do
    {:ok, product} =
      Shop.create_product(%{
        title: %{@source_lang => "Wooden Vase"},
        description: %{},
        price: Decimal.new("10.00"),
        status: "active"
      })

    fingerprint = FP.hash(fingerprinted_source)
    metadata = FP.put_many(product.metadata, @target_lang, %{"description" => fingerprint})

    {:ok, product} =
      product
      |> Ecto.Changeset.change(%{
        metadata: metadata,
        description: Map.put(product.description, @target_lang, "Alte deutsche Beschreibung")
      })
      |> repo().update()

    product
  end

  describe "form save preserves _translation_fingerprints" do
    test "editing the source description leaves fingerprints in place, reads as :stale",
         %{conn: conn} do
      fingerprinted_source = "Whatever English text stood at translation time."
      product = product_with_stamped_translation(fingerprinted_source)
      stored_fingerprint = FP.get(product.metadata, @target_lang, "description")
      assert stored_fingerprint == FP.hash(fingerprinted_source)

      {:ok, view, _html} = live(conn, "/en/admin/shop/products/#{product.uuid}/edit")

      new_description = "The description was edited through the admin form."

      view
      |> form("form.space-y-6", %{"product" => %{"description" => new_description}})
      |> render_submit()

      reloaded = Shop.get_product!(product.uuid)

      # The edit actually landed — otherwise the rest of this test would
      # be checking nothing.
      assert reloaded.description[@source_lang] == new_description

      # THE FIX: the fingerprint the form never rendered a field for is
      # still there, byte-for-byte — the form merged rather than replaced.
      fingerprint_after_save = FP.get(reloaded.metadata, @target_lang, "description")

      assert fingerprint_after_save == stored_fingerprint,
             "form save must preserve the fingerprint store " <>
               "(_translation_fingerprints), not erase it wholesale"

      # And the CONSEQUENCE named in the task: with the fingerprint intact
      # but (necessarily) mismatched against the just-edited source, the
      # pair reads :stale — which the sweep (design §4.3) DOES pick up.
      # Erasing the fingerprint instead (the bug) would fold this to
      # :unknown, which the sweep never queues (§4.1) — the ordinary edit
      # would produce no re-translation at all.
      post_state =
        FP.field_state(
          reloaded.description[@source_lang],
          Map.get(reloaded.description, @target_lang),
          fingerprint_after_save
        )

      assert post_state == :stale
    end

    test "a plain create (no prior fingerprints) still saves normally", %{conn: conn} do
      # Guards against a merge that only works for :edit — :new goes
      # through the very same save path with an empty product struct.
      {:ok, view, _html} = live(conn, "/en/admin/shop/products/new")

      view
      |> form("form.space-y-6", %{
        "product" => %{
          "title" => "Brand New Product",
          "price" => "12.00"
        }
      })
      |> render_submit()

      [product] = Shop.list_products()
      assert product.title[@source_lang] == "Brand New Product"
      assert product.metadata["_translation_fingerprints"] == nil
    end

    test "unrelated fields the form DOES own (_price_modifiers) still update correctly",
         %{conn: conn} do
      # Regression guard on the merge itself: dropping form-owned keys
      # before merging must not turn into "never remove anything" — a
      # key the form legitimately clears (all option values selected =
      # no override) must actually disappear, not survive from a stale
      # snapshot the way the fingerprint deliberately does.
      product = product_with_stamped_translation("source")

      {:ok, product} =
        product
        |> Ecto.Changeset.change(%{
          metadata: Map.put(product.metadata, "_price_modifiers", %{"size" => %{"L" => "5.00"}})
        })
        |> repo().update()

      {:ok, view, _html} = live(conn, "/en/admin/shop/products/#{product.uuid}/edit")

      view
      |> form("form.space-y-6", %{"product" => %{"vendor" => "Acme"}})
      |> render_submit()

      reloaded = Shop.get_product!(product.uuid)
      assert reloaded.vendor == "Acme"
      # The submitted form carried no `_price_modifiers` inputs at all
      # (no matching option schema), so the form's own cleanup path
      # removes the key outright — that must still take effect through
      # the merge, not be resurrected from the pre-save snapshot.
      refute Map.has_key?(reloaded.metadata, "_price_modifiers")

      # And the fingerprint from the OTHER key the form doesn't own is
      # still untouched by any of this.
      assert FP.get(reloaded.metadata, @target_lang, "description") ==
               FP.hash("source")
    end
  end
end
