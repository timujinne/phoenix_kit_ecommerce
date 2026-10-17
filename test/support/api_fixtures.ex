defmodule PhoenixKitEcommerce.APIFixtures do
  @moduledoc """
  Builders for the admin API tests: a shop that reads a catalogue, catalogue
  items, option sets, a request context like the one core's executor builds.

  Needs `phoenix_kit_catalogue` loaded; the tests that use it are tagged
  `:catalogue` / `:catalogue_api` and excluded by `test_helper.exs` otherwise.
  """

  @compile {:no_warn_undefined,
            [PhoenixKitCatalogue.Catalogue, PhoenixKitCatalogue.Catalogue.AttributeSets]}

  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  @doc "Writes a `phoenix_kit_shop_config` row (the product source, the shop catalogue's name)."
  def put_config!(key, value) do
    case Repo.get(ShopConfig, key) do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: key, value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config |> ShopConfig.changeset(%{value: %{"value" => value}}) |> Repo.update!()
    end
  end

  @doc "A catalogue the shop reads: created, named in `shop_catalogue`, product source switched to it."
  def shop_catalogue! do
    name = "api-shop-#{System.unique_integer([:positive])}"
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: name})
    put_config!("shop_product_source", "catalogue")
    put_config!("shop_catalogue", name)
    catalogue
  end

  @doc "A catalogue the shop does not read."
  def other_catalogue! do
    {:ok, catalogue} =
      Catalogue.create_catalogue(%{name: "api-other-#{System.unique_integer([:positive])}"})

    catalogue
  end

  @doc """
  An active, priced, shop-visible item. `attrs` override the defaults; pass
  `data:` to replace `data` as a whole.
  """
  def item!(catalogue, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    defaults = %{
      catalogue_uuid: catalogue.uuid,
      name: "API item #{n}",
      sku: "API-#{n}",
      base_price: Decimal.new("100.00"),
      status: "active",
      data: %{"_primary_language" => "en", "ecommerce" => %{"shop_status" => "active"}}
    }

    {:ok, item} = Catalogue.create_item(Map.merge(defaults, attrs))
    item
  end

  @doc "Reloads an item from the database."
  def reload!(item), do: Catalogue.get_item!(item.uuid)

  @doc "Attaches an option set with `values` (`[{label, slug}]`) to `item`."
  def attach_set!(item, name, slug, values) do
    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")

    actor = [actor_uuid: Ecto.UUID.generate()]
    {:ok, set} = AttributeSets.create_set(%{name: name, slug: slug}, actor)

    for {label, value_slug} <- values do
      {:ok, _} = AttributeSets.create_value(set, %{label: label, slug: value_slug}, actor)
    end

    {:ok, _} = AttributeSets.attach_set(item.uuid, set.uuid)

    :ok =
      AttributeSets.set_attachment_selection(item.uuid, set.uuid, Enum.map(values, &elem(&1, 1)))

    set
  end

  @doc "A real user with catalogue access: the owner of the key and stored files."
  def user! do
    {:ok, _} = PhoenixKit.Settings.update_boolean_setting("catalogue_enabled", true)
    user = PhoenixKitEcommerce.DataCase.fixture_user()

    {:ok, role} =
      Roles.create_role(%{
        name: "EcomCatalogue#{System.unique_integer([:positive])}"
      })

    {:ok, _} = Permissions.grant_permission(role.uuid, "catalogue")
    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  @doc "The handler context core's executor builds for a key call."
  def ctx(user, overrides \\ %{}) do
    Map.merge(
      %{
        actor: %{
          kind: :key,
          key_uuid: Ecto.UUID.generate(),
          key_prefix: "a1b2c3d4",
          user_uuid: user.uuid,
          scopes: []
        },
        audience: :admin,
        language: "en",
        currency: nil,
        hosts: [],
        base_url: "http://localhost",
        request_id: "req-test",
        dry_run?: false
      },
      overrides
    )
  end
end
