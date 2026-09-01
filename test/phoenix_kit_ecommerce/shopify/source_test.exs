defmodule PhoenixKitEcommerce.Shopify.SourceTest do
  @moduledoc """
  Tests `Source.decide/2` — the pure decision core. No I/O, no database,
  so (unlike `SourceFetchTest` below) these actually run in this
  environment.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shopify.Source

  @domain "test-shop.myshopify.com"
  @credential_errors [:unauthorized, :missing_credentials, :forbidden]

  describe "decide/2 — admin succeeded" do
    test "uses admin regardless of the shop domain result" do
      assert Source.decide({:ok, [%{"handle" => "planter"}]}, {:ok, @domain}) ==
               {:use_admin, [%{"handle" => "planter"}]}
    end

    test "uses admin even when the shop domain lookup itself failed" do
      assert Source.decide({:ok, []}, {:error, :not_configured}) == {:use_admin, []}
    end
  end

  describe "decide/2 — credential errors fall back to storefront when a domain is available" do
    for reason <- @credential_errors do
      test "#{reason} falls back, carrying the reason" do
        assert Source.decide({:error, unquote(reason)}, {:ok, @domain}) ==
                 {:use_storefront, unquote(reason)}
      end
    end
  end

  describe "decide/2 — credential errors abort when no domain is available" do
    for reason <- @credential_errors do
      test "#{reason} aborts when the shop domain could not be resolved" do
        assert Source.decide({:error, unquote(reason)}, {:error, :not_configured}) ==
                 {:abort, unquote(reason)}
      end
    end

    test "aborts on an empty-string domain (not a usable domain)" do
      assert Source.decide({:error, :unauthorized}, {:ok, ""}) == {:abort, :unauthorized}
    end
  end

  describe "decide/2 — non-credential errors always abort, never fall back" do
    # This is the important case: a rate limit, a 5xx, a timeout are
    # transient Admin-side problems, not proof the token is bad. Falling
    # back on these would silently narrow the report to price-only and
    # claim "no text changes" when the truth is "we could not check".
    test "a rate limit aborts even though a domain is available" do
      assert Source.decide({:error, :rate_limited}, {:ok, @domain}) ==
               {:abort, :rate_limited}
    end

    test "an unexpected 5xx status aborts" do
      assert Source.decide({:error, {:unexpected_status, 500}}, {:ok, @domain}) ==
               {:abort, {:unexpected_status, 500}}
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
  fallback) `StorefrontClient`.

  THESE TESTS DO NOT RUN IN THIS ENVIRONMENT. This container has no test
  database: `phoenix_kit_ecommerce_test` exists on the server but is owned
  by a role this container cannot use, and our role lacks CREATEDB (see
  `test/test_helper.exs`). `DataCase` tags every test here `:integration`,
  and `test_helper.exs` excludes that tag whenever the database is
  unreachable — which is always, here. `mix test` will report these as
  excluded, not passing; a green run of the suite is NOT coverage for
  `fetch/2`. They are written to run correctly the moment a real test
  database is available. The behavior that matters — the fallback/abort
  decision itself — is covered separately by `SourceTest` above, which
  does run.
  """

  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.Shopify.Source

  @stub __MODULE__

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

  describe "fetch/2 — admin available" do
    test "returns the admin source with :all fields and no fallback reason" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"products" => [%{"handle" => "planter"}]})
      end)

      assert {:ok,
              %{
                source: :admin,
                products: [%{"handle" => "planter"}],
                only: :all,
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
          json_response(conn, 200, %{
            "products" => [%{"handle" => "planter", "variants" => [%{"price" => "12.00"}]}]
          })
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
  end
end
