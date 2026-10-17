defmodule PhoenixKitEcommerce.SearchFixtures do
  @moduledoc """
  Fixtures for the public-search tests: enabled languages, legacy products and
  categories, and (behind the optional catalogue dependency) catalogue items.

  Every write lands in the test's sandbox transaction, so nothing here needs a
  cleanup, including the `shop_product_source` switch.
  """

  # The catalogue is an optional dependency; the functions below are only
  # reached from tests tagged :catalogue.
  @compile {:no_warn_undefined,
            [PhoenixKitCatalogue.Catalogue, PhoenixKitCatalogue.Schemas.Category]}

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.Settings
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Search.Indexer
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  @doc "Switches the Languages module on with `codes`; the first one is the default."
  def enable_languages!(codes) when is_list(codes) do
    {:ok, _} = Settings.update_boolean_setting_with_module("languages_enabled", true, "languages")

    languages =
      codes
      |> Enum.with_index()
      |> Enum.map(fn {code, index} ->
        %{"code" => code, "name" => code, "is_default" => index == 0, "is_enabled" => true}
      end)

    {:ok, _} =
      Settings.update_json_setting_with_module(
        "languages_config",
        %{"languages" => languages},
        "languages"
      )

    :ok
  end

  def disable_languages! do
    {:ok, _} =
      Settings.update_boolean_setting_with_module("languages_enabled", false, "languages")

    :ok
  end

  @doc ~s|A legacy category; `names` is the localized map, e.g. `%{"en" => "Vases"}`.|
  def legacy_category!(names, attrs \\ %{}) when is_map(names) do
    {:ok, category} = Shop.create_category(Map.merge(%{name: names}, attrs))
    category
  end

  @doc ~s|An active legacy product; `titles` is the localized map. `attrs` may carry `price: "12.50"`.|
  def legacy_product!(titles, attrs \\ %{}) when is_map(titles) do
    base = %{title: titles, price: Decimal.new("10.00"), status: "active"}
    attrs = Map.new(attrs, fn {key, value} -> {key, decimal_field(key, value)} end)
    {:ok, product} = Shop.create_product(Map.merge(base, attrs))
    product
  end

  # Raw bytes the lower-casing of a mangled id cannot disturb: none is an ASCII
  # upper-case letter.
  @raw_safe_uuid "10203060-7080-7090-a0b0-c0d0e0f01020"

  @doc """
  An active legacy product whose uuid, written as 16 raw bytes, no
  lower-casing changes. Returns `{product, raw}`: `raw` is the 16-byte string
  `Ecto.UUID.cast/1` takes for that uuid and no API caller can send as an id.
  """
  def raw_uuid_product!(titles) do
    product = legacy_product!(titles)

    # One statement: the slug rows reference the product, and the check runs at its end.
    Repo.query!(
      """
      WITH moved AS (UPDATE phoenix_kit_shop_products SET uuid = $2 WHERE uuid = $1 RETURNING 1)
      UPDATE phoenix_kit_shop_product_slugs SET product_uuid = $2 WHERE product_uuid = $1
      """,
      [Ecto.UUID.dump!(product.uuid), Ecto.UUID.dump!(@raw_safe_uuid)]
    )

    {%{product | uuid: @raw_safe_uuid}, Ecto.UUID.dump!(@raw_safe_uuid)}
  end

  defp decimal_field(key, value) when key in [:price, :compare_at_price] and is_binary(value),
    do: Decimal.new(value)

  defp decimal_field(_key, value), do: value

  @doc ~s|Writes the `shop_product_source` key (`"legacy"` or `"catalogue"`).|
  def set_product_source!(value) when value in ["legacy", "catalogue"] do
    case Repo.get(ShopConfig, "shop_product_source") do
      nil ->
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "shop_product_source", value: %{"value" => value}})
        |> Repo.insert!()

      config ->
        config |> ShopConfig.changeset(%{value: %{"value" => value}}) |> Repo.update!()
    end

    :ok
  end

  @doc "Switches the shop to the catalogue source and creates its catalogue (`decor3dprint`)."
  def catalogue_source! do
    set_product_source!("catalogue")
    {:ok, catalogue} = Catalogue.create_catalogue(%{name: "decor3dprint"})
    catalogue
  end

  def catalogue_category!(catalogue, name, attrs \\ %{}) do
    {:ok, category} =
      Catalogue.create_category(Map.merge(%{catalogue_uuid: catalogue.uuid, name: name}, attrs))

    category
  end

  @doc """
  Marks a catalogue category `deleted` with a direct write.

  Fixture order matters: `Catalogue.create_item/1` refuses an item in a
  category whose status is `deleted` (`category_uuid: is invalid`), and the
  catalogue's own `trash_category/1` trashes the category's items too (their
  status becomes `deleted`). So "an active item in a deleted category" can only
  exist after a stray write; this helper models exactly that. Create the items
  in the active category first, then call it.
  """
  def delete_category_directly!(category) do
    {1, _} =
      Repo.update_all(
        from(c in PhoenixKitCatalogue.Schemas.Category, where: c.uuid == ^category.uuid),
        set: [status: "deleted"]
      )

    :ok
  end

  @doc "An active, shop-active catalogue item; `attrs` override any default."
  def catalogue_item!(catalogue, name, attrs \\ %{}) do
    base = %{
      catalogue_uuid: catalogue.uuid,
      name: name,
      base_price: Decimal.new("10.00"),
      status: "active",
      data: shop_data("active")
    }

    {:ok, item} = Catalogue.create_item(Map.merge(base, attrs))
    item
  end

  @doc """
  The shop most search tests use (English titles; languages as they are):

      Home
      |- Vases:  Red Ceramic Vase (Acme, gift, 20.00, was 25.00, size Large + colour Red)
      |          Green Vase Small (10.00, made to order, size Small)
      |- Bowls:  Blue Glass Bowl (Beta, 35.00)
      (none):    Wooden Spoon (gift, 5.00, description "handmade from oak")
                 Plant Stand (15.00, description "A stand for a vase")

  Everything is indexed. Returns the uuids: `home`, `vases`, `bowls` (categories)
  and `a` Red Ceramic Vase, `b` Blue Glass Bowl, `c` Green Vase Small,
  `d` Wooden Spoon, `e` Plant Stand.
  """
  def sample_shop! do
    home = legacy_category!(%{"en" => "Home"})
    vases = legacy_category!(%{"en" => "Vases"}, %{parent_uuid: home.uuid})
    bowls = legacy_category!(%{"en" => "Bowls"}, %{parent_uuid: home.uuid})

    a =
      legacy_product!(%{"en" => "Red Ceramic Vase"}, %{
        category_uuid: vases.uuid,
        vendor: "Acme",
        tags: ["gift"],
        price: "20.00",
        compare_at_price: "25.00",
        metadata: %{"_option_values" => %{"size" => ["Large"], "colour" => ["Red"]}}
      })

    b =
      legacy_product!(%{"en" => "Blue Glass Bowl"}, %{
        category_uuid: bowls.uuid,
        vendor: "Beta",
        price: "35.00"
      })

    c =
      legacy_product!(%{"en" => "Green Vase Small"}, %{
        category_uuid: vases.uuid,
        price: "10.00",
        made_to_order: true,
        metadata: %{"_option_values" => %{"size" => ["Small"]}}
      })

    d =
      legacy_product!(%{"en" => "Wooden Spoon"}, %{
        price: "5.00",
        tags: ["gift"],
        description: %{"en" => "handmade from oak"}
      })

    e =
      legacy_product!(%{"en" => "Plant Stand"}, %{
        price: "15.00",
        description: %{"en" => "A stand for a vase"}
      })

    {:ok, _} = Indexer.reindex_items(Enum.map([a, b, c, d, e], & &1.uuid))

    %{
      home: home.uuid,
      vases: vases.uuid,
      bowls: bowls.uuid,
      a: a.uuid,
      b: b.uuid,
      c: c.uuid,
      d: d.uuid,
      e: e.uuid
    }
  end

  @doc """
  Stages a failure of the search text: a stand-in `websearch_to_tsquery` that
  raises `message` with SQLSTATE `sqlstate`, found before pg_catalog on the
  transaction's search path. Nothing a caller can send reaches such a failure,
  so a test stages it. All of it is rolled back with the test's sandbox
  transaction.
  """
  def stage_tsquery_failure!(sqlstate, message) do
    Repo.query!("CREATE SCHEMA search_refusal_stub")
    Repo.query!("SET LOCAL search_path TO search_refusal_stub, pg_catalog, public")

    Repo.query!("""
    CREATE FUNCTION search_refusal_stub.websearch_to_tsquery(regconfig, text)
    RETURNS tsquery LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '#{message}' USING ERRCODE = '#{sqlstate}', DETAIL = 'secret detail';
    END
    $$
    """)
  end

  @doc "Replaces the currency table with USD (base, rate 1) and EUR (rate 0.909091)."
  def currencies! do
    PhoenixKit.Cache.clear(:billing_currencies)
    Repo.delete_all(PhoenixKitBilling.Currency)

    {:ok, usd} =
      PhoenixKitBilling.create_currency(%{
        code: "USD",
        name: "Dollar",
        symbol: "$",
        is_default: true,
        exchange_rate: "1.0"
      })

    {:ok, eur} =
      PhoenixKitBilling.create_currency(%{
        code: "EUR",
        name: "Euro",
        symbol: "€",
        exchange_rate: "0.909091"
      })

    %{usd: usd, eur: eur}
  end

  @doc "The context map the executor hands a public handler (no actor; the tools here do not need one)."
  def public_ctx(overrides \\ []) do
    Map.merge(
      %{
        actor: nil,
        scopes: [],
        audience: :public,
        language: "en",
        currency: nil,
        hosts: ["shop.test"],
        base_url: "https://shop.test",
        request_id: "req-1",
        dry_run?: false
      },
      Map.new(overrides)
    )
  end

  @doc "The `data` map of an item or category with the given shop status."
  def shop_data(shop_status, extra \\ %{}) do
    %{"ecommerce" => Map.merge(%{"shop_status" => shop_status}, extra)}
  end

  # Settings and currencies are cache-backed in a running app; the test run has
  # no cache, so every read of them reaches the database and would drown the
  # queries a measurement is about.
  @cached_tables ~w(phoenix_kit_settings phoenix_kit_currencies)

  @doc """
  The number of repo queries `fun` ran (in this process's sandbox connection),
  not counting the reads of settings and currencies. Warm caches first when two
  measurements are compared.
  """
  def count_queries(fun) when is_function(fun, 0) do
    handler_id = {:query_count, make_ref()}
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        unless Enum.any?(@cached_tables, &String.contains?(metadata.query, ~s|FROM "#{&1}"|)),
          do: send(test_pid, :query_ran)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(handler_id)
    end

    drain_queries(0)
  end

  defp drain_queries(count) do
    receive do
      :query_ran -> drain_queries(count + 1)
    after
      0 -> count
    end
  end
end
