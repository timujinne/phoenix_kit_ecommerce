defmodule PhoenixKitEcommerce.API.PublicToolsTest do
  @moduledoc """
  The tool declarations: shape, schemas and registration through core.
  Needs a core with the shop API (`PhoenixKit.API.Tool`, `Registry`).
  """
  use PhoenixKitEcommerce.DataCase, async: true

  @moduletag :requires_core_api

  @compile {:no_warn_undefined,
            [PhoenixKit.API.Registry, PhoenixKit.API.Tool, PhoenixKit.API.ToolLint]}

  import ExUnit.CaptureLog

  alias PhoenixKit.API.Registry
  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.ToolLint
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.API.Public.Catalog
  alias PhoenixKitEcommerce.API.Public.Search
  alias PhoenixKitEcommerce.API.PublicTools

  @names ~w(shop.get_products shop.list_categories shop.search_products
            shop.search_products_batch shop.similar_products)

  # The validator supports only these keywords (plus the annotation keywords
  # title, default, examples, format, which the schemas here do not use).
  # Core's Tool.new/1 refuses any other keyword, or, on a core that only ignores
  # them, a schema that relies on one (oneOf, $ref ...) would silently validate
  # nothing. This test fails with a clear message in both cases.
  @keywords ~w(type required properties additionalProperties enum minimum maximum
               minLength maxLength minItems maxItems items pattern description)

  defp tools, do: PublicTools.tools()

  defp check_schema(schema, path) do
    for {key, value} <- schema do
      assert key in @keywords,
             "#{path}: keyword #{inspect(key)} is not understood by the validator"

      check_nested(key, value, path)
    end

    :ok
  end

  defp check_nested("properties", props, path),
    do: for({name, sub} <- props, do: check_schema(sub, "#{path}.#{name}"))

  defp check_nested("items", sub, path) when is_map(sub), do: check_schema(sub, "#{path}[]")

  defp check_nested("additionalProperties", sub, path) when is_map(sub),
    do: check_schema(sub, "#{path}.*")

  defp check_nested(_key, _value, _path), do: :ok

  test "PublicTools.tools/0 is the five public read tools, all valid, none dropped" do
    assert length(tools()) == 5
    assert tools() |> Enum.map(& &1.name) |> Enum.sort() == @names
    assert Enum.all?(tools(), &match?({:ok, _}, Tool.validate(&1)))
  end

  test "a tool core refuses is left out and logged once, however often the tools are asked for" do
    name = "shop.refused_#{System.unique_integer([:positive])}"
    on_exit(fn -> :persistent_term.erase({PublicTools, :refused, name}) end)

    # No handler, no schemas: core's Tool.new/1 refuses it.
    refused = [name: name, audience: :public, title: "Refused tool", description: "Nothing."]

    log =
      capture_log(fn ->
        for _ <- 1..5, do: assert(PublicTools.build_all([refused]) == [])
      end)

    assert length(String.split(log, "public tool #{name} is invalid")) == 2
  end

  test "core's module-author lint passes on the set" do
    assert ToolLint.check_tools(tools()) == :ok
  end

  test "they are public, read-only, idempotent and need neither scope nor permission" do
    for tool <- tools() do
      assert tool.audience == :public
      assert tool.scope == nil and tool.permission == nil
      assert tool.danger == nil

      assert tool.annotations == %{
               read_only: true,
               destructive: false,
               idempotent: true,
               open_world: false
             }
    end
  end

  test "batch inputs are capped: 20 queries, 50 ids" do
    caps = Map.new(tools(), &{&1.name, &1.max_items})

    assert caps["shop.search_products_batch"] == 20
    assert caps["shop.get_products"] == 50
    assert caps["shop.search_products"] == nil
  end

  test "the batch tools are priced through the declarative cost: a query, ten ids" do
    costs = Map.new(tools(), &{&1.name, &1.cost})

    assert costs["shop.search_products_batch"] ==
             {PhoenixKitEcommerce.API.Public.Search, :batch_cost}

    assert costs["shop.get_products"] ==
             {PhoenixKitEcommerce.API.Public.Catalog, :get_products_cost}

    assert costs
           |> Map.drop(["shop.search_products_batch", "shop.get_products"])
           |> Map.values()
           |> Enum.uniq() == [nil]
  end

  test "every input schema is closed and declares language and currency" do
    for tool <- tools() do
      assert tool.input_schema["type"] == "object"
      assert tool.input_schema["additionalProperties"] == false, tool.name
      assert Map.has_key?(tool.input_schema["properties"], "language"), tool.name
      assert Map.has_key?(tool.input_schema["properties"], "currency"), tool.name
    end
  end

  # Read from the schema functions, not from the built tools: a tool core refused
  # is left out of `tools/0`, and a loop over the built tools would then check nothing.
  test "every schema stays inside the keywords core's validator understands" do
    schemas = [
      {"search input", Search.search_input_schema()},
      {"search output", Search.search_output_schema()},
      {"batch input", Search.batch_input_schema()},
      {"batch output", Search.batch_output_schema()},
      {"get_products input", Catalog.get_products_input_schema()},
      {"get_products output", Catalog.get_products_output_schema()},
      {"list_categories input", Catalog.list_categories_input_schema()},
      {"list_categories output", Catalog.list_categories_output_schema()},
      {"similar_products input", Catalog.similar_products_input_schema()},
      {"similar_products output", Catalog.similar_products_output_schema()}
    ]

    for {label, schema} <- schemas, do: check_schema(schema, label)
  end

  test "every tool has a title and a description an agent can use" do
    for tool <- tools() do
      assert String.length(tool.title) >= 8, tool.name
      assert String.length(tool.description) >= 60, tool.name
    end
  end

  test "core's registry finds each tool, tagged with this module" do
    for name <- @names do
      # a map pattern, not %Tool{}: it matches the struct without needing it at compile time
      assert {:ok, %{name: ^name, module: PhoenixKitEcommerce}} = Registry.find(name, :public)
    end

    visible = :public |> Registry.visible_tools(:all) |> Enum.map(& &1.name)
    assert @names -- visible == []
  end

  test "while the shop module is disabled its tools answer module_disabled" do
    {:ok, _} = Settings.update_setting("shop_enabled", "false")

    for name <- @names do
      assert Registry.find(name, :public) == {:error, :module_disabled}
    end
  end
end
