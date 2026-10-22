defmodule PhoenixKitEcommerce.Web.ShippingPointFieldTest do
  @moduledoc """
  A `:pickup_point` setting of a provider (the branch the sender hands parcels
  over at) in the "Shipping cost calculation" card: listed for the city picked
  in the locality field it names, chosen from the list, stored like a locality.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Integrations.Providers
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Shipping.{Field, Locality, PickupPoint, Service}
  alias PhoenixKitEcommerce.Test.Shipping.{PointFieldProvider, StubProvider}

  @form "#shipping-method-form"
  @provider_target ["shipping_method", "shipping_provider", "provider"]

  setup %{conn: conn} do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [PointFieldProvider])
    Providers.clear_cache()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)

      Providers.clear_cache()
    end)

    stub(%{localities: &city_search/1, points: &points/3})

    %{conn: put_test_scope(conn, fake_scope())}
  end

  describe "the field description" do
    test "keeps the city it depends on through the map form" do
      field = %Field{key: "p", label: "P", type: :pickup_point, locality_key: "c"}

      assert %Field{type: :pickup_point, locality_key: "c"} =
               field |> Field.to_map() |> Field.from_map()
    end
  end

  describe "before the city is chosen" do
    test "the field waits for it and asks nothing of the carrier", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)

      assert has_element?(view, "#shipping-provider-setting-sender_point")

      assert has_element?(
               view,
               "#shipping-locality-waiting-sender_point",
               "Choose the city first"
             )

      refute has_element?(view, "#shipping-locality-query-sender_point")
      refute_received {:stub_called, :list_pickup_points, _}
    end
  end

  describe "once the city is chosen" do
    test "its branches are listed at once, for a service that ships to points", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)

      refute has_element?(view, "#shipping-locality-waiting-sender_point")
      assert has_element?(view, "#shipping-locality-query-sender_point")
      assert has_element?(view, "#shipping-locality-option-sender_point-0", "Branch 1")
      assert has_element?(view, "#shipping-locality-option-sender_point-0", "1 Main street")
      assert has_element?(view, "#shipping-locality-option-sender_point-1", "Branch 2")

      assert_received {:stub_called, :list_pickup_points,
                       [%Locality{id: "c-springfield"}, "branch", nil]}
    end

    test "they are listed for a point service even when the shop sells the courier",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)

      view
      |> form(@form, %{"shipping_method" => %{"shipping_provider" => %{"service" => "courier"}}})
      |> render_change()

      pick_city(view)

      assert has_element?(view, "#shipping-locality-option-sender_point-0", "Branch 1")
      assert_received {:stub_called, :list_pickup_points, [_, "branch", nil]}
    end

    test "nothing is asked of the carrier when no service ships to points", %{conn: conn} do
      stub(%{
        localities: &city_search/1,
        points: &points/3,
        services: [%Service{key: "courier", label: "Courier", destination: :address}]
      })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)

      assert has_element?(view, "#shipping-locality-selected-sender_city", "Springfield")
      refute has_element?(view, "#shipping-locality-option-sender_point-0")
      refute_received {:stub_called, :list_pickup_points, _}
    end

    test "a big city lists the first 50 branches, says so, and leaves out a branch with no id",
         %{conn: conn} do
      many =
        [
          %PickupPoint{id: nil, number: "0", name: "Ghost", address: "nowhere"},
          %PickupPoint{id: "b-x", number: "0", name: nil, address: "Nameless street"}
        ] ++
          for n <- 1..60, do: %PickupPoint{id: "b-#{n}", number: "#{n}", name: "Branch #{n}"}

      stub(%{localities: &city_search/1, points: many})
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)

      assert has_element?(view, "#shipping-locality-option-sender_point-0", "Branch 1")
      assert has_element?(view, "#shipping-locality-option-sender_point-49", "Branch 50")
      refute has_element?(view, "#shipping-locality-option-sender_point-50")
      refute has_element?(view, "#shipping-locality-results-sender_point", "Ghost")
      refute has_element?(view, "#shipping-locality-results-sender_point", "Nameless street")
      assert has_element?(view, "#shipping-locality-truncated-sender_point", "50")
    end

    test "exactly 50 branches fit and are not marked as cut", %{conn: conn} do
      fifty = for n <- 1..50, do: %PickupPoint{id: "b-#{n}", number: "#{n}", name: "Branch #{n}"}

      stub(%{localities: &city_search/1, points: fifty})
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)

      assert has_element?(view, "#shipping-locality-option-sender_point-49", "Branch 50")
      refute has_element?(view, "#shipping-locality-truncated-sender_point")
    end

    test "a list that fits is not marked as cut", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)

      assert has_element?(view, "#shipping-locality-option-sender_point-1")
      refute has_element?(view, "#shipping-locality-truncated-sender_point")
    end

    test "the words typed narrow the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)

      search(view, "sender_point", "2")

      assert has_element?(view, "#shipping-locality-option-sender_point-0", "Branch 2")
      refute has_element?(view, "#shipping-locality-option-sender_point-1")
      assert_received {:stub_called, :list_pickup_points, [_, "branch", "2"]}
    end

    test "a carrier that fails is reported, not an empty list", %{conn: conn} do
      stub(%{localities: &city_search/1, points: {:error, :timeout}})
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)

      assert has_element?(view, "#shipping-locality-results-sender_point", "unavailable")
    end

    test "picking a branch stores it with its id and name, and the method keeps it",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)

      view |> element("#shipping-locality-option-sender_point-1") |> render_click()

      assert has_element?(view, "#shipping-locality-selected-sender_point", "Branch 2")
      assert has_element?(view, "#shipping-provider-setting-sender_point-id[value='b-2']")
      refute has_element?(view, "#shipping-locality-option-sender_point-0")

      view
      |> form(@form, %{"shipping_method" => %{"name" => "With a point", "price" => "10"}})
      |> render_submit()

      method = Enum.find(Shop.list_shipping_methods(), &(&1.name == "With a point"))

      assert get_in(method.metadata, ["shipping_provider", "settings", "sender_point"]) ==
               %{"id" => "b-2", "name" => "Branch 2"}
    end

    test "clearing the branch lists them again", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)
      view |> element("#shipping-locality-option-sender_point-0") |> render_click()
      refute has_element?(view, "#shipping-locality-option-sender_point-1")

      view |> element("#shipping-locality-clear-sender_point") |> render_click()
      render_async(view)

      refute has_element?(view, "#shipping-locality-selected-sender_point")
      assert has_element?(view, "#shipping-locality-option-sender_point-1", "Branch 2")
    end
  end

  describe "when the city changes" do
    test "the branch of the old city is dropped and the new city's are listed",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)
      view |> element("#shipping-locality-option-sender_point-0") |> render_click()
      assert has_element?(view, "#shipping-locality-selected-sender_point")

      view |> element("#shipping-locality-clear-sender_city") |> render_click()

      refute has_element?(view, "#shipping-locality-selected-sender_point")
      assert has_element?(view, "#shipping-locality-waiting-sender_point")

      pick_city(view, 1)

      refute has_element?(view, "#shipping-locality-selected-sender_point")
      assert has_element?(view, "#shipping-locality-option-sender_point-0", "Branch 1")
      assert_received {:stub_called, :list_pickup_points, [%Locality{id: "c-spruce"}, _, nil]}
    end
  end

  describe "when the same city is picked again" do
    test "the chosen branch stays", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)
      pick_city(view)
      view |> element("#shipping-locality-option-sender_point-1") |> render_click()
      assert has_element?(view, "#shipping-locality-selected-sender_point", "Branch 2")

      pick_city(view, 0)

      assert has_element?(view, "#shipping-locality-selected-sender_point", "Branch 2")
      assert has_element?(view, "#shipping-provider-setting-sender_point-id[value='b-2']")
    end
  end

  describe "the label of a field that waits for its city" do
    test "points at no input until the input is there", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view)

      assert has_element?(view, "#shipping-locality-waiting-sender_point")
      refute has_element?(view, "label[for='shipping-locality-query-sender_point']")

      pick_city(view)

      assert has_element?(view, "label[for='shipping-locality-query-sender_point']")
      assert has_element?(view, "#shipping-locality-query-sender_point")
    end
  end

  describe "editing a method that has a city but no branch" do
    test "the branches are listed once the services are known", %{conn: conn} do
      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Saved #{System.unique_integer([:positive])}",
          "price" => "5",
          "shipping_provider" => %{
            "provider" => "point_stub",
            "service" => "courier",
            "settings" => %{"sender_city" => %{"id" => "c-springfield", "name" => "Springfield"}}
          }
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")
      render_async(view)

      assert has_element?(view, "#shipping-locality-option-sender_point-0", "Branch 1")
    end

    test "a branch that is saved is shown and nothing is asked of the carrier", %{conn: conn} do
      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Saved #{System.unique_integer([:positive])}",
          "price" => "5",
          "shipping_provider" => %{
            "provider" => "point_stub",
            "service" => "branch",
            "settings" => %{
              "sender_city" => %{"id" => "c-springfield", "name" => "Springfield"},
              "sender_point" => %{"id" => "b-9", "name" => "Branch 9"}
            }
          }
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")
      render_async(view)

      assert has_element?(view, "#shipping-locality-selected-sender_point", "Branch 9")
      refute_received {:stub_called, :list_pickup_points, _}
    end
  end

  defp stub(config), do: StubProvider.put(Map.put_new(config, :notify, self()))

  defp city_search(query) do
    {:ok,
     [
       %Locality{id: "c-springfield", name: "Springfield", region: "Springfield oblast"},
       %Locality{id: "c-spruce", name: "Sprucewood", region: "Springfield oblast"}
     ]
     |> Enum.filter(&String.starts_with?(String.downcase(&1.name), String.downcase(query)))}
  end

  defp points(_locality, _service, query) do
    {:ok,
     [
       %PickupPoint{id: "b-1", number: "1", name: "Branch 1", address: "1 Main street"},
       %PickupPoint{id: "b-2", number: "2", name: "Branch 2", address: "2 Main street"}
     ]
     |> Enum.filter(&(is_nil(query) or String.contains?(&1.name, query)))}
  end

  defp choose_provider(view) do
    view
    |> form(@form, %{"shipping_method" => %{"shipping_provider" => %{"provider" => "point_stub"}}})
    |> render_change(%{"_target" => @provider_target})

    render_async(view)
  end

  defp pick_city(view, index \\ 0) do
    search(view, "sender_city", "Spr")
    view |> element("#shipping-locality-option-sender_city-#{index}") |> render_click()
    render_async(view)
  end

  defp search(view, key, query) do
    view
    |> element("#shipping-locality-search-#{key}")
    |> render_change(%{"locality_query" => %{key => query}})

    render_async(view)
  end
end
