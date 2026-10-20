if Code.ensure_loaded?(PhoenixKit.API.MCP) do
  defmodule PhoenixKitEcommerce.API.PublicTransportsTest do
    @moduledoc """
    Every public tool through both transports, one success and one error
    each. The two transports are called at plug level (the router's
    `forward` leaves them the path after `/api/public/v1` and `/mcp/public`), the
    way core's own transport tests call them, with a real rate limiter and the
    real settings. A request without an `Origin` header passes the MCP Origin
    check (a browser always sends one; a native client does not).

    `async: false`: Billing's currency cache and the limiter table are node-global.
    """
    use PhoenixKitEcommerce.DataCase, async: false

    @moduletag :requires_core_api

    import PhoenixKitEcommerce.SearchFixtures
    import Plug.Conn

    alias PhoenixKit.API.MCP
    alias PhoenixKit.API.REST
    alias PhoenixKit.Settings

    @tools ~w(shop.search_products shop.search_products_batch shop.get_products
              shop.list_categories shop.similar_products)

    setup do
      disable_languages!()
      currencies!()
      {:ok, _} = Settings.update_setting("api_public_enabled", "true")
      sample_shop!()
    end

    # A fresh peer address per request: the limiter counters are shared.
    defp peer, do: {10, 7, rem(System.unique_integer([:positive]), 250), :rand.uniform(250)}

    defp rest(tool, input) do
      conn =
        :post
        |> Plug.Test.conn("/" <> tool, input)
        |> Map.put(:remote_ip, peer())
        |> REST.call(REST.init(audience: :public))

      {conn.status, JSON.decode!(conn.resp_body)}
    end

    defp mcp(method, params) do
      body = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

      conn =
        :post
        |> Plug.Test.conn("/", body)
        |> Map.put(:remote_ip, peer())
        |> put_req_header("accept", "application/json")
        |> put_req_header("mcp-protocol-version", "2025-06-18")
        |> MCP.call(MCP.init(audience: :public))

      {conn.status, JSON.decode!(conn.resp_body)["result"]}
    end

    defp mcp_call(tool, arguments),
      do: mcp("tools/call", %{"name" => String.replace(tool, ".", "_"), "arguments" => arguments})

    # The failure, as an agent reads it: the second text item of an `isError` result.
    defp mcp_problem(result),
      do: result |> Map.fetch!("content") |> Enum.at(1) |> Map.fetch!("text") |> JSON.decode!()

    defp success_case("shop.search_products", _t), do: {%{"q" => "vase"}, &(&1["count"] == 3)}

    defp success_case("shop.search_products_batch", _t),
      do: {%{"queries" => [%{"q" => "vase"}, %{"q" => "bowl"}]}, &(&1["count"] == 2)}

    defp success_case("shop.get_products", t),
      do:
        {%{"ids" => [t.a]},
         &(&1["summary"] == %{"found" => 1, "discontinued" => 0, "not_found" => 0})}

    defp success_case("shop.list_categories", _t),
      do: {%{}, &match?(%{"categories" => [%{"name" => "Home", "total_count" => 3}]}, &1)}

    defp success_case("shop.similar_products", t),
      do: {%{"id" => t.a}, &(Enum.map(&1["items"], fn item -> item["id"] end) == [t.c, t.d])}

    for tool <- @tools do
      test "#{tool}: a success is 200 over REST, and MCP returns the same JSON as structured content",
           t do
        {input, check} = success_case(unquote(tool), t)

        assert {200, rest_body} = rest(unquote(tool), input)
        assert check.(rest_body), inspect(rest_body)

        assert {200, result} = mcp_call(unquote(tool), input)
        assert result["isError"] == false
        assert result["structuredContent"] == rest_body
      end

      test "#{tool}: an error is 422 validation_failed over REST and an isError result over MCP" do
        assert {422, %{"code" => "validation_failed"}} = rest(unquote(tool), %{"bogus" => 1})

        assert {200, result} = mcp_call(unquote(tool), %{"bogus" => 1})
        assert result["isError"] == true
        assert %{"code" => "validation_failed"} = mcp_problem(result)
      end
    end

    test "a domain-level error crosses both transports with the same code", _t do
      id = Ecto.UUID.generate()

      assert {404, %{"code" => "not_found"}} = rest("shop.similar_products", %{"id" => id})

      assert {200, result} = mcp_call("shop.similar_products", %{"id" => id})
      assert result["isError"] == true
      assert %{"code" => "not_found"} = mcp_problem(result)
    end

    test "a problem the handler finds in the input crosses both transports the same way, tool by tool" do
      # search_products: the handler refuses the whole call.
      bad = %{"category_id" => "not-a-uuid"}

      assert {422, %{"code" => "validation_failed", "context" => %{"errors" => [rest_error]}}} =
               rest("shop.search_products", bad)

      assert {200, result} = mcp_call("shop.search_products", bad)
      assert result["isError"] == true

      assert %{"code" => "validation_failed", "context" => %{"errors" => [mcp_error]}} =
               mcp_problem(result)

      assert rest_error["path"] == "category_id" and mcp_error["path"] == "category_id"

      # The batch and get_products answer 200 with the problem inside the row.
      for {tool, input, row_path, code} <- [
            {"shop.search_products_batch", %{"queries" => [%{"q" => "vase"}, bad]},
             ["results", Access.at(1), "error", "code"], "validation_failed"},
            {"shop.get_products", %{"ids" => ["not-a-uuid"]},
             ["results", Access.at(0), "error", "code"], "not_found"}
          ] do
        assert {200, rest_body} = rest(tool, input)
        assert get_in(rest_body, row_path) == code

        assert {200, result} = mcp_call(tool, input)
        assert result["isError"] == false
        assert result["structuredContent"] == rest_body
      end
    end

    test "tools/list on the public MCP endpoint offers the five tools under their MCP names" do
      assert {200, %{"tools" => tools}} = mcp("tools/list", %{})
      names = Enum.map(tools, & &1["name"])

      for tool <- @tools, do: assert(String.replace(tool, ".", "_") in names, tool)
    end
  end
end
