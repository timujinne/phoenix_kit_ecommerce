defmodule PhoenixKitEcommerce.Shopify.StorefrontClientTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shopify.StorefrontClient

  @stub __MODULE__

  defp req_options(extra \\ []) do
    Keyword.merge([req_options: [plug: {Req.Test, @stub}], page_delay_ms: 0], extra)
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

    test "trims each variant down to \"price\" only, dropping every other variant field" do
      Req.Test.stub(@stub, fn conn ->
        case page_param(conn) do
          "1" ->
            json_response(conn, 200, %{
              "products" => [
                %{
                  "handle" => "rich-variant",
                  "variants" => [
                    %{
                      "id" => 42,
                      "title" => "Default",
                      "price" => "9.00",
                      "compare_at_price" => "19.00",
                      "sku" => "SKU-1",
                      "available" => true
                    }
                  ]
                }
              ]
            })

          "2" ->
            json_response(conn, 200, %{"products" => []})
        end
      end)

      assert {:ok, [%{"variants" => [variant]}]} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())

      assert Map.keys(variant) == ["price"]
      assert variant["price"] == "9.00"
    end
  end

  describe "fetch_products/2 errors" do
    test "returns an error tuple on a non-200 status instead of raising" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 500, "") end)

      assert {:error, {:unexpected_status, 500}} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
    end
  end

  describe "fetch_products/2 malformed pages" do
    test "returns an error, not a crash, when \"products\" is present but not a list" do
      for bad_products <- ["not a list", 42, nil, %{"unexpected" => "shape"}] do
        Req.Test.stub(@stub, fn conn ->
          json_response(conn, 200, %{"products" => bad_products})
        end)

        assert {:error, _reason} =
                 StorefrontClient.fetch_products("test-shop.myshopify.com", req_options()),
               "expected an error tuple for products: #{inspect(bad_products)}"
      end
    end

    test "returns an error instead of looping forever when \"products\" is an empty map" do
      Req.Test.stub(@stub, fn conn -> json_response(conn, 200, %{"products" => %{}}) end)

      task =
        Task.async(fn ->
          StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
        end)

      assert {:error, _reason} = Task.await(task, 1_000)
    end

    test "returns an error when the \"products\" key is missing entirely" do
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

  describe "fetch_products/2 rate limiting" do
    test "retries a 429 response respecting retry-after, and resumes the same page" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        count = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, "")
        else
          case page_param(conn) do
            "1" ->
              json_response(conn, 200, %{
                "products" => [%{"handle" => "survivor", "variants" => [%{"price" => "1.00"}]}]
              })

            "2" ->
              json_response(conn, 200, %{"products" => []})
          end
        end
      end)

      assert {:ok, [%{"handle" => "survivor"}]} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())

      assert Agent.get(counter, & &1) == 3
    end

    test "gives up with {:error, :rate_limited} after exhausting retries" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        Agent.update(counter, &(&1 + 1))

        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.send_resp(429, "")
      end)

      assert {:error, :rate_limited} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())

      # initial attempt + 5 retries
      assert Agent.get(counter, & &1) == 6
    end

    test "resets the retry budget after each successful page" do
      {:ok, counts} = Agent.start_link(fn -> %{} end)

      Req.Test.stub(@stub, fn conn ->
        page = page_param(conn)

        count =
          Agent.get_and_update(counts, fn m ->
            {Map.get(m, page, 0), Map.update(m, page, 1, &(&1 + 1))}
          end)

        cond do
          count < 3 ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "0")
            |> Plug.Conn.send_resp(429, "")

          page == "1" ->
            json_response(conn, 200, %{
              "products" => [%{"handle" => "p1", "variants" => [%{"price" => "1.00"}]}]
            })

          page == "2" ->
            json_response(conn, 200, %{
              "products" => [%{"handle" => "p2", "variants" => [%{"price" => "2.00"}]}]
            })

          page == "3" ->
            json_response(conn, 200, %{"products" => []})
        end
      end)

      # Each page needs 3 failed attempts before succeeding. 3 + 3 = 6 exceeds
      # a 5-retry budget shared across the whole fetch — this only succeeds
      # if the budget resets per page.
      assert {:ok, [%{"handle" => "p1"}, %{"handle" => "p2"}]} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
    end
  end

  describe "fetch_products/2 page cap" do
    test "gives up instead of looping forever against a server that never returns an empty page" do
      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [%{"handle" => "loop", "variants" => [%{"price" => "1.00"}]}]
        })
      end)

      assert {:error, :too_many_pages} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
    end
  end

  describe "fetch_products/2 :page_delay_ms option" do
    test "sleeps for the given :page_delay_ms between pages" do
      Req.Test.stub(@stub, fn conn ->
        case page_param(conn) do
          "1" ->
            json_response(conn, 200, %{
              "products" => [%{"handle" => "only", "variants" => [%{"price" => "1.00"}]}]
            })

          "2" ->
            json_response(conn, 200, %{"products" => []})
        end
      end)

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, [_product]} =
               StorefrontClient.fetch_products(
                 "test-shop.myshopify.com",
                 req_options(page_delay_ms: 30)
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      # Comfortably above the 30ms we asked for, comfortably below the
      # 500ms default — catches both "the option is ignored" (elapsed too
      # low) and "the wrong key is read so the default sneaks in" (elapsed
      # too high).
      assert elapsed_ms >= 20
      assert elapsed_ms < 300
    end

    test "defaults to a 500ms delay between pages when :page_delay_ms is omitted" do
      Req.Test.stub(@stub, fn conn ->
        case page_param(conn) do
          "1" ->
            json_response(conn, 200, %{
              "products" => [%{"handle" => "only", "variants" => [%{"price" => "1.00"}]}]
            })

          "2" ->
            json_response(conn, 200, %{"products" => []})
        end
      end)

      started_at = System.monotonic_time(:millisecond)

      assert {:ok, [_product]} =
               StorefrontClient.fetch_products("test-shop.myshopify.com",
                 req_options: [plug: {Req.Test, @stub}]
               )

      elapsed_ms = System.monotonic_time(:millisecond) - started_at

      assert elapsed_ms >= 400
      assert elapsed_ms < 900
    end
  end
end
