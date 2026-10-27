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
  alias PhoenixKitEcommerce.Test.Shipping.{CountryProvider, StubProvider}

  @form "#shipping-method-form"
  @provider_target ["shipping_method", "shipping_provider", "provider"]

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

    stub(%{localities: &city_search/1})

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
      refute has_element?(view, "#shipping-services")
      refute has_element?(view, "#shipping-provider-pricing")
      refute has_element?(view, "#shipping-provider-fallback-hint")
      refute has_element?(view, "#shipping-provider-setting-destination")
      refute has_element?(view, "#shipping-provider-settings")
      refute_received {:stub_called, :services, _}
    end

    test "a provider that declares its countries says which", %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
        StubProvider,
        CountryProvider
      ])

      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA", "PL"])

      on_exit(fn ->
        Application.delete_env(:phoenix_kit_ecommerce, :shipping_country_provider)
      end)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      refute has_element?(view, "#shipping-provider-countries")

      choose_provider(view, "country_stub")
      assert has_element?(view, "#shipping-provider-countries", "Delivers to: UA, PL")

      choose_provider(view, "stub")
      refute has_element?(view, "#shipping-provider-countries")
    end

    test "choosing a provider shows its services, settings, markup and fallback hint",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      choose_provider(view, "stub")

      # Every service the provider offers is ticked to begin with.
      assert has_element?(view, "#shipping-service-branch[checked]")
      assert has_element?(view, "#shipping-service-courier[checked]")
      assert has_element?(view, "#shipping-provider-setting-sender_city")
      assert has_element?(view, "#shipping-locality-query-sender_city")
      assert has_element?(view, "#shipping-provider-pricing")
      assert has_element?(view, "#shipping-pricing-markup_percent")
      assert has_element?(view, "#shipping-pricing-markup_fixed")
      assert has_element?(view, "#shipping-pricing-round_to[placeholder='No rounding']")
      assert has_element?(view, "#shipping-pricing-round-to-help")
      assert has_element?(view, "#shipping-provider-fallback-hint")
      # No error is shown for settings the admin has not had a chance to fill.
      refute has_element?(view, "#shipping-provider-errors")
      refute has_element?(view, "#shipping-provider-error-setting-sender_city")
    end

    test "the fallback hint goes away while the method is paid on delivery", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")
      assert has_element?(view, "#shipping-provider-fallback-hint")

      view
      |> form(@form, %{"shipping_method" => %{"pay_on_delivery" => "true"}})
      |> render_change()

      refute has_element?(view, "#shipping-provider-fallback-hint")
      assert has_element?(view, "#shipping-provider-pricing")

      view
      |> form(@form, %{"shipping_method" => %{"pay_on_delivery" => "false"}})
      |> render_change()

      assert has_element?(view, "#shipping-provider-fallback-hint")
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

      assert has_element?(view, "textarea#shipping-provider-setting-rates", "1 90")

      choose_provider(view, "stub")
      refute has_element?(view, "#shipping-provider-setting-rates")
      assert has_element?(view, "#shipping-provider-setting-sender_city")

      choose_provider(view, "table")
      refute has_element?(view, "textarea#shipping-provider-setting-rates", "1 90")
    end

    test "a post that carries the provider, service and settings together keeps all of them",
         %{conn: conn} do
      # What LiveView sends to recover a form after a reconnect: no `_target`,
      # everything at once. None of it is a provider change to reset.
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      render_change(view, "validate", %{
        "shipping_method" => %{
          "name" => "Recovered",
          "shipping_provider" => %{
            "provider" => "stub",
            "services" => ["courier"],
            "settings" => %{"sender_city" => %{"id" => "c-lviv", "name" => "Lviv"}},
            "pricing" => %{"markup_percent" => "15"}
          }
        }
      })

      render_async(view)

      assert has_element?(view, "#shipping-provider-select option[value='stub'][selected]")
      assert has_element?(view, "#shipping-service-courier[checked]")
      refute has_element?(view, "#shipping-service-branch[checked]")
      assert has_element?(view, "#shipping-locality-selected-sender_city", "Lviv")
      assert has_element?(view, "#shipping-pricing-markup_percent[value='15']")
    end

    test "a provider with an integration shows the connection and links to Integrations",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      choose_provider(view, "stub")

      assert has_element?(view, "#shipping-provider-integration")
      assert has_element?(view, "#shipping-provider-integration-status", "not connected")

      assert has_element?(
               view,
               ~s(#shipping-provider-integration-link[href$="/admin/settings/integrations"])
             )

      choose_provider(view, "table")
      refute has_element?(view, "#shipping-provider-integration")
    end

    test "the connection is shown as connected once the integration has credentials",
         %{conn: conn} do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("stub", "Stub account")
      {:ok, _} = Integrations.save_setup(uuid, %{"api_key" => "secret"})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      assert has_element?(
               view,
               "#shipping-provider-integration-status",
               "Stub carrier: connected"
             )

      refute has_element?(view, "#shipping-provider-integration-status", "not connected")
    end
  end

  describe "a slow or failing carrier" do
    test "does not hold the form up, and typing never calls it again", %{conn: conn} do
      method = stub_method!("Hung carrier", [])
      stub(%{modes: %{services: :hang}})

      {microseconds, {:ok, view, _html}} =
        :timer.tc(fn -> live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit") end)

      # The service list is loaded in the background: the page is there long
      # before the 2 s the carrier is given.
      assert microseconds < 1_500_000
      assert_receive {:stub_called, :services, _}
      assert has_element?(view, "#shipping-services-loading")
      assert has_element?(view, "#shipping-service-courier[checked]")
      refute has_element?(view, "#shipping-services", "unavailable")

      for name <- ["Hung carrier A", "Hung carrier AB"] do
        view
        |> form(@form, %{"shipping_method" => %{"name" => name}})
        |> render_change()
      end

      refute_receive {:stub_called, :services, _}, 150
    end

    test "services the carrier cannot list are reported, the saved service is kept",
         %{conn: conn} do
      method = stub_method!("Crashing carrier", [])
      stub(%{modes: %{services: :crash}})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")
      render_async(view)

      assert has_element?(view, "#shipping-services-error")
      assert has_element?(view, "#shipping-service-courier[checked]")
      refute has_element?(view, "#shipping-services", "unavailable")
    end

    test "a service the carrier answered without is called unavailable", %{conn: conn} do
      method = stub_method!("Dropped service", [])

      stub(%{
        services: [
          %PhoenixKitEcommerce.Shipping.Service{key: "branch", label: "To a branch"}
        ]
      })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")
      render_async(view)

      assert has_element?(view, "#shipping-service-courier[checked]")
      assert has_element?(view, "#shipping-services", "courier (unavailable)")
    end

    test "validating leaves the service check to the save", %{conn: conn} do
      stub(%{})
      attrs = stub_attrs()

      refute_received {:stub_called, :services, _}
      assert ShippingMethod.changeset(%ShippingMethod{}, attrs, check_service: false).valid?
      refute_received {:stub_called, :services, _}

      assert ShippingMethod.changeset(%ShippingMethod{}, attrs).valid?
      assert_received {:stub_called, :services, _}

      table = %{
        "name" => "T",
        "price" => "1",
        "shipping_provider" => %{
          "provider" => "table",
          "service" => "bogus",
          "settings" => %{"rates" => "1 90"}
        }
      }

      assert ShippingMethod.changeset(%ShippingMethod{}, table, check_service: false).valid?
      refute ShippingMethod.changeset(%ShippingMethod{}, table).valid?
      _ = conn
    end
  end

  describe "the services offered to the buyer" do
    test "an existing method shows its allowed services ticked and the rest unticked",
         %{conn: conn} do
      method = stub_method!("One service", [])

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")
      render_async(view)

      assert has_element?(view, "#shipping-service-courier[checked]")
      assert has_element?(view, "#shipping-service-branch")
      refute has_element?(view, "#shipping-service-branch[checked]")
    end

    test "saving stores the ticked services, the first one is the default", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")
      pick_sender_city(view)

      view
      |> form(@form, %{
        "shipping_method" => %{
          "name" => "Courier only",
          "price" => "70.00",
          "shipping_provider" => %{"services" => ["courier"]}
        }
      })
      |> render_submit()

      block = method_named("Courier only").metadata["shipping_provider"]

      assert block["services"] == ["courier"]
      assert block["service"] == "courier"
    end

    test "all of them unticked is refused with a message on the card", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")
      pick_sender_city(view)

      view
      |> form(@form, %{
        "shipping_method" => %{
          "name" => "Nothing offered",
          "price" => "70.00",
          "shipping_provider" => %{"services" => [""]}
        }
      })
      |> render_submit()

      assert has_element?(view, "#shipping-services-invalid", "at least one service")
      assert method_named("Nothing offered") == nil
    end
  end

  describe "locality autocomplete" do
    test "the lookups are made for the service the admin has chosen", %{conn: conn} do
      me = self()

      stub(%{
        localities: fn query, ctx ->
          send(me, {:searched_for, ctx.service})
          city_search(query)
        end
      })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")
      # The form picks the first service the provider offers.
      search_locality(view, "sender_city", "Spr")
      assert_received {:searched_for, "branch"}

      view
      |> form(@form, %{
        "shipping_method" => %{"shipping_provider" => %{"services" => ["courier"]}}
      })
      |> render_change()

      search_locality(view, "sender_city", "Spru")
      assert_received {:searched_for, "courier"}
    end

    test "search, pick and save stores the provider block", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      search_locality(view, "sender_city", "Spr")

      assert has_element?(view, "#shipping-locality-results-sender_city")
      assert has_element?(view, "#shipping-locality-option-sender_city-0", "Springfield")
      assert has_element?(view, "#shipping-locality-option-sender_city-1", "Sprucewood")

      view |> element("#shipping-locality-option-sender_city-0") |> render_click()

      assert has_element?(view, "#shipping-locality-selected-sender_city", "Springfield")

      assert has_element?(
               view,
               "#shipping-provider-setting-sender_city-id[value='c-springfield']"
             )

      assert has_element?(
               view,
               "#shipping-provider-setting-sender_city-name[value='Springfield']"
             )

      refute has_element?(view, "#shipping-locality-option-sender_city-0")
      # Picking touches nothing else: the untouched name is not "blank" yet.
      refute has_element?(view, @form, "be blank")
      refute has_element?(view, "#shipping-provider-errors")

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
               "services" => ["branch", "courier"],
               "settings" => %{
                 "sender_city" => %{"id" => "c-springfield", "name" => "Springfield"}
               },
               "pricing" => %{"markup_percent" => "10", "round_to" => "5"}
             }

      assert ShippingMethod.calculated?(method)
      assert Decimal.equal?(method.price, Decimal.new("70.00"))
    end

    test "a short query does not call the carrier, a real one does", %{conn: conn} do
      stub(%{localities: &city_search/1})
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      search_locality(view, "sender_city", "Spr")
      assert_received {:stub_called, :search_localities, ["Spr"]}
      assert has_element?(view, "#shipping-locality-option-sender_city-0")

      search_locality(view, "sender_city", "P")

      refute_received {:stub_called, :search_localities, _}
      refute has_element?(view, "#shipping-locality-option-sender_city-0")
    end

    test "a query nothing matches says so, a failing carrier says it is unavailable",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      search_locality(view, "sender_city", "Zzz")
      assert has_element?(view, "#shipping-locality-results-sender_city", "Nothing found")

      stub(%{localities: {:error, :boom}})
      search_locality(view, "sender_city", "Zzzz")
      assert has_element?(view, "#shipping-locality-results-sender_city", "unavailable")
    end

    test "typing past a slow search drops its late answer without an error", %{conn: conn} do
      stub(%{localities: blocking_search()})
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      view |> element("#shipping-locality-search-sender_city") |> render_change(query("Spr"))
      assert_receive {:lookup, slow, "Spr"}
      assert has_element?(view, "#shipping-locality-results-sender_city [role=status]")

      # The admin deletes the text before the carrier answers.
      view |> element("#shipping-locality-search-sender_city") |> render_change(query("P"))
      refute has_element?(view, "#shipping-locality-results-sender_city [role=status]")

      send(slow, :release)
      render_async(view)

      refute has_element?(view, "#shipping-locality-option-sender_city-0")
      refute has_element?(view, "#shipping-locality-results-sender_city", "unavailable")
    end

    test "choosing another provider mid-search drops the search for good", %{conn: conn} do
      stub(%{localities: blocking_search()})
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      view |> element("#shipping-locality-search-sender_city") |> render_change(query("Spr"))
      assert_receive {:lookup, slow, "Spr"}

      choose_provider(view, "table")
      refute has_element?(view, "#shipping-provider-setting-sender_city")

      send(slow, :release)
      render_async(view)

      # Back on the first provider nothing of the old search is left to pick.
      choose_provider(view, "stub")
      render_async(view)

      refute has_element?(view, "#shipping-locality-option-sender_city-0")
      refute has_element?(view, "#shipping-locality-results-sender_city [role=status]")
      refute has_element?(view, "#shipping-locality-results-sender_city", "unavailable")
    end

    test "only an offered result of the provider on screen can be picked", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")
      search_locality(view, "sender_city", "Spr")

      pick = fn attrs ->
        render_click(
          view,
          "pick_locality",
          Map.merge(%{"key" => "sender_city", "index" => "0", "provider" => "stub"}, attrs)
        )
      end

      for bad <- [
            %{"index" => "-1"},
            %{"index" => "99"},
            %{"index" => "abc"},
            %{"index" => "0.5"},
            # The id wins over the position: a list replaced since the click
            # must not select whatever now sits at index 0.
            %{"id" => "no-such-id"},
            %{"provider" => "table"},
            %{"key" => "nowhere"}
          ] do
        pick.(bad)
        refute has_element?(view, "#shipping-locality-selected-sender_city")
      end

      pick.(%{})
      assert has_element?(view, "#shipping-locality-selected-sender_city", "Springfield")
    end

    test "clearing the pick brings the search back and the required error", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")
      search_locality(view, "sender_city", "Spr")
      view |> element("#shipping-locality-option-sender_city-0") |> render_click()
      assert has_element?(view, "#shipping-locality-selected-sender_city")

      view |> element("#shipping-locality-clear-sender_city") |> render_click()

      refute has_element?(view, "#shipping-locality-selected-sender_city")
      refute has_element?(view, "#shipping-provider-setting-sender_city-id")

      assert has_element?(
               view,
               "#shipping-provider-error-setting-sender_city",
               "Sender city is required"
             )
    end

    test "a method with the required setting missing is not saved and says why",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")

      view
      |> form(@form, %{"shipping_method" => %{"name" => "Nowhere", "price" => "1"}})
      |> render_submit()

      assert has_element?(
               view,
               "#shipping-provider-error-setting-sender_city[role=alert]",
               "Sender city is required"
             )

      refute method_named("Nowhere")
    end

    test "a markup that is not a number is reported under its input", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "stub")
      search_locality(view, "sender_city", "Spr")
      view |> element("#shipping-locality-option-sender_city-0") |> render_click()

      view
      |> form(@form, %{
        "shipping_method" => %{
          "name" => "Bad markup",
          "price" => "1",
          "shipping_provider" => %{"pricing" => %{"markup_percent" => "abc"}}
        }
      })
      |> render_submit()

      assert has_element?(view, "#shipping-provider-pricing", "Must be a number")
      refute method_named("Bad markup")
    end
  end

  describe "who may ask the carrier" do
    setup %{conn: conn} do
      scope = fake_scope(permissions: ["shop", "shop.manage_catalog"], roles: ["Employee"])
      %{conn: put_test_scope(conn, scope), method: stub_method!("Read only", [])}
    end

    test "without manage_settings no lookup reaches the carrier", %{conn: conn, method: method} do
      # The page itself needs manage_settings now, so it is opened with it
      # and the grant is lost afterwards; what the opening asked the carrier
      # is not this test's question.
      {:ok, view, _html} = live_narrowed(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")
      render_async(view)
      flush_stub_calls()

      refute has_element?(view, "#shipping-services-loading")
      assert has_element?(view, "#shipping-service-courier[checked]")

      view |> element("#shipping-locality-search-sender_city") |> render_change(query("Spr"))
      render_async(view)
      render_click(view, "clear_locality", %{"key" => "sender_city"})

      refute_received {:stub_called, _, _}
      assert has_element?(view, "#shipping-locality-selected-sender_city", "Lviv")
    end

    defp flush_stub_calls do
      receive do
        {:stub_called, _, _} -> flush_stub_calls()
      after
        0 -> :ok
      end
    end

    test "and saving changes nothing", %{conn: conn, method: method} do
      {:ok, view, _html} = live_narrowed(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      view
      |> form(@form, %{"shipping_method" => %{"name" => "Renamed"}})
      |> render_submit()

      assert Shop.get_shipping_method!(method.uuid).name == method.name
    end
  end

  describe "editing" do
    test "shows the stored provider block and switching back to fixed removes it",
         %{conn: conn} do
      method = stub_method!("Stored stub", pay_on_delivery: true)

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      assert has_element?(view, "#shipping-provider-select option[value='stub'][selected]")
      assert has_element?(view, "#shipping-service-courier[checked]")
      assert has_element?(view, "#shipping-locality-selected-sender_city", "Lviv")
      assert has_element?(view, "#shipping-pricing-markup_percent[value='15']")

      choose_provider(view, "fixed")
      refute has_element?(view, "#shipping-services")
      refute has_element?(view, "#shipping-provider-pricing")

      view |> form(@form) |> render_submit()

      method = Shop.get_shipping_method!(method.uuid)
      refute Map.has_key?(method.metadata, "shipping_provider")
      refute ShippingMethod.calculated?(method)
      # Unrelated metadata survives.
      assert ShippingMethod.pay_on_delivery?(method)
    end

    test "a stored fixed block with an address destination is dropped on save",
         %{conn: conn} do
      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Legacy fixed #{System.unique_integer([:positive])}",
          "price" => "9",
          "metadata" => %{
            "shipping_provider" => %{
              "provider" => "fixed",
              "service" => "default",
              "settings" => %{"destination" => "address"}
            }
          }
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      refute has_element?(view, "#shipping-provider-setting-destination")
      refute has_element?(view, "#shipping-provider-settings")

      view
      |> form(@form, %{"shipping_method" => %{"name" => "Legacy renamed"}})
      |> render_submit()

      refute Map.has_key?(
               Shop.get_shipping_method!(method.uuid).metadata,
               "shipping_provider"
             )
    end

    test "saving without touching the card leaves a fixed method without a block",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      view
      |> form(@form, %{"shipping_method" => %{"name" => "Plain", "price" => "3.00"}})
      |> render_submit()

      refute Map.has_key?(method_named("Plain").metadata, "shipping_provider")
    end

    test "a provider the host no longer registers is said to be gone and cannot be saved",
         %{conn: conn} do
      {:ok, method} =
        Shop.create_shipping_method(%{
          "name" => "Gone #{System.unique_integer([:positive])}",
          "price" => "1",
          "metadata" => %{"shipping_provider" => %{"provider" => "gone", "service" => "x"}}
        })

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")
      render_async(view)

      assert has_element?(view, "#shipping-provider-select option[value='gone'][selected]")
      assert has_element?(view, "#shipping-provider-unknown[role=alert]", "no longer installed")
      refute has_element?(view, "#shipping-services-error")
      refute has_element?(view, "#shipping-services-loading")

      view |> form(@form, %{"shipping_method" => %{"name" => "Renamed"}}) |> render_submit()

      assert has_element?(view, "#shipping-provider-errors[role=alert]", "gone")
      assert Shop.get_shipping_method!(method.uuid).name == method.name

      choose_provider(view, "fixed")
      view |> form(@form, %{"shipping_method" => %{"name" => "Renamed"}}) |> render_submit()

      assert Shop.get_shipping_method!(method.uuid).name == "Renamed"
    end
  end

  describe "list" do
    test "shows the provider of each method as a badge", %{conn: conn} do
      fixed = fixed_method!("Flat rate")
      stub = stub_method!("Stub rate", [])
      {:ok, table} = create_method("Table rate", %{"shipping_provider" => table_param()})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping")

      assert has_element?(view, "#shipping-method-provider-#{fixed.uuid}", "Fixed price")
      assert has_element?(view, "#shipping-method-provider-#{stub.uuid}", "Stub carrier")
      assert has_element?(view, "#shipping-method-provider-#{table.uuid}", "Rate table by weight")
    end
  end

  describe "activity" do
    test "the provider is part of what is logged", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      choose_provider(view, "table")

      view
      |> form(@form, %{
        "shipping_method" => %{
          "name" => "Logged table",
          "price" => "2",
          "shipping_provider" => %{"settings" => %{"rates" => "1 90"}}
        }
      })
      |> render_submit()

      assert_activity_logged("shop.shipping_method_created",
        resource_uuid: method_named("Logged table").uuid,
        metadata_has: %{"provider" => "table"}
      )
    end
  end

  # -- helpers -----------------------------------------------------------

  # The stub's behaviour for this test; its calls are reported to the test.
  defp stub(config), do: StubProvider.put(Map.put_new(config, :notify, self()))

  defp city_search(query) do
    {:ok,
     [
       %Locality{id: "c-springfield", name: "Springfield", region: "Springfield oblast"},
       %Locality{id: "c-spruce", name: "Sprucewood", region: "Springfield oblast"}
     ]
     |> Enum.filter(&String.starts_with?(String.downcase(&1.name), String.downcase(query)))}
  end

  # A carrier that answers a search only when the test lets it.
  defp blocking_search do
    test = self()

    fn query ->
      send(test, {:lookup, self(), query})

      receive do
        :release -> city_search(query)
      after
        1_500 -> {:error, :never_released}
      end
    end
  end

  defp query(text), do: %{"locality_query" => %{"sender_city" => text}}

  defp choose_provider(view, provider) do
    view
    |> form(@form, %{"shipping_method" => %{"shipping_provider" => %{"provider" => provider}}})
    |> render_change(%{"_target" => @provider_target})

    render_async(view)
  end

  defp search_locality(view, key, query) do
    view
    |> element("#shipping-locality-search-#{key}")
    |> render_change(%{"locality_query" => %{key => query}})

    render_async(view)
  end

  defp pick_sender_city(view) do
    search_locality(view, "sender_city", "Spr")
    view |> element("#shipping-locality-option-sender_city-0") |> render_click()
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

  defp stub_attrs do
    %{
      "name" => "Stub",
      "price" => "1",
      "shipping_provider" => %{
        "provider" => "stub",
        "service" => "branch",
        "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Springfield"}}
      }
    }
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

    # Saving the method asked the stub for its services: not what a test
    # about the form is counting.
    flush_stub_calls()
    method
  end

  defp flush_stub_calls do
    receive do
      {:stub_called, _, _} -> flush_stub_calls()
    after
      0 -> :ok
    end
  end
end
