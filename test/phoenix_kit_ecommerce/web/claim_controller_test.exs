defmodule PhoenixKitEcommerce.Web.ClaimControllerTest do
  @moduledoc """
  The buyer's side of the hand-off: GET consumes nothing and shows the right
  choice; POST needs the CSRF token, consumes once, and every dead end is a
  redirect with a notice, never an error page.
  """

  # async: false - the signing secret and settings are shared.
  use PhoenixKitEcommerce.LiveCase, async: false
  @moduletag :requires_core_api

  import Ecto.Query
  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.CartWriter
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Web.ClaimController
  alias PhoenixKitEcommerce.Web.Helpers

  @compile {:no_warn_undefined, PhoenixKitWebAnalytics.Plug}

  setup %{conn: conn} do
    put_secret!()
    ensure_currencies!()

    session = "browser-#{System.unique_integer([:positive])}"
    conn = Plug.Test.init_test_session(conn, %{"shop_session_id" => session})
    p1 = product!()
    p2 = product!()

    token = new_token!()
    {:ok, hash} = CartToken.verify(token)

    {:ok, _} =
      CartWriter.set_items(
        hash,
        %{
          "items" => [
            %{"product_id" => p1.uuid, "quantity" => 2},
            %{"product_id" => p2.uuid, "quantity" => 1}
          ]
        },
        ctx_for(token)
      )

    {:ok, cart} = CartStore.resolve(hash)
    {:ok, %{token: raw, claim: claim}} = Claims.issue(cart, hash, "en")

    %{
      conn: conn,
      session: session,
      token: token,
      raw: raw,
      claim: claim,
      api_cart: cart,
      hash: hash,
      p1: p1,
      p2: p2
    }
  end

  defp page(conn, raw), do: get(conn, Claims.path(raw))

  # A fresh API cart holding `products` (one unit each) and a claim for it.
  defp claim_for!(products) do
    token = new_token!()
    {:ok, hash} = CartToken.verify(token)
    input = %{"items" => Enum.map(products, &%{"product_id" => &1.uuid, "quantity" => 1})}
    {:ok, _} = CartWriter.set_items(hash, input, ctx_for(token))
    {:ok, cart} = CartStore.resolve(hash)
    {:ok, %{token: raw}} = Claims.issue(cart, hash, "en")
    {raw, cart}
  end

  # A trigger raises what Postgres raises for the aborted side of a deadlock
  # (SQLSTATE 40P01); the DDL rolls back with the test's transaction.
  defp raise_deadlock_on_cart_item_insert! do
    Repo.query!("""
    CREATE FUNCTION pk_test_raise_deadlock() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'simulated deadlock' USING ERRCODE = '40P01'; END
    $$
    """)

    Repo.query!("""
    CREATE TRIGGER pk_test_raise_deadlock BEFORE INSERT ON phoenix_kit_shop_cart_items
    FOR EACH ROW EXECUTE FUNCTION pk_test_raise_deadlock()
    """)
  end

  # The page the redirect points at, with the cookie (and so the flash) carried over.
  defp follow(conn), do: conn |> recycle() |> get(redirected_to(conn))

  defp texts(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text()
  end

  # The gettext locale belongs to the test process: put it back to English so that a
  # German assertion proves the controller set it, not an earlier call of the test.
  defp reset_locale, do: Helpers.put_content_locale("en")

  # A German claim on a site with English and German switched on, so that the cart and
  # checkout URLs of the two languages differ.
  defp german_claim!(ctx) do
    :ok = PhoenixKitEcommerce.SearchFixtures.enable_languages!(["en", "de"])
    {:ok, %{token: german}} = Claims.issue(ctx.api_cart, ctx.hash, "de")
    german
  end

  defp csrf_token(html) do
    [input] = Regex.run(~r/<input[^>]*name="_csrf_token"[^>]*>/, html)
    [_, token] = Regex.run(~r/value="([^"]+)"/, input)
    token
  end

  defp active_carts(session),
    do: Repo.all(from c in Cart, where: c.status == "active" and c.session_id == ^session)

  defp active_carts_of(user),
    do: Repo.all(from c in Cart, where: c.status == "active" and c.user_uuid == ^user.uuid)

  # `updated_at` has second precision: make "the newest cart" unambiguous.
  defp newest!(cart) do
    later = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: [updated_at: later])
  end

  defp signed_in(conn, user),
    do: Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => %{user: user}})

  describe "GET" do
    test "shows the lines and one button, and consumes nothing however often it is opened", ctx do
      html =
        Enum.reduce(1..4, nil, fn _, _ ->
          conn = page(ctx.conn, ctx.raw)
          assert conn.status == 200
          assert ["no-referrer"] = get_resp_header(conn, "referrer-policy")
          assert ["no-store" <> _] = get_resp_header(conn, "cache-control")
          assert ["noindex, nofollow"] = get_resp_header(conn, "x-robots-tag")
          html_response(conn, 200)
        end)

      assert html =~ ~s(id="claim-page")
      assert html =~ ~s(id="claim-lines")
      assert html =~ ~s(id="claim-continue")
      assert html =~ ~s(name="offer" value="none")
      assert html =~ ctx.p1.title["en"]
      refute html =~ ~s(id="claim-replace")
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end

    test "offers replace and add when the browser already has a cart with items", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(id="claim-replace")
      assert html =~ ~s(id="claim-add")
      refute html =~ ~s(id="claim-continue")
      assert html =~ ~s(name="offer" value="#{mine.uuid}")
    end

    test "an empty cart of the browser is not a choice", ctx do
      {:ok, _empty} = Shop.create_cart(session_id: ctx.session)

      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(id="claim-continue")
    end

    test "a logged-in buyer who owns a cart with lines is offered it", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, mine} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      html = ctx.conn |> signed_in(user) |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(id="claim-add")
      assert html =~ ~s(id="claim-replace")
      refute html =~ ~s(id="claim-continue")
      assert html =~ ~s(name="offer" value="#{mine.uuid}")
    end

    # The browser's cart is the one the storefront shows (`Shop.find_active_cart/1`): the
    # user's own cart first. A newer guest cart with lines does not outrank an older cart
    # the user owns, so the claim never sits beside a second cart for the user.
    test "a user's own empty cart is the browser's cart, whatever newer guest cart exists", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, _empty} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, guest} = Shop.create_cart(session_id: ctx.session)
      {:ok, guest} = Shop.add_to_cart(guest, product!(), 1)
      newest!(guest)

      conn = signed_in(ctx.conn, user)
      html = conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(id="claim-continue")
      assert html =~ ~s(name="offer" value="none")

      stale =
        post_claim(conn, ctx.raw, %{"offer" => guest.uuid, "choice" => "replace"})

      assert redirected_to(stale) == Claims.path(ctx.raw)
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil

      done = post_claim(conn, ctx.raw, %{"offer" => "none"})

      assert redirected_to(done) == Shop.checkout_url("en")
      assert [only] = active_carts_of(user)
      assert only.uuid == ctx.api_cart.uuid
      found = Shop.find_active_cart(user_uuid: user.uuid, session_id: ctx.session)
      assert found.uuid == ctx.api_cart.uuid
    end

    test "a user's own cart with lines is offered, however new an empty guest cart is", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, mine} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)
      {:ok, empty_guest} = Shop.create_cart(session_id: ctx.session)
      newest!(empty_guest)

      conn = signed_in(ctx.conn, user)
      html = conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(name="offer" value="#{mine.uuid}")
      refute html =~ ~s(id="claim-continue")

      skipped = post_claim(conn, ctx.raw, %{"offer" => "none"})
      assert redirected_to(skipped) == Claims.path(ctx.raw)
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil

      done = post_claim(conn, ctx.raw, %{"offer" => mine.uuid, "choice" => "replace"})

      assert redirected_to(done) == Shop.checkout_url("en")
      assert [only] = active_carts_of(user)
      assert only.uuid == ctx.api_cart.uuid
      found = Shop.find_active_cart(user_uuid: user.uuid, session_id: ctx.session)
      assert found.uuid == ctx.api_cart.uuid
    end

    test "two active carts of the browser never make an error page", ctx do
      {:ok, _first} = Shop.create_cart(session_id: ctx.session)
      {:ok, second} = Shop.create_cart(session_id: ctx.session)
      {:ok, second} = Shop.add_to_cart(second, product!(), 1)
      newest!(second)

      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      assert html =~ ~s(name="offer" value="#{second.uuid}")
    end

    test "speaks the claim's language", ctx do
      {:ok, %{token: german}} = Claims.issue(ctx.api_cart, ctx.hash, "de")

      conn = page(ctx.conn, german)
      html = html_response(conn, 200)

      assert html =~ "Weiter zur Kasse"
      assert conn.assigns.content_language == "de"
      assert html =~ "Ein Assistent hat diesen Warenkorb"
    end

    test "unknown, superseded and expired links go to the cart page with a notice", ctx do
      {:ok, %{token: newer}} = Claims.issue(ctx.api_cart, ctx.hash, "en")

      expired =
        Repo.get!(
          CartClaim,
          Repo.one(from k in CartClaim, where: is_nil(k.superseded_at), select: k.uuid)
        )

      expired
      |> Ecto.Changeset.change(
        expires_at: DateTime.add(DateTime.utc_now(), -5, :second) |> DateTime.truncate(:second)
      )
      |> Repo.update!()

      for raw <- ["nope-not-a-real-token", ctx.raw, newer] do
        conn = page(ctx.conn, raw)

        assert redirected_to(conn) == Shop.cart_url("en"), inspect(raw)
        assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "already been used or has expired"
      end
    end

    test "a dead link of a German claim goes to the German cart page with a German notice", ctx do
      german = german_claim!(ctx)
      {:ok, %{token: _newer}} = Claims.issue(ctx.api_cart, ctx.hash, "de")
      refute Shop.cart_url("de") == Shop.cart_url("en")

      conn = page(ctx.conn, german)

      assert redirected_to(conn) == Shop.cart_url("de")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "bereits verwendet"
    end

    test "lists the lines in uuid order, whatever order the database returns them in", ctx do
      [later, earlier] = ctx.api_cart.items |> Enum.map(& &1.uuid) |> Enum.sort(:desc)
      # The update moves the row to the end of the table: this line is read last, and
      # its new uuid sorts first.
      smallest = "00000000-0000-7000-8000-000000000000"

      Repo.update_all(
        from(i in PhoenixKitEcommerce.CartItem, where: i.uuid == ^later),
        set: [uuid: smallest]
      )

      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      ids = ~r/id="claim-line-([0-9a-f-]+)"/ |> Regex.scan(html) |> Enum.map(&List.last/1)

      assert ids == [smallest, earlier]
    end

    test "speaks the language of a dialect claim", ctx do
      {:ok, %{token: dialect}} = Claims.issue(ctx.api_cart, ctx.hash, "de-DE")

      conn = page(ctx.conn, dialect)
      html = html_response(conn, 200)

      assert html =~ "Weiter zur Kasse"
      assert conn.assigns.content_language == "de-DE"
    end

    test "a cart that is gone goes to the cart page with the same notice", ctx do
      Repo.update_all(from(c in Cart, where: c.uuid == ^ctx.api_cart.uuid),
        set: [status: "abandoned"]
      )

      conn = page(ctx.conn, ctx.raw)

      assert redirected_to(conn) == Shop.cart_url("en")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "already been used or has expired"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end

    test "shows the options of a line", ctx do
      shirt = product_with_options!(%{"color" => ["Red", "Blue"]})
      token = new_token!()
      {:ok, hash} = CartToken.verify(token)

      {:ok, _} =
        CartWriter.set_items(
          hash,
          %{
            "items" => [
              %{
                "product_id" => shirt.uuid,
                "quantity" => 1,
                "options" => [%{"attribute_key" => "color", "value_key" => "red"}]
              }
            ]
          },
          ctx_for(token)
        )

      {:ok, cart} = CartStore.resolve(hash)
      {:ok, %{token: raw}} = Claims.issue(cart, hash, "en")

      html = ctx.conn |> page(raw) |> html_response(200)

      assert html =~ "Color:"
      assert html =~ "Red"
    end

    test "a line priced on request says so, shows no price, and the subtotal says what it leaves out",
         ctx do
      quote_me =
        product!(%{
          "title" => %{"en" => "Quote me"},
          "price" => Decimal.new("0.00"),
          "metadata" => %{"_price_display" => %{"on_request" => true}}
        })

      {raw, cart} = claim_for!([quote_me, product!(%{"price" => Decimal.new("10.00")})])
      line = Enum.find(cart.items, &(&1.product_uuid == quote_me.uuid))

      html = ctx.conn |> page(raw) |> html_response(200)
      row = texts(html, "#claim-line-#{line.uuid}")

      assert row =~ "Quote me"
      assert row =~ "Price on request"
      refute row =~ "0.00"
      assert texts(html, "#claim-subtotal") =~ "10.00"
      assert texts(html, "#claim-on-request-note") =~ "Items priced on request are not included"
    end

    test "a cart of priced lines carries no on-request note", ctx do
      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      refute html =~ ~s(id="claim-on-request-note")
      refute html =~ "Price on request"
    end

    test "shows product titles without the configured name prefix", ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("shop_name_prefixes", "3D Printed")
      mask = product!(%{"title" => %{"en" => "3D Printed Costume Mask"}})
      {raw, cart} = claim_for!([mask])
      [line] = cart.items

      html = ctx.conn |> page(raw) |> html_response(200)

      assert texts(html, "#claim-line-#{line.uuid}") =~ "Costume Mask"
      refute html =~ "3D Printed"
    end

    test "a shop that is switched off is not touched", ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")

      conn = page(ctx.conn, ctx.raw)

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "currently unavailable"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end
  end

  describe "web analytics" do
    # Needs the optional analytics module (`test_helper.exs` excludes `:analytics`
    # when it is not loaded, so a missing dependency shows up in the `excluded`
    # count instead of the test passing without asserting anything).
    @tag :analytics
    test "the claim page marks itself as not to be tracked, whatever the exclusion setting holds",
         ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("web_analytics_exclude_paths", "/admin*")

      conn = page(ctx.conn, ctx.raw)

      assert html_response(conn, 200) =~ ~s(id="claim-page")
      assert PhoenixKitWebAnalytics.Plug.skipped?(conn)
    end
  end

  # A POST the way the page makes it: the form carries the revision of the cart
  # it showed, which `Claims.redeem/3` requires.
  defp post_claim(conn, raw, params),
    do: post(conn, Claims.path(raw), Map.put_new(params, "revision", claim_revision(raw)))

  describe "POST and the cart the page showed" do
    defp shown_revision(html) do
      [input] = Regex.run(~r/<input[^>]*name="revision"[^>]*>/, html)
      [_, revision] = Regex.run(~r/value="([^"]+)"/, input)
      revision
    end

    # The agent writes to its cart after the buyer's page was rendered.
    defp agent_changes_cart!(ctx) do
      input = %{"items" => [%{"product_id" => ctx.p1.uuid, "quantity" => 5}]}
      {:ok, _} = CartWriter.set_items(ctx.hash, input, ctx_for(ctx.token))
    end

    test "the page carries the revision of the cart it shows", ctx do
      html = ctx.conn |> page(ctx.raw) |> html_response(200)

      assert shown_revision(html) == CartView.revision(Shop.get_cart(ctx.api_cart.uuid))
    end

    test "a cart the agent changed after the page was shown is shown again, not moved", ctx do
      shown = ctx.conn |> page(ctx.raw) |> html_response(200) |> shown_revision()
      agent_changes_cart!(ctx)

      conn = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none", "revision" => shown})

      assert redirected_to(conn) == Claims.path(ctx.raw)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Please choose again"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert active_carts(ctx.session) == []
      assert Repo.get!(Cart, ctx.api_cart.uuid).session_id == "api:" <> ctx.hash

      # The page shows the cart as it is now; confirming that one claims it.
      fresh = ctx.conn |> page(ctx.raw) |> html_response(200) |> shown_revision()
      refute fresh == shown

      done = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none", "revision" => fresh})

      assert redirected_to(done) == Shop.checkout_url("en")
      assert [%{items: items}] = ctx.session |> active_carts() |> Repo.preload(:items)
      assert Enum.any?(items, &(&1.quantity == 5))
    end

    test "a POST without a revision shows the page again and leaves the claim unused", ctx do
      conn = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none"})

      assert redirected_to(conn) == Claims.path(ctx.raw)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Please choose again"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert active_carts(ctx.session) == []
      assert Repo.get!(Cart, ctx.api_cart.uuid).session_id == "api:" <> ctx.hash
    end

    test "a malformed revision cannot match any cart", ctx do
      for bad <- ["", "0000", ["x"], %{"a" => "b"}] do
        conn = post(ctx.conn, Claims.path(ctx.raw), %{"offer" => "none", "revision" => bad})

        assert redirected_to(conn) == Claims.path(ctx.raw)
      end

      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end
  end

  describe "POST" do
    test "continue moves the cart to the browser and goes to checkout", ctx do
      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})

      assert redirected_to(conn) == Shop.checkout_url("en")
      assert [cart] = active_carts(ctx.session)
      assert cart.uuid == ctx.api_cart.uuid
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at != nil
      assert {:locked, %CartClaim{}} = CartStore.resolve(ctx.hash)
    end

    test "a second POST claims nothing again and shows the cart page", ctx do
      first = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})
      assert redirected_to(first) == Shop.checkout_url("en")
      used_at = Repo.get!(CartClaim, ctx.claim.uuid).used_at

      second = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})

      assert redirected_to(second) == Shop.cart_url("en")
      assert Phoenix.Flash.get(second.assigns.flash, :info) =~ "already been used or has expired"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == used_at
      assert [_one] = active_carts(ctx.session)
    end

    test "a browser cart that appeared after the page was shown sends the buyer back to the choice",
         ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, _mine} = Shop.add_to_cart(mine, product!(), 1)

      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})

      assert redirected_to(conn) == Claims.path(ctx.raw)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Please choose again"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert [still_mine] = active_carts(ctx.session)
      refute still_mine.uuid == ctx.api_cart.uuid
    end

    test "replace abandons the buyer's cart and leaves exactly one active cart", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      replace =
        post_claim(ctx.conn, ctx.raw, %{"offer" => mine.uuid, "choice" => "replace"})

      assert redirected_to(replace) == Shop.checkout_url("en")
      assert [only] = active_carts(ctx.session)
      assert only.uuid == ctx.api_cart.uuid
      assert Repo.get!(Cart, mine.uuid).status == "abandoned"
    end

    test "add merges, and names the lines it had to skip", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(conn) == Shop.checkout_url("en")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no longer available"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Widget"
      assert [only] = active_carts(ctx.session)
      assert only.uuid == mine.uuid
      assert Repo.get!(Cart, ctx.api_cart.uuid).status == "merged"
    end

    # The notice rides in the cookie-backed session (4096 bytes in all): a long skipped list
    # must never turn a claim that was consumed into an error page.
    test "add names a bounded few of many skipped lines and still ends at checkout", ctx do
      long = String.duplicate("long product title ", 7)
      lots = for n <- 1..30, do: product!(%{"title" => %{"en" => "#{n} #{long}"}})
      {raw, cart} = claim_for!(lots)
      for product <- lots, do: {:ok, _} = Shop.update_product(product, %{"status" => "archived"})
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      conn = post_claim(ctx.conn, raw, %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(conn) == Shop.checkout_url("en")
      notice = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert notice =~ "no longer available"
      assert String.ends_with?(notice, "\u2026")
      assert byte_size(notice) < 600
      assert Repo.get!(Cart, cart.uuid).status == "merged"
    end

    test "a title is cut and a short list is named in full", ctx do
      long = String.duplicate("w", 100)
      cut = product!(%{"title" => %{"en" => long}})
      {raw, _cart} = claim_for!([cut])
      {:ok, _} = Shop.update_product(cut, %{"status" => "archived"})
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      conn = post_claim(ctx.conn, raw, %{"offer" => mine.uuid, "choice" => "add"})

      notice = Phoenix.Flash.get(conn.assigns.flash, :error)
      refute notice =~ long
      assert notice =~ String.duplicate("w", 59) <> "\u2026"
      refute String.ends_with?(notice, ", \u2026")
    end

    test "skipped lines are named without the configured name prefix", ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("shop_name_prefixes", "3D Printed")
      mask = product!(%{"title" => %{"en" => "3D Printed Costume Mask"}})
      {raw, _cart} = claim_for!([mask])
      {:ok, _} = Shop.update_product(mask, %{"status" => "archived"})
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      conn = post_claim(ctx.conn, raw, %{"offer" => mine.uuid, "choice" => "add"})

      notice = Phoenix.Flash.get(conn.assigns.flash, :error)
      assert notice =~ "Costume Mask"
      refute notice =~ "3D Printed"
    end

    test "a used German claim goes to the German cart page with a German notice", ctx do
      german = german_claim!(ctx)
      first = post_claim(ctx.conn, german, %{"offer" => "none"})
      assert redirected_to(first) == Shop.checkout_url("de")
      reset_locale()

      second = post_claim(ctx.conn, german, %{"offer" => "none"})

      assert redirected_to(second) == Shop.cart_url("de")
      assert Phoenix.Flash.get(second.assigns.flash, :info) =~ "bereits verwendet"
    end

    test "skipped lines of a German claim are named in German", ctx do
      german = german_claim!(ctx)
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)
      {:ok, _} = Shop.update_product(ctx.p2, %{"status" => "archived"})

      conn = post_claim(ctx.conn, german, %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(conn) == Shop.checkout_url("de")
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "nicht mehr verfügbar"
    end

    test "a stale choice on a German claim is explained in German on the claim page", ctx do
      german = german_claim!(ctx)
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, _mine} = Shop.add_to_cart(mine, product!(), 1)

      conn = post_claim(ctx.conn, german, %{"offer" => "none"})

      assert redirected_to(conn) == Claims.path(german)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "hat sich geändert"
      reset_locale()
      assert conn |> follow() |> html_response(200) |> texts("#claim-notice-info") =~ "hat sich"
    end

    test "the claim page shows the notice of a stale choice", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, _mine} = Shop.add_to_cart(mine, product!(), 1)

      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})
      assert redirected_to(conn) == Claims.path(ctx.raw)
      html = conn |> follow() |> html_response(200)

      assert texts(html, "#claim-notice-info") =~ "Please choose again"
      assert texts(html, "#claim-add") =~ "Add these items"
    end

    test "a notice is shown once", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, _mine} = Shop.add_to_cart(mine, product!(), 1)

      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})
      shown = conn |> follow()
      assert texts(html_response(shown, 200), "#claim-notice-info") =~ "Please choose again"

      again = shown |> recycle() |> get(Claims.path(ctx.raw)) |> html_response(200)
      assert texts(again, "#claim-notice-info") == ""
    end

    test "an unexpected refusal goes to the cart page with the generic notice, logging the atom only",
         ctx do
      german = german_claim!(ctx)
      conn = ctx.conn |> Phoenix.Controller.fetch_flash([])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn = ClaimController.redeem_reply(conn, german, {:error, :surprise})

          assert redirected_to(conn) == Shop.cart_url("de")
          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Etwas ist schiefgelaufen"
        end)

      assert log =~ "surprise"
      refute log =~ german
    end

    test "an unexpected refusal that is not an atom is not logged", ctx do
      conn = ctx.conn |> Phoenix.Controller.fetch_flash([])

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          conn =
            ClaimController.redeem_reply(conn, ctx.raw, {:error, %{secret: "do-not-log-me"}})

          assert redirected_to(conn) == Shop.cart_url("en")
          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Something went wrong"
        end)

      refute log =~ "do-not-log-me"
      refute log =~ ctx.raw
    end

    test "a dialect claim ends at the checkout of its language", ctx do
      {:ok, %{token: dialect}} = Claims.issue(ctx.api_cart, ctx.hash, "de-DE")

      conn = post_claim(ctx.conn, dialect, %{"offer" => "none"})

      assert redirected_to(conn) == Shop.checkout_url("de-DE")
      assert [cart] = active_carts(ctx.session)
      assert cart.uuid == ctx.api_cart.uuid
    end

    test "a cart that is gone consumes nothing and shows the cart page", ctx do
      Repo.update_all(from(c in Cart, where: c.uuid == ^ctx.api_cart.uuid),
        set: [status: "abandoned"]
      )

      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})

      assert redirected_to(conn) == Shop.cart_url("en")
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "already been used or has expired"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert active_carts(ctx.session) == []
    end

    test "junk parameters are a choice again, never a crash", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      for params <- [
            %{},
            %{"offer" => ["x"]},
            %{"offer" => mine.uuid, "choice" => ["add"]},
            %{"offer" => mine.uuid, "choice" => "steal"}
          ] do
        conn = post_claim(ctx.conn, ctx.raw, params)
        assert redirected_to(conn) == Claims.path(ctx.raw), inspect(params)
      end

      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
    end

    test "is refused without the CSRF token and accepted with it", ctx do
      page_conn = page(ctx.conn, ctx.raw)
      token = csrf_token(html_response(page_conn, 200))

      refused =
        page_conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)

      assert_error_sent 403, fn -> post_claim(refused, ctx.raw, %{"offer" => "none"}) end
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil

      accepted =
        page_conn
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> post(Claims.path(ctx.raw), %{
          "offer" => "none",
          "revision" => claim_revision(ctx.raw),
          "_csrf_token" => token
        })

      assert redirected_to(accepted) == Shop.checkout_url("en")
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at != nil
    end

    test "a browser the shop has not seen before can open the page and post it", ctx do
      first = page(build_conn(), ctx.raw)
      token = csrf_token(html_response(first, 200))

      conn =
        first
        |> recycle()
        |> put_private(:plug_skip_csrf_protection, false)
        |> post(Claims.path(ctx.raw), %{
          "offer" => "none",
          "revision" => claim_revision(ctx.raw),
          "_csrf_token" => token
        })

      assert redirected_to(conn) == Shop.checkout_url("en")
      moved = Repo.get!(Cart, ctx.api_cart.uuid)
      assert moved.status == "active"
      refute String.starts_with?(moved.session_id, "api:")
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at != nil
    end

    test "a logged-in buyer receives the claimed cart as their own", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()

      response =
        ctx.conn |> signed_in(user) |> post_claim(ctx.raw, %{"offer" => "none"})

      assert redirected_to(response) == Shop.checkout_url("en")
      assert [found] = active_carts_of(user)
      assert found.uuid == ctx.api_cart.uuid
      assert found.user_uuid == user.uuid
      assert found.expires_at == nil
    end

    test "a logged-in buyer who owns a cart ends with exactly one active cart, either way", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, mine} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)
      conn = signed_in(ctx.conn, user)

      replaced =
        post_claim(conn, ctx.raw, %{"offer" => mine.uuid, "choice" => "replace"})

      assert redirected_to(replaced) == Shop.checkout_url("en")
      assert [only] = active_carts_of(user)
      assert only.uuid == ctx.api_cart.uuid
      assert Repo.get!(Cart, mine.uuid).status == "abandoned"
    end

    test "a logged-in buyer who adds keeps their own cart as the only active one", ctx do
      user = PhoenixKitEcommerce.DataCase.fixture_user()
      {:ok, mine} = Shop.create_cart(user_uuid: user.uuid)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      added =
        ctx.conn
        |> signed_in(user)
        |> post_claim(ctx.raw, %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(added) == Shop.checkout_url("en")
      assert [only] = active_carts_of(user)
      assert only.uuid == mine.uuid
      assert Repo.get!(Cart, ctx.api_cart.uuid).status == "merged"
    end

    test "the notice of a closed shop does not inherit the previous request's language", ctx do
      {:ok, %{token: german}} = Claims.issue(ctx.api_cart, ctx.hash, "de")
      assert ctx.conn |> page(german) |> html_response(200) =~ "Weiter zur Kasse"

      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")
      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "The shop is currently unavailable"
    end

    test "a shop that is switched off consumes nothing", ctx do
      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")

      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => "none"})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "currently unavailable"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert Repo.get!(Cart, ctx.api_cart.uuid).status == "active"
      assert Repo.get!(Cart, ctx.api_cart.uuid).session_id == "api:" <> ctx.hash
    end

    test "a deadlock victim goes back to the choice, with nothing claimed", ctx do
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)

      raise_deadlock_on_cart_item_insert!()

      conn = post_claim(ctx.conn, ctx.raw, %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(conn) == Claims.path(ctx.raw)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Your cart was not changed"
      assert Repo.get!(CartClaim, ctx.claim.uuid).used_at == nil
      assert Repo.get!(Cart, ctx.api_cart.uuid).status == "active"

      html = conn |> follow() |> html_response(200)
      assert texts(html, "#claim-notice-error") =~ "Your cart was not changed"
    end

    test "a deadlock victim on a German claim is told in German", ctx do
      german = german_claim!(ctx)
      {:ok, mine} = Shop.create_cart(session_id: ctx.session)
      {:ok, mine} = Shop.add_to_cart(mine, product!(), 1)
      raise_deadlock_on_cart_item_insert!()

      conn = post_claim(ctx.conn, german, %{"offer" => mine.uuid, "choice" => "add"})

      assert redirected_to(conn) == Claims.path(german)
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Warenkorb wurde nicht geändert"
    end
  end
end
