defmodule PhoenixKitEcommerce.Shipping.CountryUiTest do
  @moduledoc """
  The countries of a shipping method as the shop admin meets them: the lists
  in the method form (shown where they matter), the countries a shop delivers
  to, and the carriers' integrations that follow the shop's on/off switch.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Integrations.Providers
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Test.Repo, as: TestRepo
  alias PhoenixKitEcommerce.Test.Shipping.{CountryProvider, StubProvider}

  @form "#shipping-method-form"

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)

    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
      StubProvider,
      CountryProvider
    ])

    Providers.clear_cache()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)

      Application.delete_env(:phoenix_kit_ecommerce, :shipping_country_provider)
      # The setting lives in the Settings cache, which the sandbox does not roll back.
      Settings.update_setting("shop_enabled", "true")
      Providers.clear_cache()
    end)

    :ok
  end

  defp method!(attrs) do
    {:ok, method} =
      Shop.create_shipping_method(
        Map.merge(
          %{
            "name" => "Method #{System.unique_integer([:positive])}",
            "price" => Decimal.new("5.00")
          },
          attrs
        )
      )

    method
  end

  defp provider_method!(countries \\ []) do
    method!(%{
      "countries" => countries,
      "shipping_provider" => %{
        "provider" => "country_stub",
        "service" => "branch",
        "settings" => %{"sender_city" => %{"id" => "c1", "name" => "Springfield"}},
        "pricing" => %{"markup_percent" => "0", "markup_fixed" => "0", "round_to" => "1"}
      }
    })
  end

  describe "the country lists of a method" do
    test "are stored as upcased codes, once each, without blanks and junk" do
      changeset =
        ShippingMethod.changeset(%ShippingMethod{}, %{
          "name" => "Lists",
          "price" => "1",
          "countries" => ["", "ua", "UA", " pl ", "x1", "usa"],
          "excluded_countries" => ["", "ru"]
        })

      assert Ecto.Changeset.get_field(changeset, :countries) == ["UA", "PL"]
      assert Ecto.Changeset.get_field(changeset, :excluded_countries) == ["RU"]
    end

    test "keep only the countries the country data knows" do
      changeset =
        ShippingMethod.changeset(%ShippingMethod{}, %{
          "name" => "Known",
          "price" => "1",
          "countries" => ["XX", "uk", "EU", "gb", "UA"],
          "excluded_countries" => ["xk", "De"]
        })

      assert Ecto.Changeset.get_field(changeset, :countries) == ["GB", "UA"]
      assert Ecto.Changeset.get_field(changeset, :excluded_countries) == ["DE"]
      assert changeset.valid?
    end

    test "are an error when every code in them is wrong, never 'all countries'" do
      for codes <- [["USA"], ["XX"], ["UK", "EU"], ["", "usa", " "]] do
        changeset =
          ShippingMethod.changeset(%ShippingMethod{}, %{
            "name" => "Wrong",
            "price" => "1",
            "countries" => codes
          })

        refute changeset.valid?, "expected #{inspect(codes)} to be refused"
        assert %{countries: [_]} = errors_on(changeset)
      end

      changeset =
        ShippingMethod.changeset(%ShippingMethod{}, %{
          "name" => "Wrong",
          "price" => "1",
          "excluded_countries" => ["EU"]
        })

      assert %{excluded_countries: [_]} = errors_on(changeset)
    end

    test "a list set to nil is stored as the empty list, not as NULL" do
      method = method!(%{"countries" => ["UA"], "excluded_countries" => ["RU"]})

      assert {:ok, updated} =
               Shop.update_shipping_method(method, %{
                 "countries" => nil,
                 "excluded_countries" => nil
               })

      assert updated.countries == []
      assert updated.excluded_countries == []
      assert Shop.get_shipping_method!(method.uuid).countries == []
    end

    test "an update that does not mention the lists leaves them as they are" do
      method = method!(%{"countries" => ["UA"], "excluded_countries" => ["RU"]})

      assert {:ok, _} = Shop.update_shipping_method(method, %{"name" => "Renamed"})

      reloaded = Shop.get_shipping_method!(method.uuid)
      assert reloaded.countries == ["UA"]
      assert reloaded.excluded_countries == ["RU"]
    end

    test "are an error when an update would turn the list into 'all countries'" do
      method = method!(%{"countries" => ["UA"]})

      assert {:error, changeset} = Shop.update_shipping_method(method, %{"countries" => ["USA"]})
      assert %{countries: [_]} = errors_on(changeset)
      assert Shop.get_shipping_method!(method.uuid).countries == ["UA"]
    end

    test "can be emptied: the blank entry of the form clears a list" do
      method = method!(%{"countries" => ["UA", "PL"], "excluded_countries" => ["RU"]})

      {:ok, updated} =
        Shop.update_shipping_method(method, %{"countries" => [""], "excluded_countries" => [""]})

      assert updated.countries == []
      assert updated.excluded_countries == []
    end

    test "a country in both lists is not delivered to" do
      method = method!(%{"countries" => ["UA", "PL"], "excluded_countries" => ["PL"]})

      assert ShippingMethod.available_for?(method, %{country: "UA"})
      refute ShippingMethod.available_for?(method, %{country: "PL"})
    end
  end

  describe "checkout_countries/0" do
    test "is :all without active methods and while any method is open" do
      assert Shop.checkout_countries() == :all

      method!(%{"countries" => ["UA"]})
      assert Shop.checkout_countries() == ["UA"]

      method!(%{"countries" => []})
      assert Shop.checkout_countries() == :all
    end

    test "puts the countries of the active methods together, less the excluded" do
      method!(%{"countries" => ["UA", "PL", "DE"], "excluded_countries" => ["DE"]})
      method!(%{"countries" => ["PL", "LT"]})
      method!(%{"countries" => ["FR"], "active" => false})

      assert Shop.checkout_countries() == ["LT", "PL", "UA"]
    end

    test "narrows a method by the countries its provider serves" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA"])

      provider_method!()
      assert Shop.checkout_countries() == ["UA"]

      # The method lists more than the carrier delivers to: only what both allow.
      provider_method!(["UA", "PL"])
      assert Shop.checkout_countries() == ["UA"]
    end

    test "a provider that says nothing does not narrow the method" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, [])

      provider_method!(["UA", "PL"])
      assert Shop.checkout_countries() == ["PL", "UA"]

      provider_method!()
      assert Shop.checkout_countries() == :all
    end

    test "the default checkout country follows a single served country" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA"])
      provider_method!()

      assert Shop.default_checkout_country() == "UA"
    end
  end

  describe "the method form" do
    setup %{conn: conn}, do: %{conn: put_test_scope(conn, fake_scope())}

    defp choose_provider(view, provider) do
      view
      |> element(@form)
      |> render_change(%{
        "_target" => ["shipping_method", "shipping_provider", "provider"],
        "shipping_method" => %{"shipping_provider" => %{"provider" => provider}}
      })
    end

    test "keeps the lists one click away while the price is fixed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      assert has_element?(view, "#shipping-method-countries-toggle")
      refute has_element?(view, "#shipping-method-countries")

      view |> element("#shipping-method-countries-toggle") |> render_click()

      refute has_element?(view, "#shipping-method-countries-toggle")
      assert has_element?(view, "#shipping_method_countries input[type=checkbox]")
      assert has_element?(view, "#shipping_method_excluded_countries input[type=checkbox]")

      # The admin theme draws a native multiple select as one strip of overlapping
      # labels: the lists are checkboxes in a box that scrolls.
      refute has_element?(view, "#shipping-method-countries select")
      assert has_element?(view, "#shipping_method_countries input[type=checkbox][value='DE']")
      refute has_element?(view, "#shipping_method_countries input[type=checkbox][checked]")
    end

    test "leaves them out for a provider that delivers to one country", %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA"])
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      choose_provider(view, "country_stub")

      refute has_element?(view, "#shipping-method-countries-toggle")
      refute has_element?(view, "#shipping-method-countries")
    end

    test "opens them, limited to its countries, for a provider that serves several",
         %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA", "PL"])
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")

      choose_provider(view, "country_stub")

      assert has_element?(view, "#shipping-method-countries")
      assert has_element?(view, "#shipping_method_countries input[type=checkbox][value='UA']")
      assert has_element?(view, "#shipping_method_countries input[type=checkbox][value='PL']")
      refute has_element?(view, "#shipping_method_countries input[type=checkbox][value='DE']")

      refute has_element?(
               view,
               "#shipping_method_excluded_countries input[type=checkbox][value='DE']"
             )
    end

    test "shows what is saved, even for a provider that has one country", %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA"])
      method = provider_method!(["PL"])

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      # PL is not the provider's, but it is stored: it stays visible to be removed.
      assert has_element?(view, "#shipping-method-countries")

      assert has_element?(
               view,
               "#shipping_method_countries input[type=checkbox][value='PL'][checked]"
             )

      assert has_element?(view, "#shipping_method_countries input[type=checkbox][value='UA']")
      refute has_element?(view, "#shipping_method_countries input[type=checkbox][value='DE']")
    end

    test "says which countries are ticked, whatever the scroll of the list", %{conn: conn} do
      method = method!(%{"countries" => ["UA", "PL"], "excluded_countries" => ["RU"]})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      assert has_element?(view, "#shipping_method_countries-selected", "UA, PL")
      assert has_element?(view, "#shipping_method_excluded_countries-selected", "RU")

      view
      |> form(@form, shipping_method: %{countries: [""], excluded_countries: [""]})
      |> render_change()

      refute has_element?(view, "#shipping_method_countries-selected")
      refute has_element?(view, "#shipping_method_excluded_countries-selected")
    end

    test "opens at once when the method already has countries", %{conn: conn} do
      method = method!(%{"countries" => ["UA"], "excluded_countries" => ["RU"]})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      refute has_element?(view, "#shipping-method-countries-toggle")

      assert has_element?(
               view,
               "#shipping_method_countries input[type=checkbox][value='UA'][checked]"
             )

      assert has_element?(
               view,
               "#shipping_method_excluded_countries input[type=checkbox][value='RU'][checked]"
             )
    end

    test "saves the countries chosen", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/new")
      view |> element("#shipping-method-countries-toggle") |> render_click()

      view
      |> form(@form,
        shipping_method: %{
          name: "To Ukraine and Poland",
          price: "3.50",
          countries: ["UA", "PL"],
          excluded_countries: ["RU"]
        }
      )
      |> render_submit()

      method = Shop.list_shipping_methods() |> Enum.find(&(&1.name == "To Ukraine and Poland"))

      assert Enum.sort(method.countries) == ["PL", "UA"]
      assert method.excluded_countries == ["RU"]
    end

    test "can clear them, and stays open while they are emptied", %{conn: conn} do
      method = method!(%{"countries" => ["UA"], "excluded_countries" => ["RU"]})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      # What a browser posts when nothing is selected: only the blank entry.
      view
      |> form(@form, shipping_method: %{countries: [""], excluded_countries: [""]})
      |> render_change()

      assert has_element?(view, "#shipping-method-countries")

      view
      |> form(@form, shipping_method: %{countries: [""], excluded_countries: [""]})
      |> render_submit()

      reloaded = Shop.get_shipping_method!(method.uuid)
      assert reloaded.countries == []
      assert reloaded.excluded_countries == []
    end

    test "unticking the last country of a single-country provider's method clears it",
         %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA"])
      method = provider_method!(["PL"])

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      view
      |> form(@form, shipping_method: %{countries: [""], excluded_countries: [""]})
      |> render_change()

      # The lists stay, so that the browser still posts the emptied ones.
      assert has_element?(view, "#shipping-method-countries")

      view
      |> form(@form, shipping_method: %{countries: [""], excluded_countries: [""]})
      |> render_submit()

      assert Shop.get_shipping_method!(method.uuid).countries == []
    end

    test "a stored code the country data does not know stays on screen and is never widened",
         %{conn: conn} do
      method = method!(%{"countries" => ["UA"]})

      # Rows written outside the form (an import, a script) can hold a code that
      # has no checkbox, such as `UK`.
      method
      |> Ecto.Changeset.change(countries: ["UK"])
      |> TestRepo.update!()

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      assert has_element?(view, "#shipping_method_countries input[value='UK'][checked]")

      # Saving something else must not turn the list into "every country".
      view
      |> form(@form, shipping_method: %{name: "Renamed"})
      |> render_submit()

      reloaded = Shop.get_shipping_method!(method.uuid)
      assert reloaded.name == "Renamed"
      assert reloaded.countries == ["UK"]

      # Unticking it is a decision of the admin, and it is allowed.
      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      view
      |> form(@form, shipping_method: %{countries: [""]})
      |> render_submit()

      assert Shop.get_shipping_method!(method.uuid).countries == []
    end

    test "a list made only of wrong codes shows its error under the list", %{conn: conn} do
      method = method!(%{"countries" => ["UA"]})

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      # Not what the browser posts, but what a crafted or stale post looks like.
      view
      |> element(@form)
      |> render_submit(%{"shipping_method" => %{"countries" => ["", "XX"]}})

      assert has_element?(view, "#shipping_method_countries-error", "has no valid country code")
      assert Shop.get_shipping_method!(method.uuid).countries == ["UA"]
    end

    test "a stored value that is not a two-letter code is shown ticked and kept", %{conn: conn} do
      method = method!(%{"countries" => ["UA"]})

      method
      |> Ecto.Changeset.change(countries: ["USA", "Ukraine"])
      |> TestRepo.update!()

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      assert has_element?(view, "#shipping_method_countries input[value='USA'][checked]")
      assert has_element?(view, "#shipping_method_countries input[value='Ukraine'][checked]")

      view |> form(@form, shipping_method: %{name: "Renamed"}) |> render_submit()

      assert Shop.get_shipping_method!(method.uuid).countries == ["USA", "Ukraine"]
    end

    test "a stored code outside a limited provider's countries gets one row, ticked, by name",
         %{conn: conn} do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA", "PL"])
      method = provider_method!(["PL"])

      method
      |> Ecto.Changeset.change(countries: ["de"])
      |> TestRepo.update!()

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      # `element/2` + `render/1` raises when more than one row matches.
      assert view |> element("#shipping_method_countries input[value='DE']") |> render() =~
               "checked"

      refute has_element?(view, "#shipping_method_countries input[value='de']")
      assert has_element?(view, "#shipping_method_countries label", "Germany")
      assert has_element?(view, "#shipping_method_countries input[value='UA']")
      refute has_element?(view, "#shipping_method_countries input[value='FR']")
    end

    test "the button that opens the lists never closes them", %{conn: conn} do
      method = method!(%{"name" => "Open once"})
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, [])

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")
      refute has_element?(view, "#shipping-method-countries")

      view |> element("button[phx-click=open_countries]") |> render_click()
      assert has_element?(view, "#shipping-method-countries")

      # A second click can arrive before the first diff removes the button.
      render_hook(view, "open_countries", %{})
      assert has_element?(view, "#shipping-method-countries")
    end

    test "a stored lower case code is shown ticked and saved upcased", %{conn: conn} do
      method = method!(%{"countries" => ["UA"]})

      method
      |> Ecto.Changeset.change(countries: ["ua"])
      |> TestRepo.update!()

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      assert has_element?(view, "#shipping_method_countries input[value='UA'][checked]")
      refute has_element?(view, "#shipping_method_countries input[value='ua']")

      view |> form(@form, shipping_method: %{name: "Renamed"}) |> render_submit()

      assert Shop.get_shipping_method!(method.uuid).countries == ["UA"]
    end

    test "a method with stored countries saved from the form keeps them", %{conn: conn} do
      method = method!(%{"countries" => ["UA"]})
      Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, [])

      {:ok, view, _html} = live(conn, "/en/admin/shop/shipping/#{method.uuid}/edit")

      view |> form(@form, shipping_method: %{name: "Renamed"}) |> render_submit()

      reloaded = Shop.get_shipping_method!(method.uuid)
      assert reloaded.name == "Renamed"
      assert reloaded.countries == ["UA"]
    end

    test "the list of methods shows the codes", %{conn: conn} do
      method!(%{"name" => "Listed", "countries" => ["UA", "PL", "DE", "LT", "LV"]})
      method!(%{"name" => "Barred", "excluded_countries" => ["RU"]})

      {:ok, _view, html} = live(conn, "/en/admin/shop/shipping")

      assert html =~ "UA, PL, DE +2"
      assert html =~ "RU"
    end
  end

  describe "the carriers' integrations follow the shop's switch" do
    test "are offered while the shop is on" do
      Settings.update_setting("shop_enabled", "true")
      Providers.clear_cache()

      assert "stub" in Enum.map(Shop.integration_providers(), & &1.key)
      assert Enum.any?(Providers.all(), &(&1.key == "stub"))
    end

    test "are hidden once the shop is switched off, and back when it is on again" do
      {:ok, _} = Shop.enable_system()
      assert Enum.any?(Providers.all(), &(&1.key == "stub"))

      {:ok, _} = Shop.disable_system()
      assert Shop.integration_providers() == []
      refute Enum.any?(Providers.all(), &(&1.key == "stub"))

      {:ok, _} = Shop.enable_system()
      assert Enum.any?(Providers.all(), &(&1.key == "stub"))
    end

    test "an unreadable setting does not hide them" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])
      Settings.update_setting("shop_enabled", "")

      assert "stub" in Enum.map(Shop.integration_providers(), & &1.key)
    end
  end
end
