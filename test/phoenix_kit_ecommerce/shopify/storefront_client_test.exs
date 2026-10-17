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

    test "reports an unexpected body by its shape, never its content" do
      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{"secret" => "internal-metadata-value"})
      end)

      assert {:error, {:unexpected_body, summary}} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())

      assert summary == {:object, 1}
      refute inspect(summary) =~ "internal-metadata-value"
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

    # `priced_variants/1`'s `is_binary/1` filter is load-bearing across a
    # module boundary and was, until this test, unpinned: relaxing it to
    # `reject(&is_nil/1)` (which would still pass every OTHER test in
    # this file) lets a variant with a JSON *number* price through, and
    # `ProductDiff.min_variant_price/1` calls `Decimal.new/1` on
    # whatever this module hands it — which raises on a float instead of
    # a string. A real JSON round trip (not a hand-built Elixir map), so
    # the stubbed price really does decode back as a float, not a string
    # that merely looks numeric.
    test "drops a variant whose price is a JSON number, not a string — the shape Decimal.new/1 cannot take" do
      Req.Test.stub(@stub, fn conn ->
        case page_param(conn) do
          "1" ->
            json_response(conn, 200, %{
              "products" => [
                %{"handle" => "numeric-price", "variants" => [%{"price" => 5.0}]},
                %{"handle" => "string-price", "variants" => [%{"price" => "5.00"}]}
              ]
            })

          "2" ->
            json_response(conn, 200, %{"products" => []})
        end
      end)

      assert {:ok, [%{"handle" => "string-price", "variants" => [%{"price" => "5.00"}]}]} =
               StorefrontClient.fetch_products("test-shop.myshopify.com", req_options())
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

    # `retry-after: -1` end to end: without the clamp, `Process.sleep(-1)`
    # raises `FunctionClauseError` straight out of a function whose own
    # `@spec` promises `{:ok, _} | {:error, _}` — reproduced through the
    # real fetch path, not just the clamp math below, since that's where
    # the review found it.
    test "a negative Retry-After does not crash the fetch", %{} do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        count = Agent.get_and_update(counter, fn c -> {c, c + 1} end)

        if count == 0 do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "-1")
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
    end
  end

  describe "retry_after_seconds/1" do
    defp response_with_header(value) do
      %{headers: [{"retry-after", value}]}
    end

    # Both come from `Retry-After` — the ONE header value in this module
    # that originates from an unauthenticated public endpoint, not a
    # store operator's own data. Direct calls, not a real fetch: pinning
    # "does not sleep more than 60s" through a real `Process.sleep` would
    # mean actually waiting 60 real seconds in the suite.
    test "clamps a negative value to 0 instead of crashing Process.sleep/1" do
      assert StorefrontClient.retry_after_seconds(response_with_header("-1")) == 0
    end

    test "clamps a huge value to the 60s cap instead of sleeping unbounded" do
      assert StorefrontClient.retry_after_seconds(response_with_header("86400")) == 60
    end

    test "passes a normal value through unclamped" do
      assert StorefrontClient.retry_after_seconds(response_with_header("30")) == 30
    end

    test "falls back to the default when the header is absent or unparseable" do
      assert StorefrontClient.retry_after_seconds(%{headers: []}) == 5
      assert StorefrontClient.retry_after_seconds(response_with_header("not-a-number")) == 5
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

  describe "fetch_products/2 :deadline_ms option" do
    # `@max_pages * @max_retries * @max_retry_after_seconds` is ~16.7
    # hours of a `start_async` task sleeping with the spinner up (see the
    # moduledoc) — the per-sleep clamp bounds any ONE sleep, not the
    # fetch as a whole. A server that never returns an empty page would,
    # without a deadline, page all the way to `{:error, :too_many_pages}`
    # (the page-cap test above) — potentially real hours away. A short
    # `:deadline_ms` here proves the aggregate budget cuts in first,
    # before that cap is ever reached.
    test "returns {:error, :deadline_exceeded} once the wall-clock budget is exhausted, instead of paging until :too_many_pages" do
      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 200, %{
          "products" => [%{"handle" => "loop", "variants" => [%{"price" => "1.00"}]}]
        })
      end)

      assert {:error, :deadline_exceeded} =
               StorefrontClient.fetch_products(
                 "test-shop.myshopify.com",
                 req_options(page_delay_ms: 100, deadline_ms: 50)
               )
    end

    test "does not cut off a fetch that completes within the deadline" do
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

      assert {:ok, [%{"handle" => "only"}]} =
               StorefrontClient.fetch_products(
                 "test-shop.myshopify.com",
                 req_options(deadline_ms: 5_000)
               )
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

      # Assert the minimum delay: scheduler contention can increase the
      # elapsed time without changing the configured pagination interval.
      assert elapsed_ms >= 400
    end
  end

  describe "redirects" do
    defp redirect(conn, location) do
      conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(301, "")
    end

    defp empty_page(conn), do: json_response(conn, 200, %{"products" => []})

    defp public_only(host) do
      if host == "shop.example.com", do: {:ok, {93, 184, 216, 34}}, else: :error
    end

    defp fetch(extra \\ []) do
      StorefrontClient.fetch_products(
        "test-shop.myshopify.com",
        req_options([address_check: &public_only/1] ++ extra)
      )
    end

    test "a hop to a custom domain is followed, pinned to the address that was checked" do
      test_pid = self()

      Req.Test.stub(@stub, fn conn ->
        send(test_pid, {:request, conn.host, Plug.Conn.get_req_header(conn, "host")})

        if conn.host == "test-shop.myshopify.com" do
          redirect(conn, "https://shop.example.com/products.json?limit=250&page=1")
        else
          empty_page(conn)
        end
      end)

      assert {:ok, []} = fetch()

      assert_received {:request, "test-shop.myshopify.com", _}
      # Connected to the checked IP, still addressed as the domain.
      assert_received {:request, "93.184.216.34", ["shop.example.com"]}
    end

    test "a relative Location stays on the shop host" do
      Req.Test.stub(@stub, fn conn ->
        if conn.request_path == "/products.json",
          do: redirect(conn, "/moved/products.json"),
          else: empty_page(conn)
      end)

      assert {:ok, []} = fetch()
    end

    test "plain http, a bare IP and a private resolution are refused before any request" do
      test_pid = self()

      for target <- [
            "http://shop.example.com/products.json",
            "https://127.0.0.1/products.json",
            "https://internal.example.net/products.json",
            "https://shop.example.com:8443/products.json",
            "https://user:pw@shop.example.com/products.json"
          ] do
        Req.Test.stub(@stub, fn conn ->
          send(test_pid, {:request, conn.host})

          if conn.host == "test-shop.myshopify.com",
            do: redirect(conn, target),
            else: flunk("#{target} must not be requested")
        end)

        assert {:error, {:redirect_refused, _}} = fetch()
        assert_received {:request, "test-shop.myshopify.com"}
        refute_received {:request, _}
      end
    end

    test "a chain longer than three hops stops" do
      Req.Test.stub(@stub, fn conn ->
        redirect(conn, "https://test-shop.myshopify.com/products.json?page=1")
      end)

      assert {:error, :too_many_redirects} = fetch()
    end
  end

  test "a shop domain that is not a bare myshopify.com host is refused without a request" do
    Req.Test.stub(@stub, fn _conn -> flunk("no request should be made") end)

    for domain <- ["internal-host:8443/x#", "shop.example.com", ""] do
      assert StorefrontClient.fetch_products(domain, req_options()) ==
               {:error, :invalid_shop_domain}
    end
  end
end
