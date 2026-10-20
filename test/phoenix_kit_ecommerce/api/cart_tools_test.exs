defmodule PhoenixKitEcommerce.API.CartToolsTest do
  @moduledoc "The definitions of the seven cart tools, and that the module offers them."

  use PhoenixKitEcommerce.DataCase, async: false
  @moduletag :requires_core_api

  # Core's API modules exist only in the core that carries the shop API; this file is
  # compiled (and its tests excluded) against a core that has none, so they are named
  # at run time only and the tools are matched as plain maps.
  @compile {:no_warn_undefined,
            [
              PhoenixKit.API.Executor,
              PhoenixKit.API.Registry,
              PhoenixKit.API.ToolLint,
              {PhoenixKit.ModuleRegistry, :all_api_tools, 0}
            ]}

  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.ModuleRegistry
  alias PhoenixKitEcommerce.API.CartHandlers
  alias PhoenixKitEcommerce.API.CartTools

  @names ~w(
    shop.create_cart shop.get_cart shop.set_cart_items shop.clear_cart
    shop.get_shipping_options shop.set_shipping shop.get_checkout_link
  )

  test "there are exactly the seven public cart tools" do
    tools = CartTools.tools()

    assert Enum.map(tools, & &1.name) == @names
    assert Enum.all?(tools, &match?(%{audience: :public, scope: nil, permission: nil}, &1))
    assert Enum.all?(tools, &(&1.title not in [nil, ""] and &1.description not in [nil, ""]))
  end

  test "core builds all seven and its own module-author check passes" do
    assert length(CartTools.tools(true)) == 7
    assert :ok = ToolLint.check_tools(CartTools.tools(true))
  end

  test "every handler exists with the (input, ctx) arity" do
    for %{handler: {module, fun}} <- CartTools.tools() do
      assert Code.ensure_loaded?(module) and function_exported?(module, fun, 2),
             "#{inspect(module)}.#{fun}/2 is missing"
    end
  end

  test "annotations tell agents which tools read, which change, which destroy" do
    by_name = Map.new(CartTools.tools(), &{&1.name, &1.annotations})

    for read <- ["shop.get_cart", "shop.get_shipping_options"] do
      assert %{read_only: true, destructive: false} = by_name[read]
    end

    for write <- [
          "shop.create_cart",
          "shop.set_cart_items",
          "shop.set_shipping",
          "shop.get_checkout_link"
        ] do
      assert %{read_only: false, destructive: false} = by_name[write]
    end

    assert %{read_only: false, destructive: true, idempotent: true} = by_name["shop.clear_cart"]
    assert Enum.all?(Map.values(by_name), &(&1.open_world == false))
  end

  test "gate_available? looks at the exported marker, and without the gate shop.clear_cart is withheld" do
    assert CartTools.gate_available?(), "the core under test lacks the confirmation gate"

    assert "shop.clear_cart" in Enum.map(CartTools.tools(true), & &1.name)

    without = CartTools.tools(false)
    refute "shop.clear_cart" in Enum.map(without, & &1.name)
    assert length(without) == 6
    assert Enum.all?(without, &is_nil(&1.danger))
  end

  test "clear_cart asks for confirmation when there is something to clear, the others never do" do
    danger = Map.new(CartTools.tools(), &{&1.name, &1.danger})

    assert danger["shop.clear_cart"] == {CartHandlers, :clear_needs_confirmation?}
    assert danger |> Map.delete("shop.clear_cart") |> Map.values() |> Enum.all?(&is_nil/1)
  end

  test "set_cart_items caps a request at 50 lines and the schema allows a bad quantity through to the line check" do
    tool = Enum.find(CartTools.tools(), &(&1.name == "shop.set_cart_items"))

    assert tool.max_items == 50
    items = tool.input_schema["properties"]["items"]
    assert items["maxItems"] == 50 and items["minItems"] == 1
    assert items["items"]["required"] == ["product_id"]
    refute Map.has_key?(items["items"]["properties"]["quantity"], "type")
  end

  test "set_cart_items costs one unit per ten lines, at most ten, whatever the input" do
    tool = Enum.find(CartTools.tools(), &(&1.name == "shop.set_cart_items"))
    lines = fn n -> %{"items" => List.duplicate(%{}, n)} end

    assert Executor.cost(tool, lines.(1)) == 1
    assert Executor.cost(tool, lines.(9)) == 1
    assert Executor.cost(tool, lines.(10)) == 2
    assert Executor.cost(tool, lines.(50)) == 6
    assert Executor.cost(tool, lines.(5000)) == 10

    for junk <- [%{}, %{"items" => "x"}, %{"items" => nil}] do
      assert Executor.cost(tool, junk) == 1
    end
  end

  test "every cart tool takes the cart token and nothing the executor adds itself" do
    for tool <- CartTools.tools(), tool.name != "shop.create_cart" do
      assert "cart_token" in tool.input_schema["required"], tool.name
      refute Map.has_key?(tool.input_schema["properties"], "dry_run"), tool.name
      refute Map.has_key?(tool.input_schema["properties"], "confirm_token"), tool.name
      refute Map.has_key?(tool.input_schema["properties"], "idempotency_key"), tool.name
    end
  end

  test "the tools that take the cart token declare it as the client token, the checkout link as a credential" do
    tools = Map.new(CartTools.tools(), &{&1.name, &1})

    if Map.has_key?(struct(PhoenixKit.API.Tool), :client_token) do
      for {name, tool} <- tools, name != "shop.create_cart" do
        assert tool.client_token == "cart_token", name
      end

      assert tools["shop.create_cart"].client_token == nil
      assert tools["shop.get_checkout_link"].credentials == ["url"]

      for {name, tool} <- tools, name != "shop.get_checkout_link" do
        assert tool.credentials == [], name
      end
    else
      # A core before the module-neutral API rejects the fields, so the tools carry neither.
      for {_name, tool} <- tools, do: refute(Map.has_key?(tool, :client_token))
    end
  end

  test "every cart tool declares the shared language and currency control fields" do
    for tool <- CartTools.tools() do
      properties = tool.input_schema["properties"]

      assert Map.has_key?(properties, "language"), tool.name
      assert Map.has_key?(properties, "currency"), tool.name
    end
  end

  test "schemas stay inside what the validator checks (no oneOf, anyOf, const, $ref, format)" do
    banned = ~w(oneOf anyOf allOf const $ref format not)

    for tool <- CartTools.tools(), schema <- [tool.input_schema, tool.output_schema] do
      assert keys_in(schema) -- banned == keys_in(schema),
             "#{tool.name} uses a keyword the validator ignores"
    end
  end

  test "the module offers them while it is enabled, to the registry and to find/2" do
    names = ModuleRegistry.all_api_tools() |> Enum.map(& &1.name)
    for name <- @names, do: assert(name in names, "#{name} is not offered")

    assert {:ok, %{name: "shop.get_cart", audience: :public}} =
             Registry.find("shop.get_cart", :public)

    assert {:error, :not_found} = Registry.find("shop.get_cart", :admin)
  end

  test "the module declares the error codes of the cart API, with core's advice texts" do
    problems = PhoenixKitEcommerce.api_problems()

    assert Map.keys(problems) |> Enum.sort() ==
             [:cart_locked, :cart_not_found, :insufficient_stock, :unsupported_source]

    assert %{status: 404, title: "Cart not found"} = problems.cart_not_found
    assert %{status: 409, title: "Cart locked"} = problems.cart_locked
    assert %{status: 422, title: "Unsupported source"} = problems.unsupported_source
    assert %{status: 422, title: "Insufficient stock"} = problems.insufficient_stock

    for {code, problem} <- problems do
      assert is_binary(problem.advice) and problem.advice != "", inspect(code)
    end
  end

  test "core collects them from the module while it is enabled" do
    if function_exported?(ModuleRegistry, :all_api_problems, 0) do
      declared = ModuleRegistry.all_api_problems()

      for {code, problem} <- PhoenixKitEcommerce.api_problems() do
        assert declared[code] == problem, inspect(code)
      end
    end
  end

  defp keys_in(schema) when is_map(schema) do
    Enum.flat_map(schema, fn {key, value} -> [to_string(key) | keys_in(value)] end)
  end

  defp keys_in(list) when is_list(list), do: Enum.flat_map(list, &keys_in/1)
  defp keys_in(_other), do: []
end
