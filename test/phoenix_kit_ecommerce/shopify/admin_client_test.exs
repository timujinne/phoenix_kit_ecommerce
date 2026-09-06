defmodule PhoenixKitEcommerce.Shopify.AdminClientTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.Shopify.AdminClient

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

  defp req_options do
    [req_options: [plug: {Req.Test, @stub}]]
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  describe "fetch_products/2 credential resolution" do
    test "returns an error for an integration uuid that doesn't exist" do
      assert {:error, _reason} = AdminClient.fetch_products(Ecto.UUID.generate(), req_options())
    end

    test "returns an error when the connection has never been configured" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("shopify", "Unconfigured Shop")

      assert {:error, _reason} = AdminClient.fetch_products(uuid, req_options())
    end
  end

  describe "fetch_products/2 requests" do
    test "sends the access token via X-Shopify-Access-Token, not Authorization" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-shopify-access-token") == ["shpat_test_token"]
        assert Plug.Conn.get_req_header(conn, "authorization") == []

        json_response(conn, 200, %{"products" => []})
      end)

      assert {:ok, []} = AdminClient.fetch_products(uuid, req_options())
    end

    test "returns :unauthorized on a 401 response" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 401, %{"errors" => "Invalid API key"})
      end)

      assert {:error, :unauthorized} = AdminClient.fetch_products(uuid, req_options())
    end

    test "returns :forbidden on a 403 response" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 403, %{"errors" => "This action requires merchant approval"})
      end)

      assert {:error, :forbidden} = AdminClient.fetch_products(uuid, req_options())
    end

    test "returns an error on a network failure" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :closed) end)

      assert {:error, %Req.TransportError{}} = AdminClient.fetch_products(uuid, req_options())
    end
  end

  describe "fetch_products/2 pagination" do
    test "follows the Link: rel=\"next\" header across pages, preserving order" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        if conn.query_params["page_info"] do
          json_response(conn, 200, %{"products" => [%{"id" => 2, "handle" => "second"}]})
        else
          next_url =
            "https://test-shop.myshopify.com/admin/api/2025-01/products.json?limit=250&page_info=abc123"

          conn
          |> Plug.Conn.put_resp_header("link", "<#{next_url}>; rel=\"next\"")
          |> json_response(200, %{"products" => [%{"id" => 1, "handle" => "first"}]})
        end
      end)

      assert {:ok, [%{"handle" => "first"}, %{"handle" => "second"}]} =
               AdminClient.fetch_products(uuid, req_options())
    end

    test "stops when the Link header has no rel=\"next\"" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"products" => [%{"id" => 1, "handle" => "only"}]})
      end)

      assert {:ok, [%{"handle" => "only"}]} = AdminClient.fetch_products(uuid, req_options())
    end
  end

  describe "fetch_products/2 rate limiting" do
    test "retries a 429 response, respecting Retry-After" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        count = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, "")
        else
          json_response(conn, 200, %{"products" => [%{"id" => 1, "handle" => "product"}]})
        end
      end)

      assert {:ok, [%{"handle" => "product"}]} = AdminClient.fetch_products(uuid, req_options())
      assert Agent.get(counter, & &1) == 2
    end

    # `Retry-After` crosses the network, and `Process.sleep/1` accepts
    # only a non-negative integer or `:infinity` — an unclamped negative
    # raised `FunctionClauseError` straight out of a function whose spec
    # promises `{:ok, _} | {:error, _}`. `StorefrontClient` clamps and
    # pins this; the Admin path did neither. Asserted through a real
    # fetch because the clamp is private here (the storefront's is
    # `@doc false`-public for the same reason its 60s cap can't be
    # proven through a real sleep).
    test "survives a negative Retry-After instead of crashing Process.sleep/1" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        count = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "-1")
          |> Plug.Conn.send_resp(429, "")
        else
          json_response(conn, 200, %{"products" => [%{"id" => 1, "handle" => "product"}]})
        end
      end)

      assert {:ok, [%{"handle" => "product"}]} = AdminClient.fetch_products(uuid, req_options())
      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "fetch_collections/1" do
    test "returns an error when :integration_uuid is missing from opts" do
      assert {:error, :missing_integration_uuid} =
               AdminClient.fetch_collections(req_options())
    end

    test "concatenates custom then smart collections, tagged by kind, positioned across both" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        case conn.request_path do
          "/admin/api/2025-01/custom_collections.json" ->
            json_response(conn, 200, %{
              "custom_collections" => [
                %{"id" => 1, "handle" => "featured", "title" => "Featured"}
              ]
            })

          "/admin/api/2025-01/smart_collections.json" ->
            json_response(conn, 200, %{
              "smart_collections" => [
                %{"id" => 2, "handle" => "auto", "title" => "Auto"}
              ]
            })
        end
      end)

      assert {:ok, collections} =
               AdminClient.fetch_collections(Keyword.put(req_options(), :integration_uuid, uuid))

      assert [
               %{"id" => 1, "handle" => "featured", "kind" => "custom", "position" => 0},
               %{"id" => 2, "handle" => "auto", "kind" => "smart", "position" => 1}
             ] = collections
    end

    test "follows pagination independently for each collection kind" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case {conn.request_path, conn.query_params["page_info"]} do
          {"/admin/api/2025-01/custom_collections.json", nil} ->
            next_url =
              "https://test-shop.myshopify.com/admin/api/2025-01/custom_collections.json?limit=250&page_info=custom2"

            conn
            |> Plug.Conn.put_resp_header("link", "<#{next_url}>; rel=\"next\"")
            |> json_response(200, %{
              "custom_collections" => [%{"id" => 1, "handle" => "first"}]
            })

          {"/admin/api/2025-01/custom_collections.json", "custom2"} ->
            json_response(conn, 200, %{
              "custom_collections" => [%{"id" => 2, "handle" => "second"}]
            })

          {"/admin/api/2025-01/smart_collections.json", _} ->
            json_response(conn, 200, %{"smart_collections" => []})
        end
      end)

      assert {:ok, collections} =
               AdminClient.fetch_collections(Keyword.put(req_options(), :integration_uuid, uuid))

      assert [
               %{"handle" => "first", "position" => 0},
               %{"handle" => "second", "position" => 1}
             ] = collections
    end
  end

  describe "fetch_collection_product_ids/2" do
    test "returns an error when :integration_uuid is missing from opts" do
      assert {:error, :missing_integration_uuid} =
               AdminClient.fetch_collection_product_ids(99, req_options())
    end

    test "follows pagination, preserving Shopify's own order" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.request_path == "/admin/api/2025-01/collections/99/products.json"

        if conn.query_params["page_info"] do
          json_response(conn, 200, %{"products" => [%{"id" => 20}]})
        else
          next_url =
            "https://test-shop.myshopify.com/admin/api/2025-01/collections/99/products.json?limit=250&fields=id&page_info=abc123"

          conn
          |> Plug.Conn.put_resp_header("link", "<#{next_url}>; rel=\"next\"")
          |> json_response(200, %{"products" => [%{"id" => 10}]})
        end
      end)

      assert {:ok, [10, 20]} =
               AdminClient.fetch_collection_product_ids(
                 99,
                 Keyword.put(req_options(), :integration_uuid, uuid)
               )
    end
  end
end
