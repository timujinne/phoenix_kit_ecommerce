defmodule PhoenixKitEcommerce.BaseCurrencyChangeSupportedTest do
  @moduledoc """
  A base-currency change is refused on a catalogue-backed shop, and a screen
  offering the change can learn that — with the same reason — before its
  confirmation step.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ShopConfig

  defp set_product_source(value) do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config
        |> ShopConfig.changeset(%{value: %{"value" => value}})
        |> Repo.update!()
    end
  end

  test "the legacy source supports the change" do
    assert Shop.base_currency_change_supported() == :ok
  end

  @tag :catalogue
  test "the catalogue source refuses, with the reason reprice_for_base_change/3 gives" do
    set_product_source("catalogue")
    on_exit(fn -> set_product_source("legacy") end)

    refusal = {:error, {:unsupported_product_source, ProductSource.Catalogue}}

    assert Shop.base_currency_change_supported() == refusal
    assert Shop.reprice_for_base_change("USD", "EUR", Decimal.new("0.9")) == refusal

    assert Shop.Errors.message(elem(refusal, 1)) =~
             "Catalogue-backed shops cannot change their base currency yet"
  end
end
