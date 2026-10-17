defmodule PhoenixKitEcommerce.API.CartWriterVisibilityTest do
  @moduledoc """
  What `shop.set_cart_items` may put into a cart is exactly what
  `shop.get_products` shows: `:listed` is addable,
  `:discontinued` is `not_on_sale`, `:hidden` and unknown are `not_found`.
  A product in a hidden or deleted category, in an archived catalogue, or
  with item status inactive or deleted must not pass as "active".
  """

  # async: false - the product source setting and the Hammer counters are shared.
  use PhoenixKitEcommerce.DataCase, async: false
  @moduletag :requires_core_api

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  import PhoenixKitEcommerce.CartApiFixtures
  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartWriter

  setup do
    put_secret!()
    ensure_currencies!()
    token = new_token!()
    {:ok, hash} = CartToken.verify(token)
    %{token: token, hash: hash}
  end

  defp line(product, quantity), do: %{"product_id" => product.uuid, "quantity" => quantity}

  defp set(token, items) do
    {:ok, hash} = CartToken.verify(token)
    CartWriter.set_items(hash, %{"items" => items}, ctx_for(token))
  end

  defp codes(result), do: Enum.map(result.results, &get_in(&1, [:error, :code]))

  describe "legacy source" do
    test "a product in a hidden category is not found, in an unlisted one it is addable", %{
      token: token
    } do
      hidden = legacy_category!(%{"en" => "Hidden"}, %{status: "hidden"})
      unlisted = legacy_category!(%{"en" => "Unlisted"}, %{status: "unlisted"})
      in_hidden = legacy_product!(%{"en" => "In hidden"}, %{category_uuid: hidden.uuid})
      in_unlisted = legacy_product!(%{"en" => "In unlisted"}, %{category_uuid: unlisted.uuid})

      assert {:ok, result} = set(token, [line(in_hidden, 1), line(in_unlisted, 1)])

      assert codes(result) == ["not_found", nil]
      assert [%{quantity: 1}] = result.cart.lines
    end

    test "draft is not found, archived is not on sale, an unknown id is not found", %{
      token: token
    } do
      draft = legacy_product!(%{"en" => "Draft"}, %{status: "draft"})
      archived = legacy_product!(%{"en" => "Archived"}, %{status: "archived"})

      assert {:ok, result} =
               set(token, [
                 line(draft, 1),
                 line(archived, 1),
                 %{"product_id" => Ecto.UUID.generate(), "quantity" => 1}
               ])

      assert codes(result) == ["not_found", "not_on_sale", "not_found"]
    end

    test "a hidden product answers exactly like an unknown one", %{token: token} do
      hidden = legacy_category!(%{"en" => "Hidden"}, %{status: "hidden"})
      in_hidden = legacy_product!(%{"en" => "In hidden"}, %{category_uuid: hidden.uuid})

      assert {:ok, result} =
               set(token, [
                 line(in_hidden, 1),
                 %{"product_id" => Ecto.UUID.generate(), "quantity" => 1}
               ])

      assert [%{error: first}, %{error: second}] = result.results
      assert Map.take(first, [:code, :message]) == Map.take(second, [:code, :message])
    end
  end

  describe "catalogue source" do
    @describetag :catalogue

    setup do
      %{catalogue: catalogue_source!()}
    end

    test "a deleted category, inactive and deleted items are not found, a discontinued item is not on sale",
         %{token: token, catalogue: catalogue} do
      gone = catalogue_category!(catalogue, "Gone")
      in_gone = catalogue_item!(catalogue, "In gone", %{category_uuid: gone.uuid})
      delete_category_directly!(gone)
      inactive = catalogue_item!(catalogue, "Inactive", %{status: "inactive"})
      deleted = catalogue_item!(catalogue, "Deleted", %{status: "deleted"})
      discontinued = catalogue_item!(catalogue, "Discontinued", %{status: "discontinued"})
      fine = catalogue_item!(catalogue, "Fine")

      assert {:ok, result} =
               set(
                 token,
                 Enum.map([in_gone, inactive, deleted, discontinued, fine], &line(&1, 1))
               )

      assert codes(result) == ["not_found", "not_found", "not_found", "not_on_sale", nil]
      assert [%{quantity: 1}] = result.cart.lines
    end

    test "an archived catalogue hides every product, and nothing is created", %{
      token: token,
      hash: hash,
      catalogue: catalogue
    } do
      item = catalogue_item!(catalogue, "Vase")
      {:ok, _} = Catalogue.update_catalogue(catalogue, %{status: "archived"})

      assert {:ok, result} = set(token, [line(item, 1)])

      assert codes(result) == ["not_found"]
      assert CartStore.resolve(hash) == :empty
    end
  end
end
