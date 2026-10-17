defmodule PhoenixKitEcommerce.API.ClaimsCatalogueTest do
  @moduledoc """
  The checkout claim's "add" merge on the catalogue source: the API cart's
  option lines are matched to the product as the buyer's language shows it
  (a value labelled `Red` in English and `Rouge` in French, keyed `red`), join
  an identical line of the browser cart, and are added with the label of the
  claim's language.

  Needs `phoenix_kit_catalogue` loaded (`:catalogue`). `async: false`: flips the
  process-wide `shop_product_source` key.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :requires_core_api
  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}
  @compile {:no_warn_undefined, PhoenixKitEntities.EntityData}

  import PhoenixKitEcommerce.CartApiFixtures
  import PhoenixKitEcommerce.SearchFixtures, only: [catalogue_item!: 2, catalogue_source!: 0]

  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.SelectedSpecs
  alias PhoenixKitEntities.EntityData

  setup do
    put_secret!()
    ensure_currencies!()
    catalogue = catalogue_source!()
    AttributeSets.register_deletion_guard()
    Settings.update_setting("entities_enabled", "true")

    vase = catalogue_item!(catalogue, "Vase")
    attach_translated_color!(vase)
    plain = catalogue_item!(catalogue, "Spoon")

    token = new_token!()
    {:ok, hash} = CartToken.verify(token)

    input = %{
      "items" => [
        %{
          "product_id" => vase.uuid,
          "quantity" => 2,
          "options" => [%{"attribute_key" => "color", "value_key" => "red"}]
        }
      ]
    }

    {:ok, _} = CartWriter.set_items(hash, input, ctx_for(token, %{language: "en-US"}))
    {:ok, cart} = CartStore.resolve(hash)
    {:ok, %{token: raw}} = Claims.issue(cart, hash, "fr-FR")

    %{vase: vase, plain: plain, raw: raw, api_cart: cart}
  end

  # One attribute set "color" with the value "Red", translated for fr-FR.
  defp attach_translated_color!(item) do
    actor = [actor_uuid: Ecto.UUID.generate()]
    {:ok, set} = AttributeSets.create_set(%{name: "Color", slug: "color"}, actor)
    {:ok, value} = AttributeSets.create_value(set, %{label: "Red", slug: "red"}, actor)

    {:ok, _} =
      EntityData.update(
        value,
        %{data: %{"_primary_language" => "en-US", "fr-FR" => %{"_title" => "Rouge"}}},
        activity_log: false
      )

    {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)
    :ok = AttributeSets.set_attachment_selection(item.uuid, set.uuid, ["red"])
  end

  defp browser_cart!(lines) do
    session_id = "browser-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)

    cart =
      Enum.reduce(lines, cart, fn {product, quantity, specs}, acc ->
        {:ok, updated} =
          Shop.add_to_cart(acc, product, quantity, selected_specs: specs, language: "fr-FR")

        updated
      end)

    {%{session_id: session_id}, cart}
  end

  defp french(item), do: Loader.load([item.uuid], language: "fr-FR")[item.uuid].product

  defp lines(cart) do
    cart.uuid
    |> Shop.get_cart()
    |> Map.fetch!(:items)
    |> Map.new(
      &{{&1.product_uuid || &1.metadata["catalogue_item_uuid"], &1.selected_specs}, &1.quantity}
    )
  end

  test "an option line joins the identical line the buyer already has, in the claim's language",
       ctx do
    {browser, mine} = browser_cart!([{french(ctx.vase), 1, %{"color" => "red"}}])

    assert {:ok, %{mode: :merged, skipped: []}} =
             redeem_shown(ctx.raw, browser, %{offer: mine.uuid, choice: "add"})

    assert [{_product, specs}] = Map.keys(lines(mine))
    assert specs == %{"color" => "red"}
    assert lines(mine) |> Map.values() == [3]
  end

  test "an option line the buyer does not have is added with the claim's label", ctx do
    {browser, mine} = browser_cart!([{french(ctx.plain), 1, %{}}])

    assert {:ok, %{mode: :merged, skipped: []}} =
             redeem_shown(ctx.raw, browser, %{offer: mine.uuid, choice: "add"})

    by_specs = Map.new(lines(mine), fn {{_product, specs}, quantity} -> {specs, quantity} end)
    assert by_specs == %{%{} => 1, %{"color" => "red"} => 2}

    assert [added] = Enum.filter(Shop.get_cart(mine.uuid).items, &(&1.selected_specs != %{}))
    assert SelectedSpecs.labels(added) == %{"color" => "Rouge"}
  end
end
