defmodule PhoenixKitEcommerce.API.CartApiTest do
  @moduledoc """
  The seven cart tools through core's real `Auth` and `Executor`, each at least
  once with a success and with an error: switches, schema validation, the
  handlers, the response.
  """

  # async: false - settings, the key-less public buckets and the signing secret are shared.
  use PhoenixKitEcommerce.DataCase, async: false
  @moduletag :requires_core_api

  # Core's API modules exist only in the core that carries the shop API; this file is
  # compiled (and its tests excluded) against a core that has none.
  @compile {:no_warn_undefined, [PhoenixKit.API.Idempotency, PhoenixKit.API.Validator]}

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKit.API.Idempotency
  alias PhoenixKit.API.Validator
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartHandlers
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartTools
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim

  setup do
    put_secret!()
    ensure_currencies!()
    %{p1: product!(), p2: product!(), physical: physical_product!()}
  end

  defp call(tool, input, opts \\ []), do: call_tool(tool, input, opts)

  defp new_cart_token do
    {200, %{"cart_token" => token}, _conn} = call("shop.create_cart", %{})
    token
  end

  defp items(lines) do
    Enum.map(lines, fn {product, quantity} ->
      %{"product_id" => product.uuid, "quantity" => quantity}
    end)
  end

  defp write(token, lines, extra \\ %{}) do
    call(
      "shop.set_cart_items",
      Map.merge(%{"cart_token" => token, "items" => items(lines)}, extra)
    )
  end

  defp method!(attrs \\ %{}) do
    {:ok, method} =
      Shop.create_shipping_method(
        Map.merge(
          %{
            "name" => "M#{System.unique_integer([:positive])}",
            "price" => Decimal.new("4.00"),
            "active" => true
          },
          attrs
        )
      )

    method
  end

  describe "shop.create_cart" do
    test "returns a signed token and the idle lifetime, and creates no row" do
      before = Repo.aggregate(Cart, :count)

      assert {200, %{"cart_token" => token, "expires_in_seconds" => 604_800}, _} =
               call("shop.create_cart", %{})

      assert {:ok, _hash} = CartToken.verify(token)
      assert Repo.aggregate(Cart, :count) == before
    end

    test "refuses extra input, and a dry run returns no token" do
      assert {422, %{"code" => "validation_failed"}, _} = call("shop.create_cart", %{"junk" => 1})

      assert {:preview, %{expires_in_seconds: 604_800}, _} =
               CartHandlers.create_cart(%{}, ctx(%{dry_run?: true}))
    end

    test "fails closed without a signing secret" do
      Application.delete_env(:phoenix_kit, :secret_key_base)

      assert {:error, :internal_error, _message, %{}} = CartHandlers.create_cart(%{}, ctx())
    end
  end

  describe "shop.get_cart" do
    test "a fresh token reads as an empty open cart" do
      token = new_cart_token()

      assert {200, body, _} = call("shop.get_cart", %{"cart_token" => token})

      assert %{"status" => "open", "lines" => [], "currency" => "USD", "revision" => revision} =
               body

      assert is_binary(revision)
      assert body["totals"]["total"] == %{"amount" => "0.00", "currency" => "USD"}
    end

    test "shows the lines after a write", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 2}])

      assert {200, %{"lines" => [line]}, _} = call("shop.get_cart", %{"cart_token" => token})
      assert line["product_id"] == p1.uuid
      assert line["quantity"] == 2
      assert line["unit_price"] == %{"amount" => "10.00", "currency" => "USD"}
      assert line["line_total"] == %{"amount" => "20.00", "currency" => "USD"}
    end
  end

  describe "option labels on the lines" do
    setup do
      cup =
        product!(%{
          "metadata" => %{
            "_option_values" => %{"cup_color" => ["Red Gold"]},
            "_option_labels" => %{"cup_color" => "Cup colour"}
          }
        })

      %{cup: cup}
    end

    defp cup_line(cup) do
      %{
        "product_id" => cup.uuid,
        "quantity" => 1,
        "options" => [%{"attribute_key" => "cup_color", "value_key" => "red-gold"}]
      }
    end

    test "set_cart_items and get_cart name the option and the value beside their keys, in every language",
         %{cup: cup} do
      :ok = PhoenixKitEcommerce.SearchFixtures.enable_languages!(["en", "de", "fr"])
      token = new_cart_token()

      expected = [
        %{
          "attribute_key" => "cup_color",
          "value_key" => "red-gold",
          "attribute_label" => "Cup colour",
          "value_label" => "Red Gold"
        }
      ]

      for language <- ["en", "de", "fr"] do
        assert {200, %{"cart" => %{"lines" => [%{"options" => ^expected}]}}, _} =
                 call("shop.set_cart_items", %{
                   "cart_token" => token,
                   "items" => [cup_line(cup)],
                   "language" => language
                 })

        assert {200, %{"lines" => [%{"options" => ^expected}]}, _} =
                 call("shop.get_cart", %{"cart_token" => token, "language" => language})
      end
    end

    test "a line whose product was deleted still reads with labels, never bare keys", %{cup: cup} do
      token = new_cart_token()

      {200, _, _} =
        call("shop.set_cart_items", %{"cart_token" => token, "items" => [cup_line(cup)]})

      {:ok, _} = Shop.delete_product(cup)

      assert {200, %{"lines" => [%{"status" => "unavailable", "options" => [option]}]}, _} =
               call("shop.get_cart", %{"cart_token" => token})

      assert option["attribute_label"] == "Cup Color"
      assert option["value_label"] == "Red Gold"
    end

    test "the output schema of the cart describes them" do
      schema = Enum.find(CartTools.tools(), &(&1.name == "shop.get_cart")).output_schema
      options = schema["properties"]["lines"]["items"]["properties"]["options"]

      assert options["items"]["properties"] |> Map.keys() |> Enum.sort() ==
               ["attribute_key", "attribute_label", "value_key", "value_label"]
    end
  end

  describe "the price shop.get_products quotes for an option value" do
    test "is the unit price the cart charges, for an option of the global schema" do
      {:ok, _} =
        PhoenixKitEcommerce.Options.update_global_options([
          %{
            "key" => "finish",
            "label" => "Finish",
            "type" => "select",
            "options" => ["Matt", "Gloss"],
            "affects_price" => true,
            "modifier_type" => "percent",
            "price_modifiers" => %{"Matt" => "0", "Gloss" => "20"}
          }
        ])

      vase = product!(%{"metadata" => %{"_option_values" => %{"finish" => ["Matt", "Gloss"]}}})

      assert {200, %{"results" => [%{"product" => %{"options" => [finish]}}]}, _} =
               call("shop.get_products", %{"ids" => [vase.uuid]})

      assert finish["affects_price"] == true

      for {value_key, quoted} <- [{"matt", "10.00"}, {"gloss", "12.00"}] do
        token = new_cart_token()

        line = %{
          "product_id" => vase.uuid,
          "quantity" => 1,
          "options" => [%{"attribute_key" => "finish", "value_key" => value_key}]
        }

        assert {200, %{"cart" => %{"lines" => [%{"unit_price" => charged}]}}, _} =
                 call("shop.set_cart_items", %{"cart_token" => token, "items" => [line]})

        card_price = Enum.find(finish["values"], &(&1["key"] == value_key))["price"]
        assert card_price == %{"amount" => quoted, "currency" => "USD"}
        assert charged == card_price
      end
    end
  end

  describe "every cart tool and a token the server did not issue" do
    test "is cart_not_found over HTTP, never a 500", %{p1: p1} do
      carts_before = Repo.aggregate(Cart, :count)
      real = new_cart_token()
      [random, mac] = String.split(real, ".")

      tampered =
        String.replace_prefix(
          real,
          String.first(real),
          if(String.first(real) == "A", do: "B", else: "A")
        )

      inputs = %{
        "shop.get_cart" => %{},
        "shop.set_cart_items" => %{"items" => items([{p1, 1}])},
        "shop.clear_cart" => %{},
        "shop.get_shipping_options" => %{"country" => "DE"},
        "shop.set_shipping" => %{"country" => "DE", "method_id" => Ecto.UUID.generate()},
        "shop.get_checkout_link" => %{}
      }

      for {tool, input} <- inputs,
          bad <- [
            "x",
            random,
            random <> ".",
            tampered,
            random <> "." <> String.duplicate("A", String.length(mac))
          ] do
        assert {404, %{"code" => "cart_not_found"}, conn} =
                 call(tool, Map.put(input, "cart_token", bad)),
               "#{tool} with #{inspect(bad)}"

        assert ["application/problem+json" <> _] = Plug.Conn.get_resp_header(conn, "content-type")
      end

      assert Repo.aggregate(Cart, :count) == carts_before
    end

    # The signature is checked before the language and currency are resolved, so a
    # forged token costs no lookups: its answer does not depend on them. With a
    # real token the same input is refused for its language (the control).
    test "is cart_not_found before the language or currency is looked at", %{p1: p1} do
      inputs = %{
        "shop.get_cart" => %{},
        "shop.set_cart_items" => %{"items" => items([{p1, 1}])},
        "shop.clear_cart" => %{},
        "shop.get_shipping_options" => %{"country" => "DE"},
        "shop.set_shipping" => %{"country" => "DE", "method_id" => Ecto.UUID.generate()},
        "shop.get_checkout_link" => %{}
      }

      real = new_cart_token()

      for {tool, input} <- inputs, controls <- [%{"language" => "xx"}, %{"currency" => "XYZ"}] do
        input = Map.merge(input, controls)

        assert {404, %{"code" => "cart_not_found"}, _} =
                 call(tool, Map.put(input, "cart_token", "forged")),
               "#{tool} #{inspect(controls)}"

        assert {422, %{"code" => "validation_failed"}, _} =
                 call(tool, Map.put(input, "cart_token", real)),
               "#{tool} #{inspect(controls)} control"
      end
    end

    test "guessing tokens from one address is rate limited" do
      put_setting!("api_public_ip_rate_per_min", 3)
      ip = unique_ip()

      statuses =
        for _ <- 1..5 do
          {status, _body, _conn} = call("shop.get_cart", %{"cart_token" => "guess"}, ip: ip)
          status
        end

      assert Enum.take(statuses, 3) == [404, 404, 404]
      assert 429 in statuses
    end

    test "an empty token is a validation error", _ctx do
      assert {422, %{"code" => "validation_failed"}, _} =
               call("shop.get_cart", %{"cart_token" => ""})

      assert {422, %{"code" => "validation_failed"}, _} = call("shop.get_cart", %{})
    end

    test "a swept cart is cart_not_found for reads and writes alike", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])
      {:ok, hash} = CartToken.verify(token)
      {:ok, cart} = CartStore.resolve(hash)
      cart |> Cart.status_changeset("abandoned") |> Repo.update!()

      assert {404, %{"code" => "cart_not_found"}, _} =
               call("shop.get_cart", %{"cart_token" => token})

      assert {404, %{"code" => "cart_not_found"}, _} = write(token, [{p1, 2}])
    end
  end

  describe "shop.set_cart_items" do
    test "writes final quantities and answers per line", %{p1: p1, p2: p2} do
      token = new_cart_token()

      assert {200, %{"results" => results, "summary" => %{"created" => 2}, "revision" => rev}, _} =
               write(token, [{p1, 1}, {p2, 3}])

      assert Enum.map(results, & &1["action"]) == ["created", "created"]

      assert {200, %{"summary" => %{"updated" => 1}, "revision" => rev2}, _} =
               write(token, [{p1, 4}])

      refute rev == rev2
    end

    test "a bad line is a row error inside a 200, a bad shape is a 422", %{p1: p1} do
      token = new_cart_token()

      assert {200,
              %{
                "results" => [
                  %{"error" => %{"code" => "quantity_invalid"}},
                  %{"action" => "created"}
                ]
              }, _} =
               call("shop.set_cart_items", %{
                 "cart_token" => token,
                 "items" => [
                   %{"product_id" => p1.uuid, "quantity" => "3"},
                   %{"product_id" => product!().uuid, "quantity" => 1}
                 ]
               })

      assert {200, %{"results" => [%{"error" => %{"code" => "quantity_invalid"}}]}, _} =
               call("shop.set_cart_items", %{
                 "cart_token" => token,
                 "items" => [%{"product_id" => p1.uuid}]
               })

      assert {422, %{"code" => "validation_failed"}, _} =
               call("shop.set_cart_items", %{
                 "cart_token" => token,
                 "items" => [%{"quantity" => 1}]
               })

      assert {422, %{"code" => "validation_failed"}, _} =
               call("shop.set_cart_items", %{"cart_token" => token, "items" => []})
    end

    test "51 lines are refused as a whole, 50 are accepted", %{p1: p1} do
      token = new_cart_token()
      lines = for _ <- 1..51, do: %{"product_id" => p1.uuid, "quantity" => 1}

      assert {422, %{"code" => "validation_failed"}, _} =
               call("shop.set_cart_items", %{"cart_token" => token, "items" => lines})

      assert {200, %{"summary" => summary}, _} =
               call("shop.set_cart_items", %{
                 "cart_token" => token,
                 "items" => Enum.take(lines, 50)
               })

      # fifty copies of one product are fifty duplicate lines: nothing is applied
      assert summary == %{"error" => 50}
    end

    test "a stale expected_revision is a 409 with the changes since", %{p1: p1, p2: p2} do
      token = new_cart_token()
      {200, %{"revision" => first}, _} = write(token, [{p1, 1}])
      {200, _, _} = write(token, [{p2, 1}])

      assert {409, %{"code" => "revision_mismatch", "context" => context}, _} =
               write(token, [{p1, 2}], %{"expected_revision" => first})

      assert [%{"product_id" => id}] = context["changes_since"]["added"]
      assert id == p2.uuid
    end

    test "a different currency override on an existing cart is refused", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      assert {422,
              %{"code" => "validation_failed", "context" => %{"reason" => "cart_currency_fixed"}},
              _} =
               write(token, [{p1, 2}], %{"currency" => "EUR"})
    end

    # Core's executor turns a handler answer other than {:preview, ...} to a dry run into a 500:
    # the path that would not have written a cart must preview as well.
    test "a dry run on a token without a cart previews, whether or not it would write", %{p1: p1} do
      token = new_cart_token()

      assert {200,
              %{
                "executed" => false,
                "dry_run" => true,
                "preview" => %{"results" => [%{"action" => "unchanged"}]}
              }, _} =
               call("shop.set_cart_items", %{
                 "cart_token" => token,
                 "dry_run" => true,
                 "items" => [%{"product_id" => p1.uuid, "quantity" => 0}]
               })

      assert {200,
              %{
                "executed" => false,
                "dry_run" => true,
                "preview" => %{"results" => [%{"action" => "created"}]}
              }, _} =
               call("shop.set_cart_items", %{
                 "cart_token" => token,
                 "dry_run" => true,
                 "items" => items([{p1, 1}])
               })

      assert {200, %{"lines" => []}, _} = call("shop.get_cart", %{"cart_token" => token})
    end

    test "the first write is limited per network", %{p1: p1} do
      put_setting!(new_rows_key(:per_ip_hour), 1)
      ip = unique_ip()

      first = new_cart_token()
      second = new_cart_token()

      assert {200, _, _} =
               call("shop.set_cart_items", %{"cart_token" => first, "items" => items([{p1, 1}])},
                 ip: ip
               )

      assert {429, %{"code" => "rate_limited"}, conn} =
               call("shop.set_cart_items", %{"cart_token" => second, "items" => items([{p1, 1}])},
                 ip: ip
               )

      assert [retry] = Plug.Conn.get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) > 0
    end

    test "the first write is limited globally, whatever the network", %{p1: p1} do
      put_setting!(new_rows_key(:global_hour), 1)
      first = new_cart_token()
      second = new_cart_token()

      # the global bucket is shared by the whole run: the first write may pass or be limited,
      # the second one (another address) is limited either way
      assert {status, _, _} =
               call("shop.set_cart_items", %{"cart_token" => first, "items" => items([{p1, 1}])})

      assert status in [200, 429]

      assert {429, %{"code" => "rate_limited"}, conn} =
               call("shop.set_cart_items", %{"cart_token" => second, "items" => items([{p1, 1}])})

      assert [retry] = Plug.Conn.get_resp_header(conn, "retry-after")
      assert String.to_integer(retry) > 0
    end
  end

  describe "language and currency controls" do
    test "an explicit language that is not enabled is refused with the allowed list" do
      token = new_cart_token()

      assert {422, %{"code" => "validation_failed", "context" => %{"errors" => [error]}}, _} =
               call("shop.get_cart", %{"cart_token" => token, "language" => "xx"})

      assert error["path"] == "language"
      assert is_list(error["allowed"])
    end

    test "an explicit currency is used for a new cart, in any letter case", %{p1: p1} do
      token = new_cart_token()

      assert {200, %{"cart" => %{"currency" => "EUR"}}, _} =
               write(token, [{p1, 1}], %{"currency" => "eur"})

      assert {200, %{"cart" => %{"currency" => "EUR"}}, _} =
               write(token, [{p1, 2}], %{"currency" => "EUR"})
    end

    test "a line price renders the way Context.money renders the same product in the same currency",
         %{p1: p1} do
      eur = Repo.get_by!(Currency, code: "EUR")
      eur |> Ecto.Changeset.change(rounding_rule: "charm_99") |> Repo.update!()
      PhoenixKit.Cache.clear(:billing_currencies)

      token = new_cart_token()

      assert {200, %{"cart" => %{"lines" => [line]}}, _} =
               write(token, [{p1, 1}], %{"currency" => "EUR"})

      {:ok, context} = Context.build(%{"currency" => "EUR"}, ctx())
      expected = Context.money(context, p1.price)

      # the rule really ran (a plain 0.909091 conversion would not end in .99), and both builders agree
      assert expected["amount"] =~ ~r/\.99\z/
      assert line["unit_price"] == expected
      assert line["line_total"] == expected
    end

    test "a currency that is not enabled is refused, before the cart is looked at" do
      token = new_cart_token()

      assert {422,
              %{
                "code" => "validation_failed",
                "context" => %{"errors" => [%{"path" => "currency"}]}
              }, _} =
               call("shop.get_cart", %{"cart_token" => token, "currency" => "XYZ"})
    end
  end

  describe "shop.clear_cart" do
    # Through the executor, which runs a dangerous call as a dry run first: every answer
    # the handler gives to that dry run must be a preview, or core answers 500.
    test "an unconfirmed call previews and changes nothing; the confirmation empties the cart", %{
      p1: p1,
      p2: p2
    } do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 2}, {p2, 1}])

      assert {200,
              %{
                "executed" => false,
                "status" => "confirmation_required",
                "confirm_token" => code,
                "preview" => %{"lines_removed" => 2}
              }, _} = call("shop.clear_cart", %{"cart_token" => token})

      assert {200, %{"lines" => [_, _]}, _} = call("shop.get_cart", %{"cart_token" => token})

      assert {200, %{"lines_removed" => 2, "cart" => %{"lines" => []}}, _} =
               call("shop.clear_cart", %{"cart_token" => token, "confirm_token" => code})

      assert {200, %{"lines" => []}, _} = call("shop.get_cart", %{"cart_token" => token})
    end

    # Nothing to destroy, nothing to confirm: an anonymous caller must not be able to mint a
    # stored confirmation code per call with a token that never wrote.
    test "a token that never wrote, or an emptied cart, is answered at once and mints no code", %{
      p1: p1
    } do
      codes = fn -> Repo.aggregate("phoenix_kit_api_confirmations", :count) end
      before = codes.()

      token = new_cart_token()

      assert {200, %{"lines_removed" => 0, "cart" => %{"lines" => []}}, _} =
               call("shop.clear_cart", %{"cart_token" => token})

      {200, _, _} = write(token, [{p1, 1}])
      {200, %{"confirm_token" => code}, _} = call("shop.clear_cart", %{"cart_token" => token})
      assert codes.() == before + 1

      assert {200, %{"lines_removed" => 1}, _} =
               call("shop.clear_cart", %{"cart_token" => token, "confirm_token" => code})

      assert {200, %{"lines_removed" => 0}, _} = call("shop.clear_cart", %{"cart_token" => token})
      assert codes.() == before + 1
    end

    test "a confirmation is bound to the cart it previewed", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      {200, %{"confirm_token" => code}, _} = call("shop.clear_cart", %{"cart_token" => token})
      {200, _, _} = write(token, [{p1, 2}])

      assert {409, %{"code" => "confirm_token_invalid"}, _} =
               call("shop.clear_cart", %{"cart_token" => token, "confirm_token" => code})

      assert {200, %{"lines" => [%{"quantity" => 2}]}, _} =
               call("shop.get_cart", %{"cart_token" => token})
    end

    test "the handler's preview shows what would go and clearing leaves an empty cart", %{
      p1: p1,
      p2: p2
    } do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 2}, {p2, 1}])
      ctx = ctx_for(token)

      assert {:preview, %{lines_removed: 2, cart: %{lines: [_, _]}}, fingerprint} =
               CartHandlers.clear_cart(%{"cart_token" => token}, %{ctx | dry_run?: true})

      assert is_binary(fingerprint)
      assert {200, %{"lines" => [_, _]}, _} = call("shop.get_cart", %{"cart_token" => token})

      assert {:ok, %{lines_removed: 2, cart: %{lines: []}}} =
               CartHandlers.clear_cart(%{"cart_token" => token}, ctx)

      assert {200, %{"lines" => []}, _} = call("shop.get_cart", %{"cart_token" => token})
    end

    # A token that never wrote is cleared at once when asked in the ordinary way,
    # but a caller may ask for a dry run all the same; core answers 500 to a dry
    # run whose handler does not preview.
    test "a dry run on a token without a cart previews an empty cart, not a 500", _ctx do
      token = new_cart_token()

      assert {:preview, %{lines_removed: 0, cart: %{lines: []}, would_be: %{lines: []}},
              fingerprint} =
               CartHandlers.clear_cart(%{"cart_token" => token}, %{
                 ctx_for(token)
                 | dry_run?: true
               })

      assert fingerprint == CartView.revision(nil)

      assert {200,
              %{
                "executed" => false,
                "dry_run" => true,
                "preview" => %{"lines_removed" => 0, "cart" => %{"lines" => []}}
              }, _} = call("shop.clear_cart", %{"cart_token" => token, "dry_run" => true})
    end

    test "clearing a token without a cart is a no-op", _ctx do
      token = new_cart_token()

      assert {:ok, %{lines_removed: 0, cart: %{lines: []}}} =
               CartHandlers.clear_cart(%{"cart_token" => token}, ctx_for(token))
    end
  end

  describe "shipping" do
    test "options list every active method with availability and the reason", %{
      physical: physical
    } do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      open = method!(%{"name" => "Open", "countries" => ["DE"]})
      closed = method!(%{"name" => "Closed", "countries" => ["FR"]})

      assert {200, %{"country" => "DE", "methods" => methods}, _} =
               call("shop.get_shipping_options", %{"cart_token" => token, "country" => "de"})

      by_id = Map.new(methods, &{&1["id"], &1})
      assert by_id[open.uuid]["available"] == true and by_id[open.uuid]["reason"] == nil
      assert by_id[closed.uuid]["available"] == false
      assert by_id[closed.uuid]["reason"] == "country_not_served"
      assert by_id[open.uuid]["price"] == %{"amount" => "4.00", "currency" => "USD"}
    end

    test "a method below the order minimum says so", %{physical: physical} do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      small = method!(%{"min_order_amount" => Decimal.new("500.00")})

      assert {200, %{"methods" => methods}, _} =
               call("shop.get_shipping_options", %{"cart_token" => token, "country" => "DE"})

      assert Enum.find(methods, &(&1["id"] == small.uuid))["reason"] == "order_below_minimum"
    end

    test "options for a token without a cart are computed for an empty cart" do
      token = new_cart_token()
      method!()

      assert {200, %{"methods" => [_ | _]}, _} =
               call("shop.get_shipping_options", %{"cart_token" => token, "country" => "DE"})
    end

    test "country must be a known two-letter code", %{physical: physical} do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])

      for bad <- ["Germany", "", "D", "D1", "XX"] do
        assert {422, %{"code" => "validation_failed"}, _} =
                 call("shop.get_shipping_options", %{"cart_token" => token, "country" => bad}),
               inspect(bad)
      end

      assert {200, _, _} =
               call("shop.get_shipping_options", %{"cart_token" => token, "country" => "DE"})

      assert {200, _, _} =
               call("shop.get_shipping_options", %{"cart_token" => token, "country" => "de"})
    end

    test "set_shipping chooses an available method and changes the revision", %{
      physical: physical
    } do
      token = new_cart_token()
      {200, %{"revision" => before_revision}, _} = write(token, [{physical, 1}])
      method = method!(%{"countries" => ["DE"]})

      assert {200,
              %{
                "shipping" => %{"country" => "DE", "method" => %{"id" => id}},
                "revision" => after_revision
              }, _} =
               call("shop.set_shipping", %{
                 "cart_token" => token,
                 "country" => "DE",
                 "method_id" => method.uuid
               })

      assert id == method.uuid
      refute before_revision == after_revision
    end

    test "set_shipping refuses a method that does not serve the country, an unknown method and an empty cart",
         %{
           physical: physical
         } do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      french = method!(%{"countries" => ["FR"]})

      assert {422,
              %{
                "code" => "validation_failed",
                "context" => %{"errors" => [%{"path" => "method_id"}]}
              }, _} =
               call("shop.set_shipping", %{
                 "cart_token" => token,
                 "country" => "DE",
                 "method_id" => french.uuid
               })

      assert {422, %{"code" => "validation_failed"}, _} =
               call("shop.set_shipping", %{
                 "cart_token" => token,
                 "country" => "DE",
                 "method_id" => Ecto.UUID.generate()
               })

      assert {422, %{"code" => "validation_failed"}, _} =
               call("shop.set_shipping", %{
                 "cart_token" => token,
                 "country" => "DE",
                 "method_id" => "not-a-uuid"
               })

      empty = new_cart_token()

      assert {422, %{"code" => "validation_failed", "context" => %{"reason" => "cart_empty"}}, _} =
               call("shop.set_shipping", %{
                 "cart_token" => empty,
                 "country" => "DE",
                 "method_id" => french.uuid
               })
    end
  end

  describe "shipping dry runs and revision snapshots" do
    defp shipping_input(token, method),
      do: %{"cart_token" => token, "country" => "DE", "method_id" => method.uuid}

    test "a dry run of set_shipping previews the choice and leaves the cart as it was", %{
      physical: physical
    } do
      token = new_cart_token()
      {200, %{"revision" => revision}, _} = write(token, [{physical, 1}])
      method = method!(%{"countries" => ["DE"]})
      {:ok, hash} = CartToken.verify(token)
      {:ok, before} = CartStore.resolve(hash)

      assert {:preview, %{method: method_id, country: "DE", cart: %{lines: [_]}}, fingerprint} =
               CartHandlers.set_shipping(shipping_input(token, method), %{
                 ctx_for(token)
                 | dry_run?: true
               })

      assert method_id == method.uuid
      assert fingerprint == revision

      assert {200,
              %{
                "executed" => false,
                "dry_run" => true,
                "preview" => %{"method" => ^method_id, "country" => "DE"}
              }, _} =
               call("shop.set_shipping", Map.put(shipping_input(token, method), "dry_run", true))

      {:ok, after_dry_runs} = CartStore.resolve(hash)

      for field <- [:shipping_method_uuid, :shipping_country, :shipping_amount, :total] do
        assert Map.fetch!(after_dry_runs, field) == Map.fetch!(before, field), inspect(field)
      end

      assert is_nil(after_dry_runs.shipping_method_uuid)

      assert {200, %{"revision" => ^revision}, _} =
               call("shop.get_cart", %{"cart_token" => token})
    end

    # The revision a tool answers with must be one `expected_revision` can be
    # sent back with: the writer remembers the cart it leaves, and so must the
    # other writing tools, or the agent gets the whole cart instead of what
    # changed.
    test "the revision set_shipping answers with is remembered for changes_since", %{
      physical: physical,
      p1: p1
    } do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      method = method!(%{"countries" => ["DE"]})

      {200, %{"revision" => chosen}, _} =
        call("shop.set_shipping", shipping_input(token, method))

      {200, _, _} = write(token, [{physical, 1}, {p1, 1}])

      assert {409, %{"code" => "revision_mismatch", "context" => context}, _} =
               write(token, [{p1, 2}], %{"expected_revision" => chosen})

      assert [%{"product_id" => id}] = context["changes_since"]["added"]
      assert id == p1.uuid
      refute Map.has_key?(context, "cart")
    end

    test "the revision a confirmed clear_cart leaves is remembered for changes_since", %{
      physical: physical,
      p1: p1
    } do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      method = method!(%{"countries" => ["DE"]})
      {200, _, _} = call("shop.set_shipping", shipping_input(token, method))

      {200, %{"confirm_token" => code}, _} = call("shop.clear_cart", %{"cart_token" => token})

      {200, %{"lines_removed" => 1, "cart" => %{"revision" => cleared}}, _} =
        call("shop.clear_cart", %{"cart_token" => token, "confirm_token" => code})

      # The cleared cart keeps its shipping choice, so its revision is not the
      # empty cart's: only a stored snapshot can answer for it.
      refute cleared == CartView.revision(nil)

      {200, _, _} = write(token, [{p1, 1}])

      assert {409, %{"code" => "revision_mismatch", "context" => context}, _} =
               write(token, [{p1, 2}], %{"expected_revision" => cleared})

      assert [%{"product_id" => id}] = context["changes_since"]["added"]
      assert id == p1.uuid
      refute Map.has_key?(context, "cart")
    end
  end

  describe "shop.get_checkout_link" do
    test "a line whose product left the shop does not stop the link", %{p1: p1, p2: p2} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}, {p2, 1}])
      {:ok, _} = Shop.update_product(p1, %{"status" => "archived"})

      assert {200, %{"lines" => lines}, _} = call("shop.get_cart", %{"cart_token" => token})
      assert Enum.sort(Enum.map(lines, & &1["status"])) == ["ok", "unavailable"]

      assert {200, %{"url" => url}, _} = call("shop.get_checkout_link", %{"cart_token" => token})
      assert {:ok, %{cart: cart}} = url |> String.split("/") |> List.last() |> Claims.peek()
      assert length(cart.items) == 2
    end

    test "issues a one-time claim URL for a cart with lines", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      assert {200, %{"url" => url, "expires_at" => expires_at, "expires_in_seconds" => seconds},
              _} =
               call("shop.get_checkout_link", %{"cart_token" => token})

      assert url =~ ~r|\Ahttps?://[^/]+/checkout/claim/[A-Za-z0-9_-]{43}\z|
      assert {:ok, _, _} = DateTime.from_iso8601(expires_at)
      assert seconds in 1790..1800

      raw = url |> String.split("/") |> List.last()
      assert {:ok, %{cart: cart}} = Claims.peek(raw)
      assert cart.session_id == "api:" <> CartToken.digest(token)
    end

    test "the cart can still be changed until the buyer confirms the link, and a second link replaces the first",
         %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])
      {200, %{"url" => first}, _} = call("shop.get_checkout_link", %{"cart_token" => token})
      assert {200, _, _} = write(token, [{p1, 2}])
      {200, %{"url" => second}, _} = call("shop.get_checkout_link", %{"cart_token" => token})

      assert {:error, :superseded} = Claims.peek(List.last(String.split(first, "/")))
      assert {:ok, _} = Claims.peek(List.last(String.split(second, "/")))
    end

    # The link carries a credential: when a request-context hook names the
    # domains, it must point at a host the install serves, whatever Host header
    # the request came with.
    test "the link goes to a host the install serves, never the one the request named", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      link = fn overrides ->
        CartHandlers.get_checkout_link(%{"cart_token" => token}, ctx_for(token, overrides))
      end

      assert {:ok, %{url: "https://shop.test/checkout/claim/" <> _}} = link.(%{})

      assert {:ok, %{url: "https://SHOP.test/checkout/claim/" <> _}} =
               link.(%{base_url: "https://SHOP.test"})

      assert {:ok, %{url: "https://shop.test/checkout/claim/" <> _}} =
               link.(%{base_url: "https://evil.example"})

      assert {:ok, %{url: "http://shop.test/checkout/claim/" <> _}} =
               link.(%{base_url: "http://evil.example:8080"})

      assert {:ok, %{url: "https://shop.test/checkout/claim/" <> _}} =
               link.(%{base_url: "evil.example"})

      assert {:ok, %{url: "https://second.test/checkout/claim/" <> _}} =
               link.(%{base_url: "https://evil.example", hosts: ["second.test", "shop.test"]})

      assert {:ok, %{url: "https://shop.test:8443/checkout/claim/" <> _}} =
               link.(%{base_url: "https://shop.test:8443"})
    end

    test "a call that names no host is refused before any claim exists", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      for hosts <- [[], nil] do
        assert {:error, :internal_error, _message, %{}} =
                 CartHandlers.get_checkout_link(
                   %{"cart_token" => token},
                   ctx_for(token, %{hosts: hosts, base_url: "https://evil.example"})
                 )
      end

      assert Repo.aggregate(CartClaim, :count) == 0
    end

    test "a host that differs only in case from a served one is served, port kept", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      assert {:ok, %{url: "https://shop.test:8443/checkout/claim/" <> _}} =
               CartHandlers.get_checkout_link(
                 %{"cart_token" => token},
                 ctx_for(token, %{hosts: ["Shop.TEST"], base_url: "https://shop.test:8443"})
               )
    end

    test "a dry run refuses where the real call does: no host to use", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      for hosts <- [[], nil], dry_run? <- [true, false] do
        overrides = %{hosts: hosts, base_url: "https://evil.example", dry_run?: dry_run?}

        assert {:error, :internal_error, _message, %{}} =
                 CartHandlers.get_checkout_link(
                   %{"cart_token" => token},
                   ctx_for(token, overrides)
                 )
      end

      assert Repo.aggregate(CartClaim, :count) == 0

      assert {:preview, %{would_issue_link: true}, _fingerprint} =
               CartHandlers.get_checkout_link(
                 %{"cart_token" => token},
                 ctx_for(token, %{dry_run?: true})
               )
    end

    test "through the executor, a host hook that pins the domain wins over the Host header", %{
      p1: p1
    } do
      Application.put_env(
        :phoenix_kit,
        :api_request_context,
        {PhoenixKitEcommerce.CartApiFixtures, :pinned_hosts}
      )

      on_exit(fn -> Application.delete_env(:phoenix_kit, :api_request_context) end)

      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      assert {200, %{"url" => url}, _} = call("shop.get_checkout_link", %{"cart_token" => token})
      assert url =~ ~r|\Ahttps?://shop\.test/checkout/claim/|
    end

    # Pins the documented default: core fills `hosts` with the request host, so
    # without a hook the link follows the Host header of the request.
    test "without a request-context hook the link goes to the host the request named", %{p1: p1} do
      Application.delete_env(:phoenix_kit, :api_request_context)

      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      assert {200, %{"url" => url}, _} =
               call("shop.get_checkout_link", %{"cart_token" => token}, host: "asked-for.test")

      assert url =~ ~r|\Ahttps?://asked-for\.test/checkout/claim/|
    end

    test "an empty cart, or none, has nothing to hand over", _ctx do
      token = new_cart_token()

      assert {422, %{"code" => "validation_failed", "context" => %{"reason" => "cart_empty"}}, _} =
               call("shop.get_checkout_link", %{"cart_token" => token})
    end

    test "a dry run issues nothing", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      assert {:preview, _preview, _fingerprint} =
               CartHandlers.get_checkout_link(%{"cart_token" => token}, %{
                 ctx_for(token)
                 | dry_run?: true
               })

      assert Repo.aggregate(CartClaim, :count) == 0
    end

    # The idempotency layer inspects the encoded body. These tests prove that it catches the
    # two credential-bearing answers of this API, and a control proves the same key DOES
    # store an ordinary write, so "nothing stored" can fail.
    test "the detector recognises both credential-bearing answers of this API", %{p1: p1} do
      token = new_cart_token()
      {200, created, _} = call("shop.create_cart", %{})
      {200, _, _} = write(token, [{p1, 1}])
      {200, link, _} = call("shop.get_checkout_link", %{"cart_token" => token})
      {200, ordinary, _} = write(token, [{p1, 2}])

      for credential <- [created, link] do
        body = Jason.encode!(credential)
        assert Idempotency.credential_bearing?(body), body
        refute Idempotency.storable?(body), body
      end

      assert Idempotency.storable?(Jason.encode!(ordinary))
    end

    test "the response is never stored for replay (it carries a credential), an ordinary write's is",
         %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])
      link_headers = [{"idempotency-key", "check-out-link-0123456789"}]

      {200, %{"url" => url}, _} =
        call("shop.get_checkout_link", %{"cart_token" => token}, headers: link_headers)

      raw = url |> String.split("/") |> List.last()

      refute Enum.any?(stored_responses(), &(&1 =~ raw))

      # not replayed either: the second call with the same key is a new link, not the first one
      {200, %{"url" => again}, conn} =
        call("shop.get_checkout_link", %{"cart_token" => token}, headers: link_headers)

      refute again == url
      assert Plug.Conn.get_resp_header(conn, "idempotent-replayed") == []

      # positive control: the same layer stores and replays an ordinary write under its key
      write_headers = [{"idempotency-key", "control-write-0123456789"}]
      input = %{"cart_token" => token, "items" => items([{p1, 3}])}

      {200, first, _} = call("shop.set_cart_items", input, headers: write_headers)
      assert Enum.any?(stored_responses(), &(&1 =~ "\"results\""))

      {200, replayed, conn} = call("shop.set_cart_items", input, headers: write_headers)
      assert Plug.Conn.get_resp_header(conn, "idempotent-replayed") == ["true"]
      assert replayed["revision"] == first["revision"]
    end

    test "create_cart has no cart token, so an idempotency key changes nothing for it" do
      headers = [{"idempotency-key", "create-cart-0123456789"}]

      {200, %{"cart_token" => first}, _} = call("shop.create_cart", %{}, headers: headers)
      {200, %{"cart_token" => second}, _} = call("shop.create_cart", %{}, headers: headers)

      refute first == second
    end

    @tag :core_replay
    test "create_cart offers no idempotency_key, so one in the body is refused (core with :replay)" do
      assert CartTools.replay_available?()
      key = "create-cart-0123456789"

      assert {422, %{"code" => "validation_failed"}, _} =
               call("shop.create_cart", %{"idempotency_key" => key})
    end

    @tag :core_replay
    test "get_checkout_link offers no idempotency_key either (core with :replay)", %{p1: p1} do
      assert CartTools.replay_available?()
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])

      assert {422, %{"code" => "validation_failed"}, _} =
               call("shop.get_checkout_link", %{
                 "cart_token" => token,
                 "idempotency_key" => "checkout-link-0123456789"
               })
    end

    defp stored_responses do
      %{rows: rows} = Repo.query!("SELECT response::text FROM phoenix_kit_api_idempotency")
      for [response] <- rows, is_binary(response), do: response
    end
  end

  describe "shop.get_checkout_link with a site_url setting" do
    setup %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])
      put_setting!("site_url", "https://Canonical.test:8443/")
      %{token: token}
    end

    defp link(token, overrides),
      do: CartHandlers.get_checkout_link(%{"cart_token" => token}, ctx_for(token, overrides))

    test "the install's own host is served even when the hosts do not name it", %{token: token} do
      assert {:ok, %{url: "https://canonical.test:8443/checkout/claim/" <> _}} =
               link(token, %{base_url: "https://canonical.test:8443"})
    end

    test "a host the request made up is not served when the hosts name the domains", %{
      token: token
    } do
      assert {:ok, %{url: "https://shop.test/checkout/claim/" <> _}} =
               link(token, %{base_url: "https://evil.example"})
    end

    test "a call with no hosts links to the install's own address, a dry run too", %{
      token: token
    } do
      for hosts <- [[], nil] do
        assert {:ok, %{url: "https://canonical.test:8443/checkout/claim/" <> _}} =
                 link(token, %{hosts: hosts, base_url: "https://evil.example"})

        assert {:preview, %{would_issue_link: true}, _fingerprint} =
                 link(token, %{hosts: hosts, base_url: "https://evil.example", dry_run?: true})
      end
    end

    test "a setting that is not an http(s) address names no host", %{token: token} do
      for site_url <- ["canonical.test", "ftp://canonical.test", "https://", "   "] do
        put_setting!("site_url", site_url)

        assert {:error, :internal_error, _message, %{}} =
                 link(token, %{hosts: [], base_url: "https://canonical.test"}),
               site_url
      end
    end
  end

  describe "claimed carts" do
    test "reads say checking_out and writes say cart_locked once the claim is used", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])
      {200, %{"url" => url}, _} = call("shop.get_checkout_link", %{"cart_token" => token})
      raw = url |> String.split("/") |> List.last()

      assert {:ok, %{mode: :moved}} =
               redeem_shown(
                 raw,
                 %{session_id: "browser-#{System.unique_integer([:positive])}", user_uuid: nil},
                 %{
                   offer: "none"
                 }
               )

      assert {200, %{"status" => "checking_out", "lines" => []}, _} =
               call("shop.get_cart", %{"cart_token" => token})

      assert {409, %{"code" => "cart_locked"}, _} = write(token, [{p1, 2}])

      assert {409, %{"code" => "cart_locked"}, _} =
               call("shop.get_checkout_link", %{"cart_token" => token})

      assert {409, %{"code" => "cart_locked"}, _} =
               call("shop.clear_cart", %{"cart_token" => token})
    end

    # Deliberate: get_cart is the one read that answers a claimed cart with
    # `checking_out`; the other read, the shipping options, refuses it like a write.
    test "get_cart says checking_out while get_shipping_options says cart_locked", %{
      physical: physical
    } do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      {200, %{"url" => url}, _} = call("shop.get_checkout_link", %{"cart_token" => token})
      raw = url |> String.split("/") |> List.last()

      assert {:ok, %{mode: :moved}} =
               redeem_shown(
                 raw,
                 %{session_id: "browser-#{System.unique_integer([:positive])}"},
                 %{
                   offer: "none"
                 }
               )

      assert {200, %{"status" => "checking_out"}, _} =
               call("shop.get_cart", %{"cart_token" => token})

      assert {409, %{"code" => "cart_locked"}, _} =
               call("shop.get_shipping_options", %{"cart_token" => token, "country" => "DE"})
    end

    # The three hand-off paths (moved, replaced, merged) all lock the old token. "none" is the
    # moved path above; here the browser already has a cart, so the buyer replaces it or adds to it.
    for choice <- ["replace", "add"] do
      test "the old token is locked after a #{choice} as well, through every tool", %{
        p1: p1,
        p2: p2,
        physical: physical
      } do
        token = new_cart_token()
        {200, _, _} = write(token, [{p1, 1}])
        {200, %{"url" => url}, _} = call("shop.get_checkout_link", %{"cart_token" => token})
        raw = url |> String.split("/") |> List.last()

        session = "browser-#{System.unique_integer([:positive])}"
        {:ok, mine} = Shop.create_cart(session_id: session)
        {:ok, _} = Shop.add_to_cart(mine, p2, 1)

        assert {:ok, %{mode: mode}} =
                 redeem_shown(raw, %{session_id: session, user_uuid: nil}, %{
                   offer: mine.uuid,
                   choice: unquote(choice)
                 })

        assert mode in [:replaced, :merged]

        assert {200, %{"status" => "checking_out", "lines" => []}, _} =
                 call("shop.get_cart", %{"cart_token" => token})

        assert {409, %{"code" => "cart_locked"}, _} = write(token, [{p1, 2}])
        assert {409, %{"code" => "cart_locked"}, _} = write(token, [{physical, 0}])

        assert {409, %{"code" => "cart_locked"}, _} =
                 call("shop.get_checkout_link", %{"cart_token" => token})

        assert {409, %{"code" => "cart_locked"}, _} =
                 call("shop.clear_cart", %{"cart_token" => token})

        assert {409, %{"code" => "cart_locked"}, _} =
                 call("shop.set_shipping", %{
                   "cart_token" => token,
                   "country" => "DE",
                   "method_id" => Ecto.UUID.generate()
                 })
      end
    end
  end

  describe "a cart that changes hands while a write waits for its row" do
    # The cart is read as an active api cart; then, before the write takes its row
    # lock, it is handed to a buyer or swept. A benign race: the tool answers as
    # it would on any later call with that token, never a 500.
    setup %{physical: physical} do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      %{token: token, method: method!(%{"countries" => ["DE"]})}
    end

    defp change_hands_after_first_cart_read(token, how) do
      session = "api:" <> CartToken.digest(token)

      after_first_query("SELECT", "phoenix_kit_shop_carts", fn ->
        cart = Repo.get_by!(Cart, session_id: session)
        query = from(c in Cart, where: c.uuid == ^cart.uuid)

        case how do
          :handed_over ->
            Repo.update_all(query, set: [session_id: "browser-x"])
            used_claim!(cart, token)

          :swept ->
            Repo.update_all(query, set: [status: "abandoned"])
        end
      end)
    end

    defp used_claim!(cart, token) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      %CartClaim{}
      |> CartClaim.changeset(%{
        token_hash: "th-#{System.unique_integer([:positive])}",
        cart_uuid: cart.uuid,
        cart_token_hash: CartToken.digest(token),
        language: "en",
        expires_at: DateTime.add(now, 600, :second),
        used_at: now
      })
      |> Repo.insert!()
    end

    defp run_tool(:get_checkout_link, token, _method),
      do: CartHandlers.get_checkout_link(%{"cart_token" => token}, ctx_for(token))

    defp run_tool(:clear_cart, token, _method),
      do: CartHandlers.clear_cart(%{"cart_token" => token}, ctx_for(token))

    defp run_tool(:set_shipping, token, method) do
      input = %{"cart_token" => token, "country" => "DE", "method_id" => method.uuid}
      CartHandlers.set_shipping(input, ctx_for(token))
    end

    for tool <- [:get_checkout_link, :clear_cart, :set_shipping] do
      test "#{tool}: a cart handed over meanwhile is cart_locked", %{token: token, method: method} do
        change_hands_after_first_cart_read(token, :handed_over)

        assert {:error, :cart_locked, _message, %{}} = run_tool(unquote(tool), token, method)
      end

      test "#{tool}: a cart swept meanwhile is cart_not_found", %{token: token, method: method} do
        change_hands_after_first_cart_read(token, :swept)

        assert {:error, :cart_not_found, _message, %{}} = run_tool(unquote(tool), token, method)
      end
    end

    test "a link that lost the race issues no claim", %{token: token, method: method} do
      change_hands_after_first_cart_read(token, :swept)
      {:error, :cart_not_found, _, _} = run_tool(:get_checkout_link, token, method)

      assert Repo.aggregate(CartClaim, :count) == 0
    end
  end

  describe "set_shipping on a cart that is emptied, or that changes while the call waits" do
    test "a cart that was emptied (the row stays, with no lines) is cart_empty, not a shipping choice",
         %{physical: physical} do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      {200, _, _} = write(token, [{physical, 0}])
      {:ok, hash} = CartToken.verify(token)
      assert {:ok, %Cart{items: []}} = CartStore.resolve(hash)
      method = method!(%{"countries" => ["DE"]})

      assert {422, %{"code" => "validation_failed", "context" => %{"reason" => "cart_empty"}}, _} =
               call("shop.set_shipping", shipping_input(token, method))

      assert {:ok, %Cart{shipping_method_uuid: nil}} = CartStore.resolve(hash)
    end

    test "a method that stopped being available while the call waited for the row is refused, and not stored",
         %{physical: physical} do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      session = "api:" <> CartToken.digest(token)
      {:ok, hash} = CartToken.verify(token)
      {:ok, cart} = CartStore.resolve(hash)

      # Served while the cart holds at least its subtotal; the cart is emptied of
      # value after the call has read it and before it locks the row.
      method =
        method!(%{"countries" => ["DE"], "min_order_amount" => Decimal.add(cart.subtotal, 0)})

      after_first_query("SELECT", "phoenix_kit_shop_carts", fn ->
        from(c in Cart, where: c.session_id == ^session)
        |> Repo.update_all(set: [subtotal: Decimal.new("0.00")])
      end)

      assert {422,
              %{
                "code" => "validation_failed",
                "context" => %{"reason" => "method_unavailable"}
              }, _} = call("shop.set_shipping", shipping_input(token, method))

      assert Repo.get_by!(Cart, session_id: session).shipping_method_uuid == nil
    end
  end

  describe "a write that fails unexpectedly" do
    import ExUnit.CaptureLog

    # The cart is read (1), locked by the handler (2) and locked again by the
    # shop's own clear_cart (3). The cart stops being active after the second
    # read, so the third refuses it: a failure the handler did not plan for.
    defp deactivate_after_the_handler_locked_the_cart(token) do
      session = "api:" <> CartToken.digest(token)
      id = {:deactivate, make_ref()}
      reads = :counters.new(1, [])

      :telemetry.attach(
        id,
        [:phoenix_kit_ecommerce, :test, :repo, :query],
        fn _event, _measurements, meta, _config ->
          if meta.source == "phoenix_kit_shop_carts" and String.starts_with?(meta.query, "SELECT"),
            do: deactivate_on_second_read(reads, session)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(id) end)
    end

    defp deactivate_on_second_read(reads, session) do
      :counters.add(reads, 1, 1)

      if :counters.get(reads, 1) == 2 do
        Repo.update_all(from(c in Cart, where: c.session_id == ^session),
          set: [status: "abandoned"]
        )
      end
    end

    test "clear_cart answers internal_error and logs the shape of the failure, not its content",
         %{physical: physical} do
      token = new_cart_token()
      {200, _, _} = write(token, [{physical, 1}])
      deactivate_after_the_handler_locked_the_cart(token)

      log =
        capture_log(fn ->
          assert {:error, :internal_error, "The cart could not be updated.", %{}} =
                   run_tool(:clear_cart, token, nil)
        end)

      assert log =~ "[Shop] cart write failed: :cart_not_active"
      refute log =~ token
    end
  end

  describe "every result conforms to its tool's declared output schema" do
    # An MCP client may validate structuredContent against outputSchema: a null where the schema
    # says string would be rejected client-side (the answers are kept free of nil).
    test "success answers of all seven tools validate", %{p1: p1, physical: physical} do
      tools = Map.new(CartTools.tools(), &{&1.name, &1})
      method = method!(%{"countries" => ["DE"]})

      {200, created, _} = call("shop.create_cart", %{})
      token = created["cart_token"]
      {200, empty, _} = call("shop.get_cart", %{"cart_token" => token})
      {200, written, _} = write(token, [{p1, 1}, {physical, 1}])

      {200, options, _} =
        call("shop.get_shipping_options", %{"cart_token" => token, "country" => "DE"})

      {200, shipped, _} =
        call("shop.set_shipping", %{
          "cart_token" => token,
          "country" => "DE",
          "method_id" => method.uuid
        })

      {200, link, _} = call("shop.get_checkout_link", %{"cart_token" => token})
      {200, %{"confirm_token" => code}, _} = call("shop.clear_cart", %{"cart_token" => token})

      {200, cleared, _} =
        call("shop.clear_cart", %{"cart_token" => token, "confirm_token" => code})

      answers = [
        {"shop.create_cart", created},
        {"shop.get_cart", empty},
        {"shop.set_cart_items", written},
        {"shop.get_shipping_options", options},
        {"shop.set_shipping", shipped},
        {"shop.get_checkout_link", link},
        {"shop.clear_cart", cleared}
      ]

      for {name, answer} <- answers do
        assert {:ok, _} = Validator.validate(tools[name].output_schema, answer), name
      end
    end

    test "a claimed cart's answer validates too", %{p1: p1} do
      token = new_cart_token()
      {200, _, _} = write(token, [{p1, 1}])
      {200, %{"url" => url}, _} = call("shop.get_checkout_link", %{"cart_token" => token})
      raw = url |> String.split("/") |> List.last()

      {:ok, _} =
        redeem_shown(
          raw,
          %{session_id: "browser-#{System.unique_integer([:positive])}", user_uuid: nil},
          %{offer: "none"}
        )

      {200, locked, _} = call("shop.get_cart", %{"cart_token" => token})
      cart_tool = Enum.find(CartTools.tools(), &(&1.name == "shop.get_cart"))

      refute Map.has_key?(locked, "revision")
      assert {:ok, _} = Validator.validate(cart_tool.output_schema, locked)
    end
  end

  # Every tool through both transports. REST is above; this is MCP (`POST /mcp/public`).
  # Excluded when the core in use has no MCP plug.
  describe "through MCP" do
    @describetag :mcp

    defp rpc_result({200, %{"result" => result}, _conn}), do: result

    defp mcp_ok(name, arguments, opts \\ []) do
      result = name |> call_mcp(arguments, opts) |> rpc_result()
      assert result["isError"] == false, "#{name}: #{inspect(result)}"
      assert is_map(result["structuredContent"]), "#{name} has no structuredContent"
      result["structuredContent"]
    end

    # An error is a tool result (HTTP 200, isError), with the code in the text and no structuredContent.
    defp mcp_error(name, arguments, code) do
      result = name |> call_mcp(arguments) |> rpc_result()
      assert result["isError"] == true, "#{name}: #{inspect(result)}"
      refute Map.has_key?(result, "structuredContent")
      assert [%{"text" => text} | _] = result["content"]
      assert text =~ "[#{code}]", text
    end

    defp mcp_token, do: mcp_ok("shop_create_cart", %{})["cart_token"]

    test "tools/list offers the seven cart tools, with underscored names" do
      assert {200, %{"result" => %{"tools" => tools}}, _} = mcp_request("tools/list", nil)

      names = Enum.map(tools, & &1["name"])

      for name <- ~w(shop_create_cart shop_get_cart shop_set_cart_items shop_clear_cart
                     shop_get_shipping_options shop_set_shipping shop_get_checkout_link) do
        assert name in names, "#{name} is not listed"
      end

      refute Enum.any?(names, &String.contains?(&1, "."))
    end

    test "shop_create_cart and shop_get_cart: a success each, and an error" do
      token = mcp_token()
      assert is_binary(token)

      assert %{"status" => "open", "lines" => []} =
               mcp_ok("shop_get_cart", %{"cart_token" => token})

      mcp_error("shop_get_cart", %{"cart_token" => "not-a-token"}, "cart_not_found")
    end

    test "shop_set_cart_items: a success, a per-line error inside a success, and a refused request",
         %{p1: p1} do
      token = mcp_token()
      line = %{"product_id" => p1.uuid, "quantity" => 2}

      assert %{"summary" => %{"created" => 1}, "revision" => revision} =
               mcp_ok("shop_set_cart_items", %{"cart_token" => token, "items" => [line]})

      assert %{"results" => [%{"action" => "error", "error" => %{"code" => "quantity_invalid"}}]} =
               mcp_ok("shop_set_cart_items", %{
                 "cart_token" => token,
                 "items" => [%{"product_id" => p1.uuid, "quantity" => "3"}]
               })

      mcp_error(
        "shop_set_cart_items",
        %{"cart_token" => token, "items" => []},
        "validation_failed"
      )

      mcp_error(
        "shop_set_cart_items",
        %{"cart_token" => token, "items" => [line], "expected_revision" => "0000000000000000"},
        "revision_mismatch"
      )

      assert is_binary(revision)
    end

    test "shop_clear_cart: the danger flow works through MCP", %{p1: p1} do
      token = mcp_token()

      mcp_ok("shop_set_cart_items", %{
        "cart_token" => token,
        "items" => [%{"product_id" => p1.uuid, "quantity" => 1}]
      })

      assert %{"executed" => false, "status" => "confirmation_required", "confirm_token" => code} =
               mcp_ok("shop_clear_cart", %{"cart_token" => token})

      assert %{"lines" => [_]} = mcp_ok("shop_get_cart", %{"cart_token" => token})

      assert %{"lines_removed" => 1} =
               mcp_ok("shop_clear_cart", %{"cart_token" => token, "confirm_token" => code})

      mcp_error("shop_clear_cart", %{"cart_token" => "nope"}, "cart_not_found")
    end

    test "shop_get_shipping_options and shop_set_shipping: a success each, and an error each", %{
      physical: physical
    } do
      token = mcp_token()

      mcp_ok("shop_set_cart_items", %{
        "cart_token" => token,
        "items" => [%{"product_id" => physical.uuid, "quantity" => 1}]
      })

      method = method!(%{"countries" => ["DE"]})

      assert %{"country" => "DE", "methods" => [_ | _]} =
               mcp_ok("shop_get_shipping_options", %{"cart_token" => token, "country" => "DE"})

      mcp_error(
        "shop_get_shipping_options",
        %{"cart_token" => token, "country" => "Germany"},
        "validation_failed"
      )

      assert %{"shipping" => %{"country" => "DE"}} =
               mcp_ok("shop_set_shipping", %{
                 "cart_token" => token,
                 "country" => "DE",
                 "method_id" => method.uuid
               })

      mcp_error(
        "shop_set_shipping",
        %{"cart_token" => token, "country" => "DE", "method_id" => Ecto.UUID.generate()},
        "validation_failed"
      )
    end

    test "shop_get_checkout_link: a success, and an error for an empty cart", %{p1: p1} do
      token = mcp_token()
      mcp_error("shop_get_checkout_link", %{"cart_token" => token}, "validation_failed")

      mcp_ok("shop_set_cart_items", %{
        "cart_token" => token,
        "items" => [%{"product_id" => p1.uuid, "quantity" => 1}]
      })

      assert %{"url" => url} = mcp_ok("shop_get_checkout_link", %{"cart_token" => token})
      assert url =~ ~r|/checkout/claim/[A-Za-z0-9_-]{43}\z|
    end

    test "the dotted name works over MCP too, and gives the same cart as the underscored one" do
      token = mcp_token()

      dotted = mcp_ok("shop.get_cart", %{"cart_token" => token})
      underscored = mcp_ok("shop_get_cart", %{"cart_token" => token})

      assert Map.drop(dotted, ["read_at"]) == Map.drop(underscored, ["read_at"])
    end
  end
end
