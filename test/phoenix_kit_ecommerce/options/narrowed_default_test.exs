defmodule PhoenixKitEcommerce.Options.NarrowedDefaultTest do
  @moduledoc """
  `Options.get_selectable_specs_for_product/1` narrows a schema option's
  `"options"` list to the product's own `metadata["_option_values"]`
  (`filter_by_product_option_values/2`) — needed so the picker offers,
  and `validate_selected_specs/2` accepts, the product's own value list
  (on the catalogue source, per Task 3, a PER-LANGUAGE translated list,
  not the admin schema's untranslated one). An admin-configured
  `"default"` was never re-checked against that narrowed list: on a page
  where the product's own values no longer include the admin's default
  (typically a translated label replacing the untranslated one),
  `build_default_specs/2` (`catalog_product.ex`) still seeded
  `selected_specs` with the stale default, and clicking Add to Cart
  without touching the picker got `{:error, :invalid_option_value, ...}`
  — a shopper could not buy a product with priced options in a language
  other than the shop's primary one (2026-09-06 plan review, blocker 2).

  Uses `DataCase` because `get_selectable_specs_for_product/1` reads the
  global option schema through `Repo` even for a product with no schema
  entries of its own (see `option_labels_test.exs`'s moduledoc).
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.Product

  defp product(metadata), do: %Product{metadata: metadata, category_uuid: nil}

  defp configure_color_schema do
    Options.update_global_options([
      %{
        "key" => "color",
        "label" => "Color",
        "type" => "select",
        "options" => ["Red", "Blue"],
        "default" => "Red",
        "position" => 0
      }
    ])
  end

  test "drops a schema default the product's own (translated) value list no longer offers" do
    {:ok, _} = configure_color_schema()

    specs =
      product(%{"_option_values" => %{"color" => ["Rouge", "Bleu"]}})
      |> Options.get_selectable_specs_for_product()

    assert [%{"key" => "color", "options" => narrowed} = spec] = specs
    assert narrowed == ["Rouge", "Bleu"]
    refute Map.has_key?(spec, "default")
  end

  test "keeps the default when it is still one of the product's own values" do
    {:ok, _} = configure_color_schema()

    specs =
      product(%{"_option_values" => %{"color" => ["Red", "Blue"]}})
      |> Options.get_selectable_specs_for_product()

    assert [%{"key" => "color", "default" => "Red"}] = specs
  end
end
