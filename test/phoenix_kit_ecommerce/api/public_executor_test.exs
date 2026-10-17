defmodule PhoenixKitEcommerce.API.PublicExecutorTest do
  @moduledoc """
  The five tools through core's real executor: schema validation, `max_items`,
  rate limiting, problem+json and the JSON answer. `Auth` (the API switch and
  the website gate) sits in front of the executor in production and is core's
  own test; here the executor is called directly with an anonymous caller.

  `async: false`: Billing's currency cache and the limiter table are node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :requires_core_api

  @compile {:no_warn_undefined, PhoenixKit.API.Executor}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.API.Executor
  alias PhoenixKit.Settings

  setup do
    disable_languages!()
    currencies!()
    sample_shop!()
  end

  # Fixed one-minute windows: start with room, or the counter can reset between two calls.
  defp wait_for_window_room(min_left_ms \\ 1_500) do
    left = 60_000 - rem(System.os_time(:millisecond), 60_000)
    if left < min_left_ms, do: Process.sleep(left + 10)
    :ok
  end

  defp call(tool, input, ip \\ nil) do
    ip = ip || {10, 1, rem(System.unique_integer([:positive]), 250), :rand.uniform(250)}

    conn =
      :post
      |> Plug.Test.conn("/api/shop/v1/" <> tool)
      |> Map.put(:remote_ip, ip)
      |> Executor.call(:public, tool, input)

    {conn.status, JSON.decode!(conn.resp_body), conn}
  end

  test "shop.search_products answers 200 with JSON", t do
    {status, body, conn} = call("shop.search_products", %{"q" => "vase"})

    assert status == 200
    assert body["count"] == 3

    assert body["items"] |> Enum.take(2) |> Enum.map(& &1["id"]) |> Enum.sort() ==
             Enum.sort([t.a, t.c])

    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
  end

  test "every search filter works through the executor on a JSON-decoded body", t do
    json = fn input -> input |> JSON.encode!() |> JSON.decode!() end

    ids = fn input ->
      {200, body, _} = call("shop.search_products", json.(input))
      {body["items"] |> Enum.map(& &1["id"]) |> Enum.sort(), body["count"]}
    end

    assert {_, 5} = ids.(%{})
    assert ids.(%{"category_id" => t.home}) == {Enum.sort([t.a, t.b, t.c]), 3}

    assert ids.(%{"options" => %{"size" => ["large", "small"], "colour" => ["red"]}}) ==
             {[t.a], 1}

    assert ids.(%{"vendor" => "ACME"}) == {[t.a], 1}
    assert ids.(%{"on_sale" => true}) == {[t.a], 1}
    assert ids.(%{"made_to_order" => true}) == {[t.c], 1}
    assert ids.(%{"price_min" => "15", "price_max" => 20}) == {Enum.sort([t.a, t.e]), 2}

    {200, batch, _} =
      call(
        "shop.search_products_batch",
        json.(%{"queries" => [%{"vendor" => "beta"}, %{"made_to_order" => true}, %{}]})
      )

    assert [one, two, all] = batch["results"]
    assert Enum.map(one["items"], & &1["id"]) == [t.b]
    assert Enum.map(two["items"], & &1["id"]) == [t.c]
    assert all["count"] == 5
  end

  test "a number too large to be a limit or a price is a 422 before any handler runs", t do
    huge = 10 ** 30

    for {tool, input, path} <- [
          {"shop.search_products", %{"limit" => huge}, "limit"},
          {"shop.search_products", %{"price_min" => huge}, "price_min"},
          {"shop.search_products", %{"price_max" => huge}, "price_max"},
          {"shop.search_products", %{"price_max" => String.duplicate("9", 41)}, "price_max"},
          {"shop.search_products_batch", %{"queries" => [%{"limit" => huge}]},
           "queries[0].limit"},
          {"shop.similar_products", %{"id" => t.a, "limit" => huge}, "limit"}
        ] do
      assert {422, body, _} = call(tool, input)
      assert [%{"path" => ^path}] = body["context"]["errors"]
    end
  end

  test "a price bound too large to convert is a 422 in another currency too, never a 500" do
    for input <- [
          %{"currency" => "EUR", "price_max" => 10 ** 7_000},
          %{"currency" => "EUR", "price_min" => 10 ** 20_000},
          %{"currency" => "EUR", "price_max" => String.duplicate("9", 40)},
          %{"currency" => "EUR", "price_max" => 1.0e300}
        ] do
      assert {422, body, _} = call("shop.search_products", input)
      assert [%{"path" => "price_" <> _}] = body["context"]["errors"]
    end

    # 10.00 EUR is 11.00 USD: the 10.00 and 5.00 products.
    assert {200, %{"count" => 2}, _} =
             call("shop.search_products", %{"currency" => "EUR", "price_max" => "10"})
  end

  test "a q over 200 characters is a 422 that names it, never a 500; 200 characters are searched" do
    assert {422, body, _} =
             call("shop.search_products", %{"q" => String.duplicate("vase ", 2_000)})

    assert [%{"path" => "q"}] = body["context"]["errors"]

    assert {422, body, _} =
             call("shop.search_products_batch", %{
               "queries" => [%{"q" => "vase"}, %{"q" => String.duplicate("v", 201)}]
             })

    assert [%{"path" => "queries[1].q"}] = body["context"]["errors"]

    assert {200, %{"match_mode" => mode}, _} =
             call("shop.search_products", %{"q" => String.duplicate("v", 200)})

    assert mode in ["fulltext", "typo"]
  end

  test "a NUL byte in a vendor or an option is a 422 that names it, in a batch one error block" do
    # The NUL arrives the way a client sends it: as a JSON escape.
    json = fn input -> input |> JSON.encode!() |> JSON.decode!() end
    nul = <<0>>

    for {input, path} <- [
          {%{"vendor" => "Ac" <> nul <> "me"}, "vendor"},
          {%{"options" => %{("si" <> nul <> "ze") => ["large"]}}, "options"},
          {%{"options" => %{"size" => ["la" <> nul <> "rge"]}}, "options.size"}
        ] do
      assert {422, body, _} = call("shop.search_products", json.(input))
      assert [%{"path" => ^path}] = body["context"]["errors"]
    end

    {200, batch, _} =
      call(
        "shop.search_products_batch",
        json.(%{"queries" => [%{"vendor" => "Ac" <> nul}, %{"vendor" => "acme"}]})
      )

    assert [bad, good] = batch["results"]
    assert bad["error"]["code"] == "validation_failed"
    assert good["count"] == 1
  end

  test "an option value or an option list over the limits is a 422 before any handler runs" do
    for options <- [
          %{"size" => [String.duplicate("a", 201)]},
          %{"size" => Enum.map(1..51, &"v#{&1}")}
        ] do
      assert {422, body, _} = call("shop.search_products", %{"options" => options})
      assert [%{"path" => "options.size" <> _}] = body["context"]["errors"]
    end
  end

  test "language and currency are accepted; any other field is a 422, the control fields of write tools included" do
    assert {200, %{"currency" => "EUR"}, _} =
             call("shop.search_products", %{
               "q" => "vase",
               "language" => "en",
               "currency" => "EUR"
             })

    for bad <- [
          %{"bogus" => 1},
          %{"dry_run" => true},
          %{"confirm_token" => "x"},
          %{"api_key" => "x"}
        ] do
      assert {422, body, _} = call("shop.search_products", bad)
      assert body["code"] == "validation_failed"
      assert [%{"path" => path}] = body["context"]["errors"]
      assert path == bad |> Map.keys() |> hd()
    end
  end

  test "an unknown language or currency is a 422 that lists what is allowed" do
    assert {422, body, _} = call("shop.search_products", %{"language" => "xx"})
    assert [%{"path" => "language", "allowed" => ["en"]}] = body["context"]["errors"]

    assert {422, body, _} = call("shop.search_products", %{"currency" => "XXX"})
    assert [%{"path" => "currency", "allowed" => ["EUR", "USD"]}] = body["context"]["errors"]
  end

  # One letter and 300 combining marks: a single grapheme, 301 code points. The
  # schema counts code points, `SearchParams` counts graphemes, so only the
  # schema's own bound refuses it.
  @many_marks "a" <> String.duplicate("\u0301", 300)

  test "the schema bounds hold on their own: a vendor and an option value over 200 code points" do
    assert {422, body, _} = call("shop.search_products", %{"vendor" => @many_marks})
    assert [%{"path" => "vendor", "limit" => 200}] = body["context"]["errors"]

    assert {422, body, _} =
             call("shop.search_products", %{"options" => %{"size" => [@many_marks]}})

    assert [%{"path" => "options.size[0]", "limit" => 200}] = body["context"]["errors"]

    assert {422, body, _} =
             call("shop.search_products_batch", %{"queries" => [%{"vendor" => @many_marks}]})

    assert [%{"path" => "queries[0].vendor"}] = body["context"]["errors"]
  end

  test "the schema bounds hold on their own: more than 50 values of one option" do
    values = Enum.map(1..51, &"v#{&1}")

    assert {422, body, _} = call("shop.search_products", %{"options" => %{"size" => values}})

    assert [%{"path" => "options.size", "limit" => 50, "message" => message}] =
             body["context"]["errors"]

    assert message =~ "50 items"
  end

  test "the schema bounds hold on their own: a price string over 40 characters that is a number" do
    # 41 zeros parse as 0, so only the schema's maxLength refuses them.
    assert {200, _, _} = call("shop.search_products", %{"price_max" => String.duplicate("0", 40)})

    for name <- ["price_min", "price_max"] do
      assert {422, body, _} =
               call("shop.search_products", %{name => String.duplicate("0", 41)})

      assert [%{"path" => ^name, "limit" => 40}] = body["context"]["errors"]
    end
  end

  test "an option key is counted in bytes before graphemes: a string of marks is refused, never walked" do
    marks = fn n -> "a" <> String.duplicate("\u0301", n) end

    # 1 grapheme but 901 bytes: over 4 bytes per allowed character
    for key <- [marks.(450), marks.(900_000)] do
      assert {422, body, _} = call("shop.search_products", %{"options" => %{key => ["x"]}})
      assert [%{"path" => "options"}] = body["context"]["errors"]
    end

    # 200 two-byte characters are within the limit
    assert {200, _, _} =
             call("shop.search_products", %{"options" => %{String.duplicate("é", 200) => ["x"]}})
  end

  test "an option key echoed in an error path is cut at 64 bytes, as core cuts its own" do
    key = String.duplicate("k", 150)

    assert {422, body, _} =
             call("shop.search_products", %{"options" => %{key => ["a" <> <<0>> <> "b"]}})

    assert [%{"path" => path}] = body["context"]["errors"]
    assert path == "options." <> String.duplicate("k", 64) <> "..."

    assert {200, %{"results" => [%{"error" => error}]}, _} =
             call("shop.search_products_batch", %{
               "queries" => [%{"options" => %{key => ["a" <> <<0>> <> "b"]}}]
             })

    assert [%{"path" => batch_path}] = error["context"]["errors"]
    assert batch_path == "queries[0].options." <> String.duplicate("k", 64) <> "..."
  end

  test "schema errors name the field: a limit of 0, a field that is not an item field" do
    assert {422, body, _} = call("shop.search_products", %{"limit" => 0})
    assert [%{"path" => "limit"}] = body["context"]["errors"]

    assert {422, body, _} = call("shop.search_products", %{"fields" => ["cost_per_item"]})
    assert [%{"path" => "fields[0]"}] = body["context"]["errors"]
  end

  test "the executor enforces the batch caps before any handler runs" do
    assert {422, body, _} =
             call("shop.search_products_batch", %{"queries" => List.duplicate(%{}, 21)})

    assert [%{"path" => "queries"}] = body["context"]["errors"]

    ids = List.duplicate(Ecto.UUID.generate(), 51)
    assert {422, body, _} = call("shop.get_products", %{"ids" => ids})
    assert [%{"path" => "ids"}] = body["context"]["errors"]

    assert {422, _, _} = call("shop.search_products_batch", %{"queries" => []})
  end

  test "the tool's own item cap answers before the schema looks at the items" do
    # 21 queries that are each invalid: the cap is one error on the list, not 21 item errors.
    bad = List.duplicate(%{"bogus" => 1}, 21)

    assert {422, body, _} = call("shop.search_products_batch", %{"queries" => bad})
    assert [%{"path" => "queries", "limit" => 20}] = body["context"]["errors"]

    bad_ids = List.duplicate(1, 51)
    assert {422, body, _} = call("shop.get_products", %{"ids" => bad_ids})
    assert [%{"path" => "ids", "limit" => 50}] = body["context"]["errors"]
  end

  test "a schema-level problem in one batch query fails the whole call and names the query" do
    assert {422, body, _} =
             call("shop.search_products_batch", %{
               "queries" => [%{"q" => "vase"}, %{"limit" => 0}]
             })

    assert [%{"path" => "queries[1].limit"}] = body["context"]["errors"]
  end

  test "get_products hides what is hidden: a draft and an unknown id answer alike" do
    draft = legacy_product!(%{"en" => "Draft Lamp"}, %{status: "draft"})

    {200, body, _} =
      call("shop.get_products", %{"ids" => [draft.uuid, Ecto.UUID.generate()]})

    assert [%{"error" => first}, %{"error" => second}] = body["results"]
    assert first == second
    assert body["summary"] == %{"found" => 0, "discontinued" => 0, "not_found" => 2}
  end

  test "list_categories and similar_products answer through the executor", t do
    assert {200, %{"categories" => [%{"name" => "Home", "total_count" => 3}]}, _} =
             call("shop.list_categories", %{})

    assert {200, %{"items" => items}, _} = call("shop.similar_products", %{"id" => t.a})
    assert Enum.map(items, & &1["id"]) == [t.c, t.d]

    assert {404, %{"code" => "not_found"}, _} =
             call("shop.similar_products", %{"id" => Ecto.UUID.generate()})
  end

  test "an unknown tool is 404 not_found; with the shop module disabled it is 404 module_disabled" do
    assert {404, %{"code" => "not_found"}, _} = call("shop.no_such_tool", %{})

    {:ok, _} = Settings.update_setting("shop_enabled", "false")
    assert {404, %{"code" => "module_disabled"}, _} = call("shop.search_products", %{})
  end

  test "a batch of 20 queries costs 20 units: the second batch from one address is refused" do
    wait_for_window_room()
    {:ok, _} = Settings.update_setting("api_public_ip_rate_per_min", "25")
    ip = {10, 9, 9, 9}
    twenty = %{"queries" => List.duplicate(%{"q" => "vase"}, 20)}

    assert {200, %{"count" => 20}, _} = call("shop.search_products_batch", twenty, ip)

    assert {429, %{"code" => "rate_limited"}, _} = call("shop.search_products_batch", twenty, ip)
  end

  test "GET discovery lists the read tools with their schemas" do
    conn =
      :get
      |> Plug.Test.conn("/api/shop/v1/")
      |> Map.put(:remote_ip, {10, 1, 2, 3})
      |> Executor.list(:public)

    assert conn.status == 200
    body = JSON.decode!(conn.resp_body)
    names = body["tools"] |> Enum.map(& &1["name"])

    # The cart tools of the same module are listed beside the five read tools.
    assert ~w(shop.get_products shop.list_categories shop.search_products shop.search_products_batch shop.similar_products) --
             names == []

    search = Enum.find(body["tools"], &(&1["name"] == "shop.search_products"))
    assert search["input_schema"]["additionalProperties"] == false
    assert search["annotations"]["read_only"] == true
  end
end
