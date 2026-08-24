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
  end
end
