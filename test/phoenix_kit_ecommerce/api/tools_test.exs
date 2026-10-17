defmodule PhoenixKitEcommerce.API.ToolsTest do
  @moduledoc """
  What the module hands to core's tool registry: the tools, their scopes and
  permissions, schemas that core's own validator accepts and that accept what
  they should and refuse what they should, and the rule that the write tools
  exist only on a core that can hold a dangerous call for confirmation.

  Needs core's tool registry: tagged `:core_api`. The tests of the write tools
  are tagged `:core_confirm` (core also has the confirmation flow); the one
  that pins the reduced list is `:core_no_confirm`.
  `test_helper.exs` excludes what does not apply to the core in use.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :core_api

  @compile {:no_warn_undefined,
            [PhoenixKit.API.Tool, PhoenixKit.API.Executor, PhoenixKit.API.ToolLint]}

  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Tool
  alias PhoenixKit.API.ToolLint

  @uuid "0192a7c0-0000-7000-8000-000000000001"
  @row %{"ref" => %{"sku" => "A"}}

  # The e-commerce (admin) tools as `api_tools/0` hands them over: it carries
  # the public read and cart tools next to them.
  defp tools do
    for tool <- PhoenixKitEcommerce.api_tools(),
        String.starts_with?(tool.name, "ecommerce."),
        into: %{},
        do: {tool.name, tool}
  end

  # `function_exported?/3` does not load the module, and the handlers of the
  # public tools are not loaded until a call reaches them.
  defp assert_exported(module, function, label) do
    assert Code.ensure_loaded?(module) and function_exported?(module, function, 2),
           "#{label} missing"
  end

  defp validate(tool_name, input) do
    tool = Map.fetch!(tools(), tool_name)
    Executor.validate_input(tool, input)
  end

  describe "the read tool" do
    test "is registered with the read scope and permission, read-only, capped at 500 rows" do
      tool = tools()["ecommerce.get_prices"]

      assert {tool.scope, tool.permission, tool.audience} ==
               {"ecommerce.prices:read", "shop", :admin}

      assert tool.annotations.read_only
      refute tool.annotations.destructive
      assert tool.max_items == 500
      assert tool.danger == nil
    end

    test "accepts refs by id, sku and external_id" do
      input = %{"refs" => [%{"id" => @uuid}, %{"sku" => "A-1"}, %{"external_id" => "ERP-1"}]}
      assert {:ok, _} = validate("ecommerce.get_prices", input)
    end

    test "refuses an empty sku or external_id (a blank one is the handler's to refuse)" do
      for key <- ["sku", "external_id"] do
        assert {:error, _} = validate("ecommerce.get_prices", %{"refs" => [%{key => ""}]})
        assert {:ok, _} = validate("ecommerce.get_prices", %{"refs" => [%{key => " "}]})
      end
    end

    test "refuses no refs, a malformed id, an unknown field and a control field" do
      assert {:error, _} = validate("ecommerce.get_prices", %{"refs" => []})
      assert {:error, _} = validate("ecommerce.get_prices", %{"refs" => [%{"id" => "nope"}]})

      assert {:error, _} =
               validate("ecommerce.get_prices", %{"refs" => [%{"sku" => "a", "colour" => "red"}]})

      assert {:error, _} =
               validate("ecommerce.get_prices", %{"refs" => [%{"sku" => "a"}], "dry_run" => true})
    end
  end

  describe "the confirmation markers" do
    test "a core that lacks any marker is not one that can hold a dangerous call" do
      assert PhoenixKitEcommerce.API.confirmation_available?([{Enum, :map, 2}])
      refute PhoenixKitEcommerce.API.confirmation_available?([{Enum, :no_such_function, 1}])
      refute PhoenixKitEcommerce.API.confirmation_available?([{NoSuchModule, :gate, 1}])

      refute PhoenixKitEcommerce.API.confirmation_available?([
               {Enum, :map, 2},
               {NoSuchModule, :gate, 1}
             ])
    end

    test "no markers at all is not evidence that core can hold a dangerous call" do
      refute PhoenixKitEcommerce.API.confirmation_available?([])
    end

    test "with a marker missing only the read tool is offered" do
      for markers <- [[], [{NoSuchModule, :gate, 1}], [{Enum, :map, 2}, {Enum, :nope, 9}]] do
        assert ["ecommerce.get_prices"] ==
                 markers |> PhoenixKitEcommerce.API.tools() |> Enum.map(& &1.name)
      end
    end

    test "the default markers are core's key check and its enforcement gate" do
      assert PhoenixKitEcommerce.API.markers() == [
               {PhoenixKit.API.Keys, :active?, 1},
               {PhoenixKit.API.Flow, :gate, 1}
             ]
    end
  end

  describe "without core's confirmation flow" do
    @describetag :core_no_confirm

    test "only the read tool is offered: a write tool would run a 90 percent price cut on the first call" do
      assert Map.keys(tools()) == ["ecommerce.get_prices"]
    end
  end

  describe "with core's confirmation flow" do
    @describetag :core_confirm

    test "with every marker present the write tools are offered" do
      names = [{Enum, :map, 2}] |> PhoenixKitEcommerce.API.tools() |> Enum.map(& &1.name)

      assert Enum.sort(names) ==
               ~w(ecommerce.attach_images ecommerce.detach_images ecommerce.get_prices ecommerce.set_availability ecommerce.set_prices)
    end

    test "all five tools are offered, with the documented scopes and permissions" do
      table =
        Map.new(tools(), fn {name, tool} ->
          {name, {tool.scope, tool.permission, tool.audience}}
        end)

      assert table == %{
               "ecommerce.get_prices" => {"ecommerce.prices:read", "shop", :admin},
               "ecommerce.set_prices" =>
                 {"ecommerce.prices:write", "shop.manage_catalog", :admin},
               "ecommerce.set_availability" =>
                 {"ecommerce.availability:write", "shop.manage_catalog", :admin},
               "ecommerce.attach_images" =>
                 {"ecommerce.images:write", "shop.manage_catalog", :admin},
               "ecommerce.detach_images" =>
                 {"ecommerce.images:write", "shop.manage_catalog", :admin}
             }
    end

    test "core's tool lint passes for the whole set" do
      assert :ok = ToolLint.check_tools(PhoenixKitEcommerce.api_tools())
    end

    test "the write tools' descriptions name every transient reason they can answer with" do
      for name <- [
            "ecommerce.set_prices",
            "ecommerce.set_availability",
            "ecommerce.attach_images",
            "ecommerce.detach_images"
          ],
          reason <- ["database_error", "storage_error", "unexpected"] do
        assert tools()[name].description =~ reason, "#{name} does not mention #{reason}"
      end
    end

    test "the read tool can answer with unexpected (a ref lookup can fail), so it carries the retry note" do
      for reason <- ["database_error", "storage_error", "unexpected"] do
        assert tools()["ecommerce.get_prices"].description =~ reason
      end
    end

    test "every tool is valid for core and every handler and danger function is exported" do
      for tool <- PhoenixKitEcommerce.api_tools() do
        assert {:ok, _} = Tool.validate(tool)
        {module, function} = tool.handler
        assert_exported(module, function, "#{tool.name}: #{function}/2")

        case tool.danger do
          nil -> :ok
          {m, f} -> assert_exported(m, f, "#{tool.name}: #{f}/2")
        end
      end
    end

    test "set_prices is destructive and dangerous by value, attach_images reaches the open world" do
      tools = tools()

      assert tools["ecommerce.set_prices"].annotations.destructive
      assert tools["ecommerce.set_prices"].danger == {PhoenixKitEcommerce.API, :set_prices_danger}

      # the size of a batch is core's rule: no other tool has a danger function
      assert tools["ecommerce.set_availability"].danger == nil
      assert tools["ecommerce.attach_images"].danger == nil
      refute tools["ecommerce.set_availability"].annotations.destructive
      assert tools["ecommerce.attach_images"].annotations.open_world
      refute tools["ecommerce.set_prices"].annotations.open_world
    end

    test "detach_images is destructive and idempotent, held when it would empty a gallery" do
      tool = tools()["ecommerce.detach_images"]

      assert tool.annotations.destructive
      assert tool.annotations.idempotent
      refute tool.annotations.open_world
      assert tool.danger == {PhoenixKitEcommerce.API, :detach_images_danger}
      assert tool.max_items == 500
    end

    test "detach_images accepts a picture by id or by url and refuses an unknown field" do
      id = %{"id" => @uuid}
      url = %{"url" => "https://cdn.example.com/a.png"}

      assert {:ok, _} =
               validate("ecommerce.detach_images", %{
                 "items" => [Map.put(@row, "images", [id, url])]
               })

      assert {:error, _} =
               validate("ecommerce.detach_images", %{
                 "items" => [Map.put(@row, "images", [%{"id" => "nope"}])]
               })

      assert {:error, _} =
               validate("ecommerce.detach_images", %{
                 "items" => [Map.put(@row, "images", [%{"all" => true}])]
               })

      assert {:error, _} =
               validate("ecommerce.detach_images", %{"items" => [Map.put(@row, "images", [])]})
    end

    test "attach_images is priced by its pictures when core has the cost field" do
      tool = tools()["ecommerce.attach_images"]

      if Map.has_key?(tool, :cost) do
        assert tool.cost == {PhoenixKitEcommerce.API.AttachImages, :cost}
      end
    end

    test "batch caps are 500 rows and 20 pictures" do
      tools = tools()
      assert tools["ecommerce.set_prices"].max_items == 500
      assert tools["ecommerce.set_availability"].max_items == 500
      assert tools["ecommerce.attach_images"].max_items == 20
    end

    test "set_prices accepts the documented shapes" do
      input = %{
        "items" => [
          %{"ref" => %{"sku" => "A"}, "price" => "12.50"},
          %{"ref" => %{"sku" => "B"}, "compare_at" => nil},
          %{
            "ref" => %{"id" => @uuid},
            "price" => "0",
            "price_modifiers" => %{"color" => %{"black" => "-2.00", "blue" => nil}}
          }
        ]
      }

      assert {:ok, _} = validate("ecommerce.set_prices", input)
    end

    test "set_prices refuses prices a client could mean differently" do
      for bad <- ["12,50", "12.505", "-1", "1e3", " 12.50", "12.50\n", 12.5, nil] do
        input = %{"items" => [Map.put(@row, "price", bad)]}
        assert {:error, [%{path: "items[0].price"}]} = validate("ecommerce.set_prices", input)
      end
    end

    test "set_prices refuses a bad modifier, the catalogue's own price fields, and 501 rows" do
      assert {:error, [%{path: path}]} =
               validate("ecommerce.set_prices", %{
                 "items" => [Map.put(@row, "price_modifiers", %{"c" => %{"x" => "abc"}})]
               })

      assert path =~ "price_modifiers"

      for field <- [
            "base_price",
            "markup_percentage",
            "discount_percentage",
            "data",
            "cost_per_item"
          ] do
        input = %{"items" => [@row |> Map.put("price", "1.00") |> Map.put(field, "5")]}
        assert {:error, _} = validate("ecommerce.set_prices", input), "#{field} must be refused"
      end

      rows = for _ <- 1..501, do: Map.put(@row, "price", "1.00")
      assert {:error, _} = validate("ecommerce.set_prices", %{"items" => rows})
    end

    test "availability accepts the three visibilities and refuses another" do
      for visibility <- ["draft", "active", "archived"] do
        input = %{"items" => [Map.put(@row, "visibility", visibility)]}
        assert {:ok, _} = validate("ecommerce.set_availability", input)
      end

      assert {:error, [%{path: "items[0].visibility", allowed: allowed}]} =
               validate("ecommerce.set_availability", %{
                 "items" => [Map.put(@row, "visibility", "hidden")]
               })

      assert allowed == ["draft", "active", "archived"]
    end

    test "images accept http(s) URLs and refuse other schemes, more than 20 per row, and none" do
      ok = %{
        "items" => [
          Map.put(@row, "images", [%{"url" => "https://cdn.example/a.png", "featured" => true}])
        ]
      }

      assert {:ok, _} = validate("ecommerce.attach_images", ok)

      # an @ after the host is not a credential
      for url <- [
            "https://cdn.example",
            "https://cdn.example/a@b.png",
            "https://cdn.example?u=a@b"
          ] do
        input = %{"items" => [Map.put(@row, "images", [%{"url" => url}])]}
        assert {:ok, _} = validate("ecommerce.attach_images", input), "#{url} must be accepted"
      end

      for url <- [
            "file:///etc/passwd",
            "ftp://x/y.png",
            "//cdn.example/a.png",
            "https://user:secret@cdn.example/a.png",
            "https://token@cdn.example/a.png",
            "https://@cdn.example/a.png",
            "https://cdn.example@evil.example/a.png"
          ] do
        input = %{"items" => [Map.put(@row, "images", [%{"url" => url}])]}
        assert {:error, _} = validate("ecommerce.attach_images", input), "#{url} must be refused"
      end

      many = for n <- 1..21, do: %{"url" => "https://cdn.example/#{n}.png"}

      assert {:error, _} =
               validate("ecommerce.attach_images", %{"items" => [Map.put(@row, "images", many)]})

      assert {:error, _} =
               validate("ecommerce.attach_images", %{"items" => [Map.put(@row, "images", [])]})
    end

    test "the write descriptions mention the Shopify sync warning only while it is on" do
      names = ["ecommerce.set_prices", "ecommerce.set_availability", "ecommerce.attach_images"]

      for name <- names do
        refute tools()[name].description =~ "shopify_sync_may_overwrite", "#{name} while off"
      end

      enable_shopify!()

      for name <- names do
        assert tools()[name].description =~ "shopify_sync_may_overwrite", "#{name} while on"
      end

      refute tools()["ecommerce.get_prices"].description =~ "shopify_sync_may_overwrite"
    end
  end
end
