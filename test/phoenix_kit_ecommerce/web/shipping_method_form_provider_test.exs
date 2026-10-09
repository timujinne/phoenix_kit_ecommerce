defmodule PhoenixKitEcommerce.Web.ShippingMethodFormProviderTest do
  @moduledoc """
  The "Shipping cost calculation" card of the shipping method form and the
  provider badge of the shipping method list, driven through a stub provider
  registered in the app env.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Integrations
  alias PhoenixKit.Integrations.Providers
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Shipping.Locality
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @form "#shipping-method-form"

  setup %{conn: conn} do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])
    # The Integrations registry is cached in a persistent term: rebuilt here so
    # it lists the stub, and again on exit so no other test sees it.
    Providers.clear_cache()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)

      Providers.clear_cache()
    end)

    StubProvider.put(%{
      localities: fn query ->
        {:ok,
         [
           %Locality{id: "c-poltava", name: "Poltava", region: "Poltava oblast"},
           %Locality{id: "c-pol", name: "Polonne", region: "Khmelnytskyi oblast"}
         ]
         |> Enum.filter(&String.starts_with?(String.downcase(&1.name), String.downcase(query)))}
      end
    })

    %{conn: put_test_scope(conn, fake_scope())}
  end

  describe "the provider card" do
    test "offers the built-in and the registered providers, fixed price by default",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      assert has_element?(view, "#shipping-provider-card")
      assert has_element?(view, "#shipping-provider-select option[value='fixed'][selected]")
      assert has_element?(view, "#shipping-provider-select option[value='table']")
      assert has_element?(view, "#shipping-provider-select option[value='stub']")

      # A fixed price asks for no service and no markup.
      refute has_element?(view, "#shipping-service-select")
      refute has_element?(view, "#shipping-provider-pricing")
      refute has_element?(view, "#shipping-provider-fallback-hint")
      assert has_element?(view, "#shipping-provider-setting-destination")
    end

    test "choosing a provider shows its services, settings, markup and fallback hint",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      choose_provider(view, "stub")

      assert has_element?(view, "#shipping-service-select option[value='branch'][selected]")
      assert has_element?(view, "#shipping-service-select option[value='courier']")
      assert has_element?(view, "#shipping-provider-setting-sender_city")
      assert has_element?(view, "#shipping-locality-query-sender_city")
      assert has_element?(view, "#shipping-provider-pricing")
      assert has_element?(view, "#shipping-pricing-markup_percent")
      assert has_element?(view, "#shipping-pricing-markup_fixed")
      assert has_element?(view, "#shipping-pricing-round_to")
      assert has_element?(view, "#shipping-provider-fallback-hint")
      # No error is shown for settings the admin has not had a chance to fill.
      refute has_element?(view, "#shipping-provider-errors")
    end

    test "choosing a provider resets what was typed for the previous one", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      choose_provider(view, "table")
      assert has_element?(view, "#shipping-provider-setting-rates")

      view
      |> form(@form, %{
        "shipping_method" => %{"shipping_provider" => %{"settings" => %{"rates" => "1 90"}}}
      })
      |> render_change()

      assert render(element(view, "#shipping-provider-setting-rates")) =~ "1 90"

      choose_provider(view, "stub")
      refute has_element?(view, "#shipping-provider-setting-rates")
      assert has_element?(view, "#shipping-provider-setting-sender_city")

      choose_provider(view, "table")
      refute render(element(view, "#shipping-provider-setting-rates")) =~ "1 90"
    end

    test "a provider with an integration shows the connection and links to Integrations",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      choose_provider(view, "stub")

      assert has_element?(view, "#shipping-provider-integration")
      assert render(element(view, "#shipping-provider-integration-status")) =~ "not connected"

      assert render(element(view, "#shipping-provider-integration-link")) =~
               "/admin/settings/integrations"

      choose_provider(view, "table")
      refute has_element?(view, "#shipping-provider-integration")
    end

    test "the connection is shown as connected once the integration has credentials",
         %{conn: conn} do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("stub", "Stub account")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "secret"})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      status = render(element(view, "#shipping-provider-integration-status"))
      assert status =~ "connected"
      refute status =~ "not connected"
    end

    test "services the carrier cannot list are reported and do not break the form",
         %{conn: conn} do
      StubProvider.put(%{modes: %{services: :crash}})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      assert has_element?(view, "#shipping-services-error")
      assert has_element?(view, "#shipping-service-select")
    end
  end

  describe "locality autocomplete" do
    test "search, pick and save stores the provider block", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      search_locality(view, "sender_city", "Pol")

      assert has_element?(view, "#shipping-locality-results-sender_city")
      assert has_element?(view, "#shipping-locality-option-sender_city-0", "Poltava")
      assert has_element?(view, "#shipping-locality-option-sender_city-1", "Polonne")

      view |> element("#shipping-locality-option-sender_city-0") |> render_click()

      assert has_element?(view, "#shipping-locality-selected-sender_city", "Poltava")
      assert has_element?(view, "#shipping-provider-setting-sender_city-id[value='c-poltava']")
      assert has_element?(view, "#shipping-provider-setting-sender_city-name[value='Poltava']")
      refute has_element?(view, "#shipping-locality-option-sender_city-0")

      view
      |> form(@form, %{
        "shipping_method" => %{
          "name" => "Stub carrier",
          "price" => "70.00",
          "shipping_provider" => %{
            "pricing" => %{"markup_percent" => "10", "round_to" => "5"}
          }
        }
      })
      |> render_submit()

      method = method_named("Stub carrier")

      assert method.metadata["shipping_provider"] == %{
               "provider" => "stub",
               "service" => "branch",
               "settings" => %{"sender_city" => %{"id" => "c-poltava", "name" => "Poltava"}},
               "pricing" => %{"markup_percent" => "10", "round_to" => "5"}
             }

      assert ShippingMethod.calculated?(method)
      assert Decimal.equal?(method.price, Decimal.new("70.00"))
    end

    test "a short query lists nothing and does not call the carrier", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      search_locality(view, "sender_city", "P")

      refute_received {:stub_called, :search_localities, _}
      refute has_element?(view, "#shipping-locality-option-sender_city-0")
    end

    test "a query nothing matches says so, a failing carrier says it is unavailable",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      search_locality(view, "sender_city", "Zzz")
      assert render(element(view, "#shipping-locality-results-sender_city")) =~ "Nothing found"

      StubProvider.put(%{localities: {:error, :boom}})
      search_locality(view, "sender_city", "Zzzz")
      assert render(element(view, "#shipping-locality-results-sender_city")) =~ "unavailable"
    end

    test "clearing the pick brings the search back and the required error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")
      search_locality(view, "sender_city", "Pol")
      view |> element("#shipping-locality-option-sender_city-0") |> render_click()
      assert has_element?(view, "#shipping-locality-selected-sender_city")

      view |> element("#shipping-locality-clear-sender_city") |> render_click()

      refute has_element?(view, "#shipping-locality-selected-sender_city")
      refute has_element?(view, "#shipping-provider-setting-sender_city-id")
      assert render(element(view, "#shipping-provider-errors")) =~ "sender_city"
    end

    test "a method with the required setting missing is not saved and says why",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      view
      |> form(@form, %{"shipping_method" => %{"name" => "Nowhere", "price" => "1"}})
      |> render_submit()

      assert render(element(view, "#shipping-provider-errors")) =~ "sender_city"
      refute method_named("Nowhere")
    end
  end

  describe "editing" do
    test "shows the stored provider block and switching back to fixed removes it",
         %{conn: conn} do
      method = stub_method!("Stored stub", pay_on_delivery: true)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      assert has_element?(view, "#shipping-provider-select option[value='stub'][selected]")
      assert has_element?(view, "#shipping-service-select option[value='courier'][selected]")
      assert has_element?(view, "#shipping-locality-selected-sender_city", "Lviv")
      assert has_element?(view, "#shipping-pricing-markup_percent[value='15']")

      choose_provider(view, "fixed")
      refute has_element?(view, "#shipping-service-select")
      refute has_element?(view, "#shipping-provider-pricing")

      view |> form(@form) |> render_submit()

      method = Shop.get_shipping_method!(method.uuid)
      refute Map.has_key?(method.metadata, "shipping_provider")
      refute ShippingMethod.calculated?(method)
      # Unrelated metadata survives.
      assert ShippingMethod.pay_on_delivery?(method)
    end

    test "a plain fixed price with an address stores the fixed block", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      view
      |> form(@form, %{
        "shipping_method" => %{
          "name" => "Courier flat",
          "price" => "9.00",
          "shipping_provider" => %{"settings" => %{"destination" => "address"}}
        }
      })
      |> render_submit()

      assert method_named("Courier flat").metadata["shipping_provider"] == %{
               "provider" => "fixed",
               "service" => "default",
               "settings" => %{"destination" => "address"}
             }
    end

    test "saving without touching the card leaves a fixed method without a block",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      view
      |> form(@form, %{"shipping_method" => %{"name" => "Plain", "price" => "3.00"}})
      |> render_submit()

      refute Map.has_key?(method_named("Plain").metadata, "shipping_provider")
    end

    test "a provider the host no longer registers stays selected", %{conn: conn} do
      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Gone #{System.unique_integer([:positive])}",
          "price" => "1",
          "metadata" => %{"shipping_provider" => %{"provider" => "gone", "service" => "x"}}
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      assert has_element?(view, "#shipping-provider-select option[value='gone'][selected]")
    end
  end

  describe "list" do
    test "shows the provider of each method as a badge", %{conn: conn} do
      fixed = fixed_method!("Flat rate")
      stub = stub_method!("Stub rate", [])
      {:ok, table} = create_method("Table rate", %{"shipping_provider" => table_param()})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping")

      assert render(element(view, "#shipping-method-provider-#{fixed.uuid}")) =~ "Fixed price"
      assert render(element(view, "#shipping-method-provider-#{stub.uuid}")) =~ "Stub carrier"

      assert render(element(view, "#shipping-method-provider-#{table.uuid}")) =~
               "Rate table by weight"
    end
  end

  # -- helpers -----------------------------------------------------------

  defp choose_provider(view, provider) do
    view
    |> form(@form, %{"shipping_method" => %{"shipping_provider" => %{"provider" => provider}}})
    |> render_change()
  end

  defp search_locality(view, key, query) do
    view
    |> form(@form, %{"shipping_locality_query" => %{key => query}})
    |> render_change()

    render_async(view)
  end

  defp method_named(name),
    do: Enum.find(Shop.list_shipping_methods(), &(&1.name == name))

  defp create_method(name, attrs) do
    Shop.create_shipping_method(
      Map.merge(
        %{"name" => "#{name} #{System.unique_integer([:positive])}", "price" => "5"},
        attrs
      )
    )
  end

  defp fixed_method!(name) do
    {:ok, method} = create_method(name, %{})
    method
  end

  defp table_param do
    %{"provider" => "table", "service" => "default", "settings" => %{"rates" => "1 90"}}
  end

  defp stub_method!(name, opts) do
    {:ok, method} =
      create_method(name, %{
        "pay_on_delivery" => Keyword.get(opts, :pay_on_delivery, false),
        "shipping_provider" => %{
          "provider" => "stub",
          "service" => "courier",
          "settings" => %{"sender_city" => %{"id" => "c-lviv", "name" => "Lviv"}},
          "pricing" => %{"markup_percent" => "15"}
        }
      })

    method
  end
end
