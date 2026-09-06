defmodule PhoenixKitEcommerce.Options.OptionLabelsTest do
  @moduledoc """
  `Options.get_selectable_specs_for_product/1`'s DISCOVERED options (a
  key found in `metadata["_option_values"]` with no admin-configured
  schema entry — the catalogue source's attribute sets have none) read
  their label from `metadata["_option_labels"]` (`View.product_view/2`'s
  synthesized `%{set_slug => set display name}`, 2026-09-06 plan Task 3)
  before falling back to a `humanize_key/1` guess of the raw key.

  Uses `DataCase` (not a plain `ExUnit.Case`) because
  `get_selectable_specs_for_product/1` reads global/category option
  config through `Repo` (`Options.get_global_options/0`) even for a
  product with no schema entries at all — on a clean test DB that read
  is just an empty `ShopConfig` row, `[]`.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Options
  alias PhoenixKitEcommerce.Product

  defp product(metadata) do
    %Product{metadata: metadata, category_uuid: nil}
  end

  describe "get_selectable_specs_for_product/1 — discovered option labels" do
    test "reads the label from _option_labels when present" do
      # "Couleur" (not "Color", `humanize_key/1`'s guess for the bare key)
      # so a passing assertion actually proves `_option_labels` was read,
      # not merely that the fallback happens to agree with it.
      specs =
        product(%{
          "_option_values" => %{"color" => ["Red", "Blue"]},
          "_option_labels" => %{"color" => "Couleur"}
        })
        |> Options.get_selectable_specs_for_product()

      assert [%{"key" => "color", "label" => "Couleur"}] = specs
    end

    test "falls back to humanize_key/1 when _option_labels has no entry for the key" do
      specs =
        product(%{"_option_values" => %{"main_color" => ["Red"]}})
        |> Options.get_selectable_specs_for_product()

      assert [%{"key" => "main_color", "label" => "Main Color"}] = specs
    end

    test "falls back to humanize_key/1 when _option_labels is present but blank for the key" do
      specs =
        product(%{
          "_option_values" => %{"color" => ["Red"]},
          "_option_labels" => %{"color" => ""}
        })
        |> Options.get_selectable_specs_for_product()

      assert [%{"key" => "color", "label" => "Color"}] = specs
    end
  end

  describe "get_price_affecting_specs_for_product/1 — discovered option labels" do
    test "reads the label from _option_labels when present" do
      specs =
        product(%{
          "_option_values" => %{"color" => ["Red", "Blue"]},
          "_price_modifiers" => %{"color" => %{"Red" => "5.00"}},
          "_option_labels" => %{"color" => "Couleur"}
        })
        |> Options.get_price_affecting_specs_for_product()

      assert [%{"key" => "color", "label" => "Couleur"}] = specs
    end
  end
end
