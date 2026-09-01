defmodule PhoenixKitEcommerce.Shopify.StorefrontClientTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shopify.StorefrontClient

  @stub __MODULE__

  defp req_options do
    [req_options: [plug: {Req.Test, @stub}], page_delay_ms: 0]
  end

  defp json_response(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, JSON.encode!(body))
  end

  defp page_param(conn) do
    conn |> Plug.Conn.fetch_query_params() |> Map.fetch!(:query_params) |> Map.fetch!("page")
  end

  describe "fetch_products/2 paging" do
    test "follows pages until an empty page, preserving order across and within pages, trimming fields" do
      Req.Test.stub(@stub, fn conn ->
        case page_param(conn) do
          "1" ->
            json_response(conn, 200, %{
              "products" => [
                %{
                  "handle" => "first",
                  "title" => "First Product",
                  "body_html" => "<p>First</p>",
                  "variants" => [%{"price" => "10.00"}]
                },
                %{
                  "handle" => "second",
                  "title" => "Second Product",
                  "body_html" => "<p>Second</p>",
                  "variants" => [%{"price" => "20.00"}]
                }
              ]
            })

          "2" ->
            json_response(conn, 200, %{
              "products" => [
                %{
                  "handle" => "third",
                  "title" => "Third Product",
                  "body_html" => "<p>Third</p>",
                  "variants" => [%{"price" => "30.00"}]
                }
              ]
            })

          "3" ->
            json_response(conn, 200, %{"products" => []})
        end
      end)

      assert {:ok, [first, second, third]} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())

      assert first["handle"] == "first"
      assert second["handle"] == "second"
      assert third["handle"] == "third"

      for product <- [first, second, third] do
        assert Enum.sort(Map.keys(product)) == ["handle", "variants"]
      end
    end
  end

  describe "fetch_products/2 errors" do
    test "returns an error tuple on a non-200 status instead of raising" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 429, "") end)

      assert {:error, {:unexpected_status, 429}} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
    end

    test "returns an error tuple when a page has no \"products\" key instead of looping forever" do
      Req.Test.stub(@stub, fn conn -> json_response(conn, 200, %{"unexpected" => "shape"}) end)

      assert {:error, _reason} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
    end
  end

  describe "fetch_products/2 priceless products" do
    test "omits products with no priced variants and keeps priced ones" do
      Req.Test.stub(@stub, fn conn ->
        case page_param(conn) do
          "1" ->
            json_response(conn, 200, %{
              "products" => [
                %{"handle" => "no-price", "variants" => []},
                %{"handle" => "has-price", "variants" => [%{"price" => "5.00"}]}
              ]
            })

          "2" ->
            json_response(conn, 200, %{"products" => []})
        end
      end)

      assert {:ok, [%{"handle" => "has-price"}]} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
    end

    test "skips a product whose \"variants\" key is missing entirely, without crashing" do
      Req.Test.stub(@stub, fn conn ->
        case page_param(conn) do
          "1" -> json_response(conn, 200, %{"products" => [%{"handle" => "no-variants-key"}]})
          "2" -> json_response(conn, 200, %{"products" => []})
        end
      end)

      assert {:ok, []} = StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
    end
  end
end
