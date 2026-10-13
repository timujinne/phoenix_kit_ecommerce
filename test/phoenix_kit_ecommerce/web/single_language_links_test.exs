defmodule PhoenixKitEcommerce.Web.SingleLanguageLinksTest do
  @moduledoc """
  One language per rendered page, and no locale segment at all on a
  single-language site.

  The storefront used to build its links from two sources: the page language
  (catalog, cart, checkout) and the language of a product's slug (product
  links and redirects). On a site with one language the two disagreed —
  `Back` went to `/en/shop` while the product redirected to `/uk/shop/...`.
  Now every link on a page uses the page's language, and with multi-language
  support off none carries a locale segment.

  Every link the storefront builds goes through `Shop.url_locale/1`, which
  passes `:none` itself while multi-language support is off — so the
  locale-free assertions hold on a core that predates the single-language
  policy too. Only the tests tagged `:requires_core_single_language` need the
  newer core (the primary language of a switched-off site being its stored
  default language).
  """
  use PhoenixKitEcommerce.LiveCase, async: false

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Web.Helpers
  alias PhoenixKitEcommerce.Web.SEOHelpers

  # A locale segment at the start of a path, or of a `return_to` value.
  @segment ~r{(^|return_to=)/(en|uk|de)(/|\?|$)}

  defp configure_languages(enabled?, codes, opts \\ []) do
    Settings.update_setting("languages_enabled", to_string(enabled?))

    languages =
      Enum.map(codes, fn code ->
        %{
          "code" => code,
          "name" => code,
          "is_enabled" => true,
          "is_default" => code == hd(codes)
        }
      end)

    Settings.update_json_setting("languages_config", %{"languages" => languages})
    Languages.set_default_language_no_prefix(Keyword.get(opts, :no_prefix, false))
  end

  defp reset_languages do
    Settings.update_setting("languages_enabled", "false")
    Settings.update_json_setting("languages_config", %{"languages" => []})
    Languages.set_default_language_no_prefix(false)
  end

  # The changeset fills a missing language's slug from the title, so an entity
  # whose slugs exist only in some languages has to have its map written
  # directly.
  defp create_product(slug_map, extra \\ %{}) do
    {:ok, product} =
      Shop.create_product(
        Map.merge(
          %{
            "title" => %{"en" => "Link Probe", "uk" => "Link Probe"},
            "slug" => slug_map,
            "price" => Decimal.new("10.00"),
            "status" => "active",
            "currency" => "USD",
            "product_type" => "digital",
            "requires_shipping" => false
          },
          extra
        )
      )

    product
    |> Ecto.Changeset.change(slug: slug_map)
    |> Repo.update!()
  end

  defp create_category(slug_map) do
    {:ok, category} =
      Shop.create_category(%{
        "name" => %{"en" => "Probe Category", "uk" => "Probe Category"},
        "slug" => slug_map,
        "status" => "active"
      })

    category
    |> Ecto.Changeset.change(slug: slug_map)
    |> Repo.update!()
  end

  defp slug(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"

  defp cart_conn(conn, product, extra_session \\ %{}) do
    session_id = "links-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    Plug.Test.init_test_session(
      conn,
      Map.merge(%{"shop_session_id" => session_id, "shop_session_trusted" => true}, extra_session)
    )
  end

  defp order_for(product) do
    session_id = "links-order-#{System.unique_integer([:positive])}"
    {:ok, cart} = Shop.create_cart(session_id: session_id)
    {:ok, cart} = Shop.add_to_cart(cart, product, 1)

    {:ok, order} =
      Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "links-order"))

    {order, session_id}
  end

  defp hrefs(html) do
    ~r/href="([^"]+)"/
    |> Regex.scan(html, capture: :all_but_first)
    |> List.flatten()
    |> Enum.map(fn href -> href |> String.replace("&amp;", "&") |> URI.decode() end)
    |> Enum.filter(&String.starts_with?(&1, "/"))
  end

  # Core's own chrome around the page (the admin link, the profile menu): on a
  # core that predates the single-language policy it carries the locale, and it
  # is not what is under test. Every other link on the page is.
  @core_chrome ~r{^(/(en|uk|de))?/(admin|profile|users/log-out|users/settings)(/|\?|$)}

  # Every link on the page, none of which may carry a locale segment.
  defp assert_locale_free(html, page) do
    links = hrefs(html)
    assert links != [], "#{page}: no links rendered"

    for link <- links, link =~ @segment, not (link =~ @core_chrome) do
      flunk("#{page}: locale segment in #{link}")
    end

    links
  end

  # No link may switch to a language other than `language`.
  defp assert_only_language(html, language, page) do
    links = hrefs(html)
    assert links != [], "#{page}: no links rendered"

    for link <- links, other <- ["en", "uk", "de"] -- [language] do
      refute link =~ ~r{(^|return_to=)/#{other}(/|\?|$)}, "#{page}: #{other} link #{link}"
    end

    links
  end

  # A catalog with one category holding one product, as the storefront pages
  # render it: sidebar and card links to both.
  defp catalog_fixture do
    category = create_category(%{"uk" => slug("cat"), "en" => slug("cat-en")})

    product =
      create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")}, %{
        "category_uuid" => category.uuid
      })

    {category, product}
  end

  # A signed-in shopper with two saved billing profiles and none of them the
  # default: the billing step shows the profile selector (a function
  # component) and, once one is picked, its edit link.
  defp profile_selector_html(conn, product, path, session \\ %{}) do
    user = PhoenixKitEcommerce.DataCase.fixture_user()
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    profiles =
      for n <- 1..2 do
        {:ok, profile} =
          PhoenixKitBilling.create_billing_profile(user, %{
            "first_name" => "Saved#{n}",
            "last_name" => "Person",
            "email" => "saved#{n}-#{System.unique_integer([:positive])}@example.com",
            "address_line1" => "9 Saved Road",
            "city" => "Tartu",
            "postal_code" => "50090",
            "country" => "EE"
          })

        profile
      end

    Repo.update_all(PhoenixKitBilling.BillingProfile, set: [is_default: false])

    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = Plug.Test.init_test_session(conn, Map.put(session, "phoenix_kit_test_scope", scope))

    {:ok, view, html} = live(conn, path)
    selected = render_click(view, "select_profile", %{"profile_uuid" => hd(profiles).uuid})
    html <> selected
  end

  # A confirmed signed-in shopper with a default billing profile (so the page
  # opens on the review step), checking out `product` on `path`; returns the
  # redirect target and the buyer's notification links after the order.
  defp checkout_as_user(conn, product, path, session \\ %{}) do
    user = PhoenixKitEcommerce.DataCase.fixture_user()
    confirm_user!(user)
    {:ok, cart} = Shop.create_cart(user_uuid: user.uuid)
    {:ok, _cart} = Shop.add_to_cart(cart, product, 1)

    {:ok, _profile} =
      PhoenixKitBilling.create_billing_profile(user, %{
        "first_name" => "Saved",
        "last_name" => "Person",
        "email" => user.email,
        "address_line1" => "9 Saved Road",
        "city" => "Tartu",
        "postal_code" => "50090",
        "country" => "EE"
      })

    scope = fake_scope(user_uuid: user.uuid, email: user.email)
    conn = Plug.Test.init_test_session(conn, Map.put(session, "phoenix_kit_test_scope", scope))

    {:ok, view, _html} = live(conn, path)
    view |> element("button[phx-click='confirm_order']") |> render_click()

    {to, _flash} = assert_redirect(view)
    [_, uuid] = Regex.run(~r{/checkout/complete/([0-9a-f-]+)$}, to)
    {uuid, notification_links_mentioning("is confirmed")}
  end

  defp customer(order), do: Auth.get_user(order.user_uuid)

  defp link_to?(links, prefix), do: Enum.any?(links, &String.starts_with?(&1, prefix))

  # Walks a digital-cart guest checkout to the review step (a digital cart
  # needs no shipping) and returns the view with the review step's markup.
  defp review_step(conn, product, path, billing_email \\ nil, session \\ %{}) do
    {:ok, view, _html} = live(cart_conn(conn, product, session), path)

    form =
      if billing_email do
        billing = Map.put(complete_billing("EE", "links-review"), "email", billing_email)
        form(view, "#checkout-billing-form", billing: billing)
      else
        fill_billing_form(view, country: "EE")
      end

    render_change(form)
    html = view |> element("button[phx-click='proceed_to_review']") |> render_click()
    {view, html}
  end

  # An account that exists and is confirmed: a guest checking out with its
  # email is told to log in.
  defp confirmed_account_email do
    email = "links-account-#{System.unique_integer([:positive])}@example.com"
    {:ok, user} = Auth.create_guest_user(%{email: email, first_name: "A"})
    confirm_user!(user)
    email
  end

  defp confirm_user!(user) do
    user
    |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update!()
  end

  describe "single-language site (switch off, primary uk)" do
    setup do
      configure_languages(false, ["uk"])
      on_exit(&reset_languages/0)
      :ok
    end

    test "storefront URL builders carry no locale segment, whatever language is asked for" do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      category = create_category(%{"uk" => slug("cat"), "en" => slug("cat-en")})

      for language <- ["uk", "en", "en-US"] do
        assert Shop.catalog_url(language) == "/shop"
        assert Shop.cart_url(language) == "/cart"
        assert Shop.checkout_url(language) == "/checkout"
        assert Shop.product_url(product, language) =~ ~r{^/shop/product/probe}
        assert Shop.category_url(category, language) =~ ~r{^/shop/category/cat}
      end
    end

    test "url_locale/1 is :none whatever the language, so no core has to drop the segment" do
      assert Shop.url_locale("uk") == :none
      assert Shop.url_locale("en-US") == :none
    end

    @tag :requires_core_single_language
    test "the primary language is the stored one, not a hardcoded en" do
      assert Shop.get_default_language() == "uk"
    end

    test "a product whose slug is in another language renders instead of redirecting", %{
      conn: conn
    } do
      en_slug = slug("probe")
      create_product(%{"en" => en_slug})

      assert {:ok, _view, html} = live(conn, "/shop/product/#{en_slug}")
      assert html =~ "Link Probe"
    end

    # Whatever the page language is on this core, one of the two slugs is not
    # its own: the page used to hop to the other language's slug (a locale
    # segment appearing out of nowhere); a single-language site has nowhere to
    # hop to, so it renders both.
    test "a product reached by either language's slug is never redirected", %{conn: conn} do
      uk_slug = slug("probe-uk")
      en_slug = slug("probe-en")
      create_product(%{"uk" => uk_slug, "en" => en_slug})

      for s <- [uk_slug, en_slug] do
        assert {:ok, _view, html} = live(conn, "/shop/product/#{s}")
        assert html =~ "Link Probe"
        assert_locale_free(html, "product page")
      end
    end

    test "every link on the product page is locale-free", %{conn: conn} do
      s = slug("probe")
      create_product(%{"uk" => s, "en" => slug("probe-en")})

      {:ok, _view, html} = live(conn, "/shop/product/#{s}")

      assert "/shop" in assert_locale_free(html, "product page")
    end

    test "a category reached by either language's slug is never redirected", %{conn: conn} do
      uk_slug = slug("cat-uk")
      en_slug = slug("cat-en")
      create_category(%{"uk" => uk_slug, "en" => en_slug})

      for s <- [uk_slug, en_slug] do
        assert {:ok, _view, html} = live(conn, "/shop/category/#{s}")
        assert html =~ "Probe Category"
        assert_locale_free(html, "category page")
      end
    end

    test "a category with a slug in one language only renders, links locale-free", %{conn: conn} do
      s = slug("cat-en")
      create_category(%{"en" => s})

      assert {:ok, _view, html} = live(conn, "/shop/category/#{s}")
      assert html =~ "Probe Category"
      assert "/shop" in assert_locale_free(html, "category page")
    end

    test "the cart page links to its items, the catalog and checkout without a segment", %{
      conn: conn
    } do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      {:ok, _view, html} = live(cart_conn(conn, product), "/cart")

      links = assert_locale_free(html, "cart page")
      assert Enum.any?(links, &String.starts_with?(&1, "/shop/product/probe"))
    end

    test "the checkout page: the way back to the cart and the log-in link are locale-free", %{
      conn: conn
    } do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      {:ok, _view, html} = live(cart_conn(conn, product), "/checkout")

      links = assert_locale_free(html, "checkout page")
      assert "/cart" in links
    end

    test "checkout with an empty cart goes back to the locale-free cart", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/cart"}}} = live(conn, "/checkout")
    end

    test "the catalog links its categories and products without a segment", %{conn: conn} do
      {_category, _product} = catalog_fixture()

      {:ok, _view, html} = live(conn, "/shop")

      links = assert_locale_free(html, "catalog page")
      assert link_to?(links, "/shop/category/cat")
      assert link_to?(links, "/shop/product/probe")
    end

    test "a category page links its product cards and the cart without a segment", %{conn: conn} do
      {category, _product} = catalog_fixture()

      {:ok, _view, html} = live(conn, Shop.category_url(category, "uk"))

      links = assert_locale_free(html, "category page")
      assert link_to?(links, "/shop/product/probe")
      assert "/cart" in links
    end

    test "the review step's links are locale-free", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      {_view, html} = review_step(conn, product, "/checkout")

      links = assert_locale_free(html, "review step")
      assert "/cart" in links
    end

    test "the profile selector's links are locale-free", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      html = profile_selector_html(conn, product, "/checkout")

      links = assert_locale_free(html, "profile selector")
      assert link_to?(links, "/dashboard/billing-profiles")
      assert Enum.any?(links, &String.ends_with?(&1, "/edit?return_to=/checkout"))
    end

    test "a checkout whose order is already placed redirects to the locale-free confirmation",
         %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      conn = cart_conn(conn, product)
      cart = Shop.find_active_cart(session_id: Plug.Conn.get_session(conn, "shop_session_id"))

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "links"))

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/checkout")
      assert to == "/checkout/complete/#{order.uuid}"
    end

    test "an order placed from a stale checkout page lands on the locale-free confirmation", %{
      conn: conn
    } do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      {view, _html} = review_step(conn, product, "/checkout")

      stale_cart = :sys.get_state(view.pid).socket.assigns.cart

      {:ok, order} =
        Shop.convert_cart_to_order(stale_cart, billing_data: complete_billing("EE", "links"))

      view |> element("button[phx-click='confirm_order']") |> render_click()

      {to, _flash} = assert_redirect(view)
      assert to == "/checkout/complete/#{order.uuid}"
    end

    test "the log-in link of an existing account returns to the locale-free checkout", %{
      conn: conn
    } do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      {view, _html} = review_step(conn, product, "/checkout", confirmed_account_email())

      html = view |> element("button[phx-click='confirm_order']") |> render_click()

      links = assert_locale_free(html, "account-exists notice")
      assert "/users/log-in?return_to=/checkout" in links
    end

    test "placing the order lands on the locale-free confirmation page", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      {view, _html} = review_step(conn, product, "/checkout")

      view |> element("button[phx-click='confirm_order']") |> render_click()

      {to, _flash} = assert_redirect(view)
      assert to =~ ~r{^/checkout/complete/[0-9a-f-]+$}
    end

    test "the order notification links to the locale-free order page" do
      product = create_product(%{"uk" => slug("probe")})
      {order, _session_id} = order_for(product)
      order |> customer() |> confirm_user!()

      PhoenixKitEcommerce.Notifications.order_placed(order)

      assert ["/dashboard/orders/" <> _] = notification_links_mentioning(order.order_number)
    end

    test "the order confirmation page's links are locale-free", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      {order, session_id} = order_for(product)

      conn =
        Plug.Test.init_test_session(conn, %{
          "shop_session_id" => session_id,
          "shop_session_trusted" => true
        })

      {:ok, _view, html} = live(conn, "/checkout/complete/#{order.uuid}")

      assert "/shop" in assert_locale_free(html, "order confirmation")
    end

    test "the account's order pages' links are locale-free", %{conn: conn} do
      Settings.update_boolean_setting_with_module("billing_enabled", true, "billing")
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      {order, _session_id} = order_for(product)
      conn = put_test_scope(conn, fake_scope(user_uuid: order.user_uuid))

      {:ok, _view, details} = live(conn, "/dashboard/orders/#{order.uuid}")
      assert "/dashboard/orders" in assert_locale_free(details, "order details")

      {:ok, view, _html} = live(conn, "/dashboard/orders")
      assert "/shop" in assert_locale_free(render(view), "order list")
    end
  end

  describe "one enabled language, primary served without a prefix" do
    setup do
      configure_languages(true, ["uk"], no_prefix: true)
      on_exit(&reset_languages/0)
      :ok
    end

    test "the builders emit no segment for the primary language" do
      assert Shop.catalog_url("uk") == "/shop"
      assert Shop.cart_url("uk") == "/cart"
      assert Shop.url_locale("uk-UA") == "uk"
    end

    test "the pages' links carry no segment", %{conn: conn} do
      s = slug("probe")
      product = create_product(%{"uk" => s})

      {:ok, _view, html} = live(conn, "/shop/product/#{s}")
      assert "/shop" in assert_locale_free(html, "product page")

      {:ok, _view, html} = live(cart_conn(conn, product), "/cart")
      assert_locale_free(html, "cart page")

      {:ok, _view, html} = live(cart_conn(conn, product), "/checkout")
      assert "/cart" in assert_locale_free(html, "checkout page")
    end

    test "the catalog and a category page link without a segment", %{conn: conn} do
      {category, product} = catalog_fixture()

      {:ok, _view, html} = live(conn, "/shop")
      links = assert_locale_free(html, "catalog page")
      assert Shop.category_url(category, "uk") in links
      assert Shop.product_url(product, "uk") in links

      {:ok, _view, html} = live(conn, Shop.category_url(category, "uk"))
      links = assert_locale_free(html, "category page")
      assert Shop.product_url(product, "uk") in links
      assert "/cart" in links
    end

    test "the review step and the order redirect carry no segment", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe")})
      {view, html} = review_step(conn, product, "/checkout")
      assert "/cart" in assert_locale_free(html, "review step")

      view |> element("button[phx-click='confirm_order']") |> render_click()
      {to, _flash} = assert_redirect(view)
      assert to =~ ~r{^/checkout/complete/[0-9a-f-]+$}
    end

    test "checkout with an empty cart goes back to the unprefixed cart", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/cart"}}} = live(conn, "/checkout")
    end
  end

  describe "multilingual site (uk primary, en enabled)" do
    setup do
      configure_languages(true, ["uk", "en"])
      on_exit(&reset_languages/0)
      :ok
    end

    test "url_locale/1 is the base code of the language asked for" do
      assert Shop.url_locale("en-US") == "en"
      assert Shop.url_locale("uk") == "uk"
    end

    test "checkout with an empty cart goes back to the cart in the primary language", %{
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/checkout")
      assert to == Shop.cart_url("uk")
    end

    test "the checkout page keeps the page's language on every link", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      conn = cart_conn(conn, product, %{"phoenix_kit_test_locale" => "en"})
      {:ok, _view, html} = live(conn, "/en/checkout")

      links = assert_only_language(html, "en", "checkout page")
      assert Shop.cart_url("en") in links
    end

    test "the catalog and a category page keep the page's language on every link", %{conn: conn} do
      {category, product} = catalog_fixture()

      {:ok, _view, html} = live(conn, "/en/shop")
      links = assert_only_language(html, "en", "catalog page")
      assert Shop.category_url(category, "en") in links
      assert Shop.product_url(product, "en") in links

      {:ok, _view, html} = live(conn, Shop.category_url(category, "en"))
      links = assert_only_language(html, "en", "category page")
      assert Shop.product_url(product, "en") in links
      assert Shop.cart_url("en") in links
    end

    test "the review step keeps the page's language on every link", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      {_view, html} =
        review_step(conn, product, "/en/checkout", nil, %{"phoenix_kit_test_locale" => "en"})

      links = assert_only_language(html, "en", "review step")
      cart_links = Enum.filter(links, &String.ends_with?(&1, "/cart"))
      assert cart_links != []
      assert Enum.all?(cart_links, &(&1 == Shop.cart_url("en")))
    end

    test "the profile selector keeps the page's language on its links", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      html =
        profile_selector_html(conn, product, "/en/checkout", %{"phoenix_kit_test_locale" => "en"})

      links = assert_only_language(html, "en", "profile selector")
      assert link_to?(links, Routes.path("/dashboard/billing-profiles", locale: "en"))
    end

    test "the log-in link keeps the page's language and returns to its checkout", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      {view, _html} =
        review_step(conn, product, "/en/checkout", confirmed_account_email(), %{
          "phoenix_kit_test_locale" => "en"
        })

      html = view |> element("button[phx-click='confirm_order']") |> render_click()

      links = assert_only_language(html, "en", "account-exists notice")

      assert (Routes.path("/users/log-in", locale: "en") <>
                "?return_to=" <> Shop.checkout_url("en")) in links
    end

    test "placing the order redirects to the confirmation page of the page's language", %{
      conn: conn
    } do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      {view, _html} =
        review_step(conn, product, "/uk/checkout", nil, %{"phoenix_kit_test_locale" => "uk"})

      view |> element("button[phx-click='confirm_order']") |> render_click()

      {to, _flash} = assert_redirect(view)
      [_, uuid] = Regex.run(~r{/checkout/complete/([0-9a-f-]+)$}, to)
      assert to == Routes.path("/checkout/complete/#{uuid}", locale: "uk")
    end

    test "the order notification links to the language the buyer checked out in" do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      {order, _session_id} = order_for(product)
      order |> customer() |> confirm_user!()

      PhoenixKitEcommerce.Notifications.order_placed(order, language: "en")

      assert [link] = notification_links_mentioning(order.order_number)
      assert link == Routes.path("/dashboard/orders/#{order.uuid}", locale: "en")
    end

    test "a buyer language the site does not serve, or none, gets the primary language's link" do
      product = create_product(%{"uk" => slug("probe")})

      for opts <- [[language: "de"], [language: nil], []] do
        {order, _session_id} = order_for(product)
        order |> customer() |> confirm_user!()

        PhoenixKitEcommerce.Notifications.order_placed(order, opts)

        assert [link] = notification_links_mentioning(order.order_number)
        assert link == Routes.path("/dashboard/orders/#{order.uuid}", locale: "uk")
      end
    end

    test "the order notification follows the page's language even where the shop has no catalogue",
         %{conn: conn} do
      # es, it and pl are languages a site can enable that the shop's own
      # catalogues do not carry: `put_content_locale/1` resets the Gettext
      # locale of such a page to the shop default, the page's language stays.
      configure_languages(true, ["uk", "en", "es", "it", "pl"])
      product = create_product(%{"uk" => slug("probe"), "es" => slug("probe-es")})

      for code <- ["es", "it", "pl"] do
        {uuid, links} =
          checkout_as_user(conn, product, "/#{code}/checkout", %{
            "phoenix_kit_test_locale" => code
          })

        assert Routes.path("/dashboard/orders/#{uuid}", locale: code) in links
      end
    end

    test "the redirect of a checkout whose order is already placed keeps the page's language", %{
      conn: conn
    } do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})
      conn = cart_conn(conn, product, %{"phoenix_kit_test_locale" => "uk"})
      cart = Shop.find_active_cart(session_id: Plug.Conn.get_session(conn, "shop_session_id"))

      {:ok, order} =
        Shop.convert_cart_to_order(cart, billing_data: complete_billing("EE", "links"))

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/uk/checkout")
      assert to == Routes.path("/checkout/complete/#{order.uuid}", locale: "uk")
    end

    test "an order placed from a stale checkout page lands on its confirmation, in the page's language",
         %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      {view, _html} =
        review_step(conn, product, "/uk/checkout", nil, %{"phoenix_kit_test_locale" => "uk"})

      # The cart is converted elsewhere (another tab) while this page is open.
      stale_cart = :sys.get_state(view.pid).socket.assigns.cart

      {:ok, order} =
        Shop.convert_cart_to_order(stale_cart, billing_data: complete_billing("EE", "links"))

      view |> element("button[phx-click='confirm_order']") |> render_click()

      {to, _flash} = assert_redirect(view)
      assert to == Routes.path("/checkout/complete/#{order.uuid}", locale: "uk")
    end

    test "on the primary language's page every checkout link is in that language", %{conn: conn} do
      product = create_product(%{"uk" => slug("probe"), "en" => slug("probe-en")})

      {_view, html} =
        review_step(conn, product, "/uk/checkout", nil, %{"phoenix_kit_test_locale" => "uk"})

      links = assert_only_language(html, "uk", "review step")
      assert Shop.cart_url("uk") in links

      html =
        profile_selector_html(conn, product, "/uk/checkout", %{"phoenix_kit_test_locale" => "uk"})

      links = assert_only_language(html, "uk", "profile selector")
      assert link_to?(links, Routes.path("/dashboard/billing-profiles/", locale: "uk"))
      # The "edit" link of the chosen profile comes back to this page's checkout.
      assert Enum.any?(
               links,
               &String.ends_with?(&1, "/edit?return_to=" <> Shop.checkout_url("uk"))
             )

      {view, _html} =
        review_step(conn, product, "/uk/checkout", confirmed_account_email(), %{
          "phoenix_kit_test_locale" => "uk"
        })

      html = view |> element("button[phx-click='confirm_order']") |> render_click()
      links = assert_only_language(html, "uk", "account-exists notice")

      assert (Routes.path("/users/log-in", locale: "uk") <>
                "?return_to=" <> Shop.checkout_url("uk")) in links
    end

    test "a product with no slug in the page language renders there, in that language", %{
      conn: conn
    } do
      s = slug("probe")
      product = create_product(%{"uk" => s})

      # The page asks for English; the product has only a Ukrainian slug.
      assert {:ok, view, html} = live(conn, "/en/shop/product/#{s}")
      assert html =~ "Link Probe"

      # Back-to-catalog stays in the page language, not the slug's.
      links = assert_only_language(html, "en", "product page")
      assert Shop.catalog_url("en") in links

      # The English page is a duplicate of the Ukrainian one: its canonical
      # URL is the language the slug really belongs to, and hreflang does not
      # advertise a translation the product lacks.
      assigns = :sys.get_state(view.pid).socket.assigns
      assert String.ends_with?(assigns.canonical_url, Shop.product_url(product, "uk"))
      refute String.ends_with?(assigns.canonical_url, Shop.product_url(product, "en"))
      assert assigns.hreflang_links == []
    end

    test "a slug of another language redirects only to the same language's own slug", %{
      conn: conn
    } do
      uk_slug = slug("probe-uk")
      en_slug = slug("probe-en")
      product = create_product(%{"uk" => uk_slug, "en" => en_slug})

      # An English page, asked with the Ukrainian slug: same page language,
      # corrected to the English slug.
      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/en/shop/product/#{uk_slug}")
      assert to == Shop.product_url(product, "en")
    end

    test "a category with no slug in the page language renders there, not in the catalog", %{
      conn: conn
    } do
      s = slug("cat")
      category = create_category(%{"uk" => s})

      assert {:ok, view, html} = live(conn, "/en/shop/category/#{s}")
      assert html =~ "Probe Category"

      links = assert_only_language(html, "en", "category page")
      assert Shop.catalog_url("en") in links

      assigns = :sys.get_state(view.pid).socket.assigns
      assert String.ends_with?(assigns.canonical_url, Shop.category_url(category, "uk"))
      assert assigns.hreflang_links == []
    end

    test "a category slug of another language redirects only to the same language's own slug", %{
      conn: conn
    } do
      uk_slug = slug("cat-uk")
      en_slug = slug("cat-en")
      category = create_category(%{"uk" => uk_slug, "en" => en_slug})

      assert {:error, {:live_redirect, %{to: to}}} = live(conn, "/en/shop/category/#{uk_slug}")
      assert to == Shop.category_url(category, "en")
    end

    test "an unknown category slug goes to the catalog in the page language", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(conn, "/en/shop/category/#{slug("nope")}")

      assert to == Shop.catalog_url("en")
    end
  end

  describe "canonical and hreflang (three languages)" do
    setup do
      configure_languages(true, ["uk", "en", "de"])
      on_exit(&reset_languages/0)
      :ok
    end

    test "a page in a language with its own slug is its own canonical" do
      product = create_product(%{"uk" => slug("p-uk"), "en" => slug("p-en")})

      seo = SEOHelpers.product_seo(product, "en")

      assert String.ends_with?(seo.canonical_url, Shop.product_url(product, "en"))
      assert seo.og.url == seo.canonical_url
    end

    test "a page in a language without a slug points at the primary language's page" do
      product = create_product(%{"uk" => slug("p-uk"), "en" => slug("p-en")})

      seo = SEOHelpers.product_seo(product, "de")

      assert String.ends_with?(seo.canonical_url, Shop.product_url(product, "uk"))
      assert seo.og.url == seo.canonical_url
      assert seo.og.locale == "de"
    end

    test "with no slug in the primary language either, the first language that has one" do
      product = create_product(%{"en" => slug("p-en")})

      seo = SEOHelpers.product_seo(product, "de")

      assert String.ends_with?(seo.canonical_url, Shop.product_url(product, "en"))
    end

    test "hreflang lists only the languages the raw slug map has" do
      product = create_product(%{"uk" => slug("p-uk"), "en" => slug("p-en")})

      codes = product |> SEOHelpers.product_seo("de") |> Map.fetch!(:hreflang_links)

      assert codes |> Enum.map(& &1.code) |> Enum.sort() == ["en", "uk"]
    end

    test "a blank slug is no translation: not a hreflang, not a canonical" do
      product = create_product(%{"uk" => slug("p-uk"), "en" => "", "de" => nil})

      seo = SEOHelpers.product_seo(product, "en")

      assert String.ends_with?(seo.canonical_url, Shop.product_url(product, "uk"))
      assert seo.hreflang_links == []
      refute Helpers.slug_translated?(product.slug, "en")
      refute Helpers.slug_translated?(product.slug, "de")
      assert Helpers.slug_translated?(product.slug, "uk-UA")
      assert Helpers.requested_translation_lang(product, "en") == nil
    end

    test "categories follow the same rules" do
      category = create_category(%{"uk" => slug("c-uk"), "en" => slug("c-en")})

      own = SEOHelpers.category_seo(category, "en")
      other = SEOHelpers.category_seo(category, "de")

      assert String.ends_with?(own.canonical_url, Shop.category_url(category, "en"))
      assert String.ends_with?(other.canonical_url, Shop.category_url(category, "uk"))
      assert other.hreflang_links |> Enum.map(& &1.code) |> Enum.sort() == ["en", "uk"]
    end
  end

  describe "canonical on a single-language site" do
    setup do
      configure_languages(false, ["uk"])
      on_exit(&reset_languages/0)
      :ok
    end

    test "a page is its own canonical and advertises no alternates" do
      product = create_product(%{"uk" => slug("p-uk"), "en" => slug("p-en")})

      seo = SEOHelpers.product_seo(product, "uk")

      assert seo.hreflang_links == []
      refute URI.parse(seo.canonical_url).path =~ @segment
    end
  end

  describe "admin screens without a locale segment" do
    test "the test router mounts them, as Routes.path/2 emits them on a single-language site",
         %{conn: conn} do
      conn = put_test_scope(conn, fake_scope())

      for path <- ~w(/admin/shop /admin/shop/products /admin/shop/categories
                     /admin/shop/shipping /admin/shop/carts /admin/shop/settings) do
        assert {:ok, _view, _html} = live(conn, path)
      end
    end
  end

  test "Routes still builds the same path the storefront does" do
    configure_languages(true, ["uk", "en"])
    on_exit(&reset_languages/0)

    assert Shop.cart_url("en") == Routes.path("/cart", locale: "en")
  end
end
