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

  defp variant_list(count, first_id \\ 1) do
    for id <- first_id..(first_id + count - 1),
        do: %{"id" => id, "option1" => "V#{id}", "price" => "10.00"}
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

  describe "fetch_products/2 — variant lists capped at 100" do
    test "a product with fewer than 100 embedded variants is not re-read" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        refute conn.request_path =~ "/variants.json"

        json_response(conn, 200, %{
          "products" => [%{"id" => 1, "handle" => "small", "variants" => variant_list(99)}]
        })
      end)

      assert {:ok, [product]} = AdminClient.fetch_products(uuid, req_options())
      assert length(product["variants"]) == 99
      refute AdminClient.variants_incomplete?(product)
    end

    test "a product at the 100 cap is completed from variants.json, across pages" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        cond do
          String.ends_with?(conn.request_path, "/products.json") ->
            json_response(conn, 200, %{
              "products" => [
                %{
                  "id" => 1,
                  "handle" => "big",
                  "title" => "Big",
                  "variants" => variant_list(100)
                },
                %{"id" => 2, "handle" => "small", "variants" => variant_list(3)}
              ]
            })

          conn.request_path =~ "/products/1/variants.json" and
              conn.query_string =~ "page_info=2" ->
            json_response(conn, 200, %{"variants" => variant_list(6, 251)})

          conn.request_path =~ "/products/1/variants.json" ->
            conn
            |> Plug.Conn.put_resp_header(
              "link",
              ~s(<https://test-shop.myshopify.com#{conn.request_path}?limit=250&page_info=2>; rel="next")
            )
            |> json_response(200, %{"variants" => variant_list(250)})
        end
      end)

      assert {:ok, [big, small]} = AdminClient.fetch_products(uuid, req_options())
      assert length(big["variants"]) == 256
      assert big["title"] == "Big"
      refute AdminClient.variants_incomplete?(big)
      assert length(small["variants"]) == 3
    end

    test "exactly 100 real variants: re-read, same list, no flag" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if conn.request_path =~ "/variants.json",
          do: json_response(conn, 200, %{"variants" => variant_list(100)}),
          else:
            json_response(conn, 200, %{
              "products" => [%{"id" => 1, "handle" => "box", "variants" => variant_list(100)}]
            })
      end)

      assert {:ok, [box]} = AdminClient.fetch_products(uuid, req_options())
      assert length(box["variants"]) == 100
      refute AdminClient.variants_incomplete?(box)
    end

    test "a failed backfill flags only that product and keeps the run going" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        cond do
          conn.request_path =~ "/products/1/variants.json" ->
            json_response(conn, 403, %{"errors" => "nope"})

          conn.request_path =~ "/products/2/variants.json" ->
            json_response(conn, 200, %{"variants" => variant_list(120)})

          true ->
            json_response(conn, 200, %{
              "products" => [
                %{"id" => 1, "handle" => "broken", "variants" => variant_list(100)},
                %{"id" => 2, "handle" => "fine", "variants" => variant_list(100)}
              ]
            })
        end
      end)

      assert {:ok, [broken, fine]} = AdminClient.fetch_products(uuid, req_options())
      assert AdminClient.variants_incomplete?(broken)
      assert broken["_variants_incomplete"] =~ "forbidden"
      assert length(broken["variants"]) == 100
      refute AdminClient.variants_incomplete?(fine)
      assert length(fine["variants"]) == 120
    end

    # Review Focus #2: a rate limit that never clears must not hang the
    # backfill or bring down the whole call — only the one product is
    # flagged. `retry-after: 0` keeps this test from actually sleeping
    # through `@max_retries` real seconds.
    test "a persistent 429 on the variants endpoint flags the product after retries" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if conn.request_path =~ "/variants.json" do
          conn
          |> Plug.Conn.put_resp_header("retry-after", "0")
          |> Plug.Conn.send_resp(429, "")
        else
          json_response(conn, 200, %{
            "products" => [
              %{"id" => 1, "handle" => "rate-limited", "variants" => variant_list(100)}
            ]
          })
        end
      end)

      assert {:ok, [product]} = AdminClient.fetch_products(uuid, req_options())
      assert AdminClient.variants_incomplete?(product)
      assert product["_variants_incomplete"] =~ "rate_limited"
      assert length(product["variants"]) == 100
    end

    # Same shape as "a failed backfill flags only that product and keeps
    # the run going" above, but for a rate limit that never clears rather
    # than an outright 403 — a persistent 429 goes through `fetch_all/5`'s
    # OWN retry loop before it gives up, so this proves that loop doesn't
    # somehow affect (or get stuck on) the next product's own backfill.
    test "a persistent 429 on one product's variants doesn't stop a sibling from completing" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        cond do
          conn.request_path =~ "/products/1/variants.json" ->
            conn
            |> Plug.Conn.put_resp_header("retry-after", "0")
            |> Plug.Conn.send_resp(429, "")

          conn.request_path =~ "/products/2/variants.json" ->
            json_response(conn, 200, %{"variants" => variant_list(120)})

          true ->
            json_response(conn, 200, %{
              "products" => [
                %{"id" => 1, "handle" => "rate-limited", "variants" => variant_list(100)},
                %{"id" => 2, "handle" => "fine", "variants" => variant_list(100)}
              ]
            })
        end
      end)

      assert {:ok, [limited, fine]} = AdminClient.fetch_products(uuid, req_options())
      assert AdminClient.variants_incomplete?(limited)
      assert limited["_variants_incomplete"] =~ "rate_limited"
      assert length(limited["variants"]) == 100
      refute AdminClient.variants_incomplete?(fine)
      assert length(fine["variants"]) == 120
    end

    # `id` here comes straight off the payload, same as `fetch_product/3`'s
    # caller-supplied one — `complete_variants/3` must run it through the
    # same `numeric_id/2` check before ever building `variants_url/2`, or
    # a malformed "id" would be interpolated into the backfill request's
    # path unchecked. No request is ever made for it, but it is still
    # flagged incomplete — a product at the cap with an untrustworthy id
    # must not read as complete to a caller that only ever checks the
    # flag (`ProductDiff`, the variants writer), never the id itself.
    test "a non-numeric product id is flagged incomplete instead of building a bad request" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        refute conn.request_path =~ "/variants.json"

        json_response(conn, 200, %{
          "products" => [%{"id" => "abc", "handle" => "weird", "variants" => variant_list(100)}]
        })
      end)

      assert {:ok, [product]} = AdminClient.fetch_products(uuid, req_options())
      assert length(product["variants"]) == 100
      assert AdminClient.variants_incomplete?(product)
      assert product["_variants_incomplete"] =~ "invalid_product_id"
    end

    test "a product at the cap with no id at all is flagged incomplete, no request made" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        refute conn.request_path =~ "/variants.json"

        json_response(conn, 200, %{
          "products" => [%{"handle" => "no-id", "variants" => variant_list(100)}]
        })
      end)

      assert {:ok, [product]} = AdminClient.fetch_products(uuid, req_options())
      assert length(product["variants"]) == 100
      assert AdminClient.variants_incomplete?(product)
      assert product["_variants_incomplete"] =~ "invalid_product_id"
    end

    test "a 404 on variants.json names the product, not the shop" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if conn.request_path =~ "/variants.json",
          do: json_response(conn, 404, %{"errors" => "Not Found"}),
          else:
            json_response(conn, 200, %{
              "products" => [%{"id" => 1, "handle" => "gone", "variants" => variant_list(100)}]
            })
      end)

      assert {:ok, [product]} = AdminClient.fetch_products(uuid, req_options())
      assert product["_variants_incomplete"] =~ "product_not_found"
      refute product["_variants_incomplete"] =~ "shop_not_found"
    end
  end

  describe "fetch_products/2 — :complete_variants" do
    defp capped_stub(test_pid) do
      fn conn ->
        if conn.request_path =~ "/variants.json" do
          send(test_pid, {:backfilled, conn.request_path})
          json_response(conn, 200, %{"variants" => variant_list(130)})
        else
          json_response(conn, 200, %{
            "products" => [
              %{"id" => 1, "handle" => "wanted", "variants" => variant_list(100)},
              %{"id" => 2, "handle" => "unwanted", "variants" => variant_list(100)},
              %{"id" => 3, "handle" => "small", "variants" => variant_list(4)}
            ]
          })
        end
      end
    end

    test "false: no backfill; a product at the cap is flagged :not_requested" do
      uuid = connect_shopify()
      Req.Test.stub(@stub, capped_stub(self()))

      assert {:ok, [wanted, unwanted, small]} =
               AdminClient.fetch_products(uuid, req_options() ++ [complete_variants: false])

      refute_received {:backfilled, _}
      assert wanted["_variants_incomplete"] =~ "not_requested"
      assert unwanted["_variants_incomplete"] =~ "not_requested"
      assert length(wanted["variants"]) == 100
      refute AdminClient.variants_incomplete?(small)
    end

    test "a predicate backfills only the products it selects, in the original order" do
      uuid = connect_shopify()
      Req.Test.stub(@stub, capped_stub(self()))

      assert {:ok, [wanted, unwanted, small]} =
               AdminClient.fetch_products(
                 uuid,
                 req_options() ++ [complete_variants: &(&1["handle"] == "wanted")]
               )

      assert_received {:backfilled, "/admin/api/2025-01/products/1/variants.json"}
      refute_received {:backfilled, _}
      assert length(wanted["variants"]) == 130
      refute AdminClient.variants_incomplete?(wanted)
      assert unwanted["_variants_incomplete"] =~ "not_requested"
      assert small["handle"] == "small"
      refute AdminClient.variants_incomplete?(small)
    end

    # A caller's predicate may close over something large (the media sync's
    # whole item index). It must run in the calling process: evaluated inside
    # a spawned task, its environment would be copied into every task —
    # thousands of copies for one store.
    test "the predicate runs in the caller, never inside a backfill task" do
      uuid = connect_shopify()
      test_pid = self()
      Req.Test.stub(@stub, capped_stub(test_pid))

      predicate = fn product ->
        send(test_pid, {:predicate_ran_in, self()})
        product["handle"] == "wanted"
      end

      assert {:ok, _products} =
               AdminClient.fetch_products(uuid, req_options() ++ [complete_variants: predicate])

      assert_received {:predicate_ran_in, ^test_pid}

      pids =
        Stream.repeatedly(fn ->
          receive do
            {:predicate_ran_in, pid} -> pid
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)

      assert Enum.all?(pids, &(&1 == test_pid))
    end
  end

  describe "fetch_product/3 credential resolution" do
    test "returns an error for an integration uuid that doesn't exist" do
      assert {:error, _reason} =
               AdminClient.fetch_product(Ecto.UUID.generate(), 123, req_options())
    end

    test "returns an error when the connection has never been configured" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("shopify", "Unconfigured Shop")

      assert {:error, _reason} = AdminClient.fetch_product(uuid, 123, req_options())
    end
  end

  describe "fetch_product/3 requests" do
    test "sends the access token via X-Shopify-Access-Token, hits products/{id}.json, and returns the product map" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-shopify-access-token") == ["shpat_test_token"]
        assert conn.request_path == "/admin/api/2025-01/products/555.json"

        json_response(conn, 200, %{
          "product" => %{"id" => 555, "handle" => "ceramic-vase", "title" => "Ceramic Vase"}
        })
      end)

      assert {:ok, %{"id" => 555, "handle" => "ceramic-vase"}} =
               AdminClient.fetch_product(uuid, 555, req_options())
    end

    test "requests the same field set fetch_products/2 does" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.query_params["fields"] ==
                 "id,handle,title,body_html,vendor,product_type,tags,status,images,variants,options"

        json_response(conn, 200, %{"product" => %{"id" => 555, "handle" => "ceramic-vase"}})
      end)

      assert {:ok, _product} = AdminClient.fetch_product(uuid, 555, req_options())
    end

    test "accepts a string product id, unchanged in the request path" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/admin/api/2025-01/products/555.json"
        json_response(conn, 200, %{"product" => %{"id" => 555}})
      end)

      assert {:ok, %{"id" => 555}} = AdminClient.fetch_product(uuid, "555", req_options())
    end

    # The id lands in the URL path verbatim, so anything but digits could
    # rewrite the request. Refused before any request is made (the stub
    # would fail the test if it were reached).
    test "refuses a non-numeric product id without making a request" do
      uuid = connect_shopify()
      Req.Test.stub(@stub, fn _conn -> flunk("no request should be made") end)

      for bad <- ["555/../shop", "555?x=1", "", "abc", "-1", nil, 1.5] do
        assert {:error, :invalid_product_id} = AdminClient.fetch_product(uuid, bad, req_options())
      end
    end

    test "refuses a non-numeric collection id in fetch_collection_product_ids/2" do
      uuid = connect_shopify()
      Req.Test.stub(@stub, fn _conn -> flunk("no request should be made") end)

      assert {:error, :invalid_collection_id} =
               AdminClient.fetch_collection_product_ids(
                 "1/products",
                 [integration_uuid: uuid] ++ req_options()
               )
    end

    test "returns :unauthorized on a 401 response" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 401, %{"errors" => "Invalid API key"})
      end)

      assert {:error, :unauthorized} = AdminClient.fetch_product(uuid, 555, req_options())
    end

    test "returns :forbidden on a 403 response" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 403, %{"errors" => "This action requires merchant approval"})
      end)

      assert {:error, :forbidden} = AdminClient.fetch_product(uuid, 555, req_options())
    end

    # Deliberately distinct from `fetch_products/2`'s bulk 404
    # (`:shop_not_found` — the SHOP wasn't found): here the shop answered
    # fine, it just doesn't have this product id.
    test "returns :not_found on a 404 response, not :shop_not_found" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn -> json_response(conn, 404, %{"errors" => "Not Found"}) end)

      assert {:error, :not_found} = AdminClient.fetch_product(uuid, 555, req_options())
    end

    test "returns an error on a network failure" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :closed) end)

      assert {:error, %Req.TransportError{}} = AdminClient.fetch_product(uuid, 555, req_options())
    end
  end

  describe "fetch_product/3 rate limiting" do
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
          json_response(conn, 200, %{"product" => %{"id" => 555, "handle" => "ceramic-vase"}})
        end
      end)

      assert {:ok, %{"handle" => "ceramic-vase"}} =
               AdminClient.fetch_product(uuid, 555, req_options())

      assert Agent.get(counter, & &1) == 2
    end

    test "gives up and returns :rate_limited after exhausting retries" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_resp_header("retry-after", "0")
        |> Plug.Conn.send_resp(429, "")
      end)

      assert {:error, :rate_limited} = AdminClient.fetch_product(uuid, 555, req_options())
    end
  end

  describe "fetch_product/3 — variant lists capped at 100" do
    test "completes the variant list the same way" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if conn.request_path =~ "/variants.json",
          do: json_response(conn, 200, %{"variants" => variant_list(160)}),
          else:
            json_response(conn, 200, %{
              "product" => %{"id" => 5, "handle" => "horns", "variants" => variant_list(100)}
            })
      end)

      assert {:ok, product} = AdminClient.fetch_product(uuid, 5, req_options())
      assert length(product["variants"]) == 160
    end

    test "a failed backfill flags the product instead of failing the call" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        if conn.request_path =~ "/variants.json",
          do: json_response(conn, 403, %{"errors" => "nope"}),
          else:
            json_response(conn, 200, %{
              "product" => %{"id" => 5, "handle" => "horns", "variants" => variant_list(100)}
            })
      end)

      assert {:ok, product} = AdminClient.fetch_product(uuid, 5, req_options())
      assert length(product["variants"]) == 100
      assert product["_variants_incomplete"] =~ "forbidden"
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

  describe "fetch_shop/2 credential resolution" do
    test "returns an error for an integration uuid that doesn't exist" do
      assert {:error, _reason} = AdminClient.fetch_shop(Ecto.UUID.generate(), req_options())
    end

    test "returns an error when the connection has never been configured" do
      {:ok, %{uuid: uuid}} = Integrations.add_connection("shopify", "Unconfigured Shop")

      assert {:error, _reason} = AdminClient.fetch_shop(uuid, req_options())
    end
  end

  describe "fetch_shop/2 requests" do
    test "sends the access token via X-Shopify-Access-Token, hits shop.json, and returns the shop map" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        assert Plug.Conn.get_req_header(conn, "x-shopify-access-token") == ["shpat_test_token"]
        assert conn.request_path == "/admin/api/2025-01/shop.json"

        json_response(conn, 200, %{
          "shop" => %{
            "name" => "Test Shop",
            "myshopify_domain" => "test-shop.myshopify.com",
            "currency" => "USD"
          }
        })
      end)

      assert {:ok, %{"currency" => "USD"}} = AdminClient.fetch_shop(uuid, req_options())
    end

    test "returns :unauthorized on a 401 response" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 401, %{"errors" => "Invalid API key"})
      end)

      assert {:error, :unauthorized} = AdminClient.fetch_shop(uuid, req_options())
    end

    test "returns :forbidden on a 403 response" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn ->
        json_response(conn, 403, %{"errors" => "This action requires merchant approval"})
      end)

      assert {:error, :forbidden} = AdminClient.fetch_shop(uuid, req_options())
    end

    test "returns :shop_not_found on a 404 response" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn -> json_response(conn, 404, %{"errors" => "Not Found"}) end)

      assert {:error, :shop_not_found} = AdminClient.fetch_shop(uuid, req_options())
    end

    test "returns an error on a network failure" do
      uuid = connect_shopify()

      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :closed) end)

      assert {:error, %Req.TransportError{}} = AdminClient.fetch_shop(uuid, req_options())
    end
  end

  describe "parse_shop_response/1" do
    # Exercises the response-shape handling directly, with no HTTP call
    # at all — same reason `AdminClient.check_shop_currency/1`'s sibling
    # in the app's own mix task is public.
    test "extracts the shop map from a 200" do
      response = {:ok, %Req.Response{status: 200, body: %{"shop" => %{"currency" => "EUR"}}}}

      assert {:ok, %{"currency" => "EUR"}} = AdminClient.parse_shop_response(response)
    end

    test "maps 401/403/404 to the same atoms fetch_products/2 uses" do
      assert {:error, :unauthorized} =
               AdminClient.parse_shop_response({:ok, %Req.Response{status: 401, body: %{}}})

      assert {:error, :forbidden} =
               AdminClient.parse_shop_response({:ok, %Req.Response{status: 403, body: %{}}})

      assert {:error, :shop_not_found} =
               AdminClient.parse_shop_response({:ok, %Req.Response{status: 404, body: %{}}})
    end

    test "maps any other status to :unexpected_status" do
      assert {:error, {:unexpected_status, 500}} =
               AdminClient.parse_shop_response({:ok, %Req.Response{status: 500, body: %{}}})
    end

    test "passes a transport error straight through" do
      assert {:error, :closed} = AdminClient.parse_shop_response({:error, :closed})
    end
  end
end
