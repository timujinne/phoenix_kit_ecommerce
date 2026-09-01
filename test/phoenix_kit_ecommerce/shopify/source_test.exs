defmodule PhoenixKitEcommerce.Shopify.SourceTest do
  @moduledoc """
  Tests `Source.decide/2` — the pure decision core. No I/O, no database.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.Source

  @domain "test-shop.myshopify.com"
  @credential_errors [:unauthorized, :missing_credentials, :forbidden]
  @all_fields ProductDiff.comparable_fields()

  describe "decide/2 — admin succeeded" do
    test "uses admin regardless of the shop domain result, tagging every comparable field" do
      assert Source.decide({:ok, [%{"handle" => "planter"}]}, {:ok, @domain}) ==
               {:use_admin, [%{"handle" => "planter"}], @all_fields}
    end

    test "uses admin even when the shop domain lookup itself failed" do
      assert Source.decide({:ok, []}, {:error, :not_configured}) ==
               {:use_admin, [], @all_fields}
    end
  end

  describe "decide/2 — credential errors fall back to storefront when a domain is available" do
    for reason <- @credential_errors do
      test "#{reason} falls back, carrying the domain, the reason, and :price-only" do
        assert Source.decide({:error, unquote(reason)}, {:ok, @domain}) ==
                 {:use_storefront, @domain, unquote(reason), [:price]}
      end
    end
  end

  describe "decide/2 — credential errors abort when no usable domain is available" do
    for reason <- @credential_errors do
      test "#{reason} aborts when the shop domain lookup itself failed" do
        assert Source.decide({:error, unquote(reason)}, {:error, :not_configured}) ==
                 {:abort, unquote(reason)}
      end
    end

    test "aborts on an empty-string domain" do
      assert Source.decide({:error, :unauthorized}, {:ok, ""}) == {:abort, :unauthorized}
    end

    test "aborts on a nil domain — pins the is_binary/1 guard" do
      assert Source.decide({:error, :unauthorized}, {:ok, nil}) == {:abort, :unauthorized}
    end
  end

  describe "decide/2 — non-credential errors always abort, never fall back" do
    # This is the important case: a rate limit, a 5xx, a timeout are
    # transient Admin-side problems, not proof the token is bad. Falling
    # back on these would silently narrow the report to price-only and
    # claim "no text changes" when the truth is "we could not check".
    #
    # These are the actual atoms `AdminClient.fetch_products/2` emits for
    # non-credential failures (:shop_not_found from a 404, :rate_limited
    # once its own retry budget is exhausted, {:unexpected_status, _} as
    # its catch-all, and any raw `Req` error term) — not a hypothetical
    # list. Pinning these specific values, not just synthetic ones like
    # `:timeout`, is what stops `@credential_errors` in `Source` from
    # silently growing to include one of them.
    for reason <- [
          :shop_not_found,
          :rate_limited,
          {:unexpected_status, 500},
          %Req.TransportError{reason: :closed}
        ] do
      test "#{inspect(reason)} aborts even though a domain is available" do
        assert Source.decide({:error, unquote(Macro.escape(reason))}, {:ok, @domain}) ==
                 {:abort, unquote(Macro.escape(reason))}
      end
    end

    test "an arbitrary transient error (timeout) aborts" do
      assert Source.decide({:error, :timeout}, {:ok, @domain}) == {:abort, :timeout}
    end
  end
end

defmodule PhoenixKitEcommerce.Shopify.SourceFetchTest do
  @moduledoc """
  Integration coverage for `Source.fetch/2` — the I/O shell, which calls
  `PhoenixKit.Integrations.get_credentials/1`, `AdminClient`, and (on
  fallback) `StorefrontClient`. Needs the test database (`DataCase`); run
  `mix test` with a reachable `phoenix_kit_ecommerce_test` (see
  `test/test_helper.exs`) for these to execute — without one they are
  excluded, same as any other `DataCase` test in this repo.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.Source

  @stub __MODULE__
  @all_fields ProductDiff.comparable_fields()

  defp connect_shopify(attrs \\ %{}) do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection("shopify", "Test Shop #{System.unique_integer([:positive])}")

    {:ok, _} =
      Integrations.save_setup(
        uuid,
        Map.merge(
          %{"shop_domain" => "test-shop.myshopify.com", "access_token" => "shpat_test_token"},
          attrs
        )
      )

    uuid
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        admin_options: [req_options: [plug: {Req.Test, @stub}]],
        storefront_options: [req_options: [plug: {Req.Test, @stub}], page_delay_ms: 0]
      ],
      extra
    )
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  defp admin_request?(conn), do: String.starts_with?(conn.request_path, "/admin/")

  defp storefront_page(conn) do
    conn |> Plug.Conn.fetch_query_params() |> Map.fetch!(:query_params) |> Map.get("page")
  end

  # The storefront stub must terminate its own pagination (an empty page
  # once page 1 is served) — a stub that always returns products makes
  # `StorefrontClient` page until `:too_many_pages`, which is what
  # actually happened here the first time: the test asserted on a result
  # it never reached.
  defp storefront_first_page(conn) do
    if storefront_page(conn) == "1" do
      json_response(conn, 200, %{
        "products" => [%{"handle" => "planter", "variants" => [%{"price" => "12.00"}]}]
      })
    else
      json_response(conn, 200, %{"products" => []})
    end
  end

  describe "fetch/2 — admin available" do
    test "returns the admin source tagged with every comparable field and no fallback reason" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"products" => [%{"handle" => "planter"}]})
      end)

      assert {:ok,
              %{
                source: :admin,
                products: [%{"handle" => "planter"}],
                only: @all_fields,
                fallback_reason: nil
              }} = Source.fetch(uuid, opts())
    end
  end

  describe "fetch/2 — credential failure falls back to storefront" do
    test "falls back on 401, tagging the result price-only and carrying the reason" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 401, %{"errors" => "Invalid API key"})
        else
          storefront_first_page(conn)
        end
      end)

      assert {:ok,
              %{
                source: :storefront,
                products: [%{"handle" => "planter", "variants" => [%{"price" => "12.00"}]}],
                only: [:price],
                fallback_reason: :unauthorized
              }} = Source.fetch(uuid, opts())
    end

    test "falls back on 403 (token installed without the read_products scope)" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 403, %{"errors" => "This action requires merchant approval"})
        else
          storefront_first_page(conn)
        end
      end)

      assert {:ok, %{source: :storefront, fallback_reason: :forbidden}} =
               Source.fetch(uuid, opts())
    end

    test "surfaces the storefront's own error when the fallback also fails" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          json_response(conn, 401, %{"errors" => "Invalid API key"})
        else
          json_response(conn, 500, %{})
        end
      end)

      assert {:error, {:unexpected_status, 500}} = Source.fetch(uuid, opts())
    end
  end

  describe "fetch/2 — non-credential admin failures abort without touching the storefront" do
    test "a rate limit aborts instead of falling back" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if admin_request?(conn) do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> json_response(429, %{"errors" => "Too many requests"})
        else
          flunk("storefront should never be called for a non-credential admin failure")
        end
      end)

      assert {:error, :rate_limited} = Source.fetch(uuid, opts())
    end
  end

  describe "fetch/2 — no usable connection" do
    test "aborts when the connection was never configured" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("shopify", "Unconfigured Shop")

      assert {:error, _reason} = Source.fetch(uuid, opts())
    end

    test "aborts, not crashes, when the connection has a token but a blank shop domain" do
      # No stub registered: AdminClient itself already rejects this data
      # as incomplete before making any HTTP request (its own
      # `{:ok, %{"shop_domain" => shop_domain, "access_token" => ...}}`
      # match fails the `shop_domain != ""` guard), and so does
      # `Source`'s private `shop_domain/1` — proving its `{:ok,
      # _incomplete}` clause is reachable, not dead defensive code.
      uuid = connect_shopify(%{"shop_domain" => ""})

      assert {:error, :missing_credentials} = Source.fetch(uuid, opts())
    end
  end
end
