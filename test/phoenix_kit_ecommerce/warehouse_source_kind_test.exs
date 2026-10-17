defmodule PhoenixKitEcommerce.WarehouseSourceKindTest do
  @moduledoc """
  The warehouse source kind `shop_order`: what Warehouse's
  `SourceKinds` registry is given, and the three callbacks it dispatches to,
  against real billing orders. Only orders placed by the storefront checkout
  are shop orders, and no label shows the customer.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @compile {:no_warn_undefined, [PhoenixKitWarehouse.SourceKinds, PhoenixKitCatalogue.Catalogue]}

  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Order
  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.APIFixtures, as: F
  alias PhoenixKitEcommerce.WarehouseSourceKind, as: Kind
  alias PhoenixKitEcommerce.Web.StatusLabels
  alias PhoenixKitWarehouse.SourceKinds

  @item_a "0192a7c0-0000-7000-8000-00000000000a"
  @item_b "0192a7c0-0000-7000-8000-00000000000b"

  defp order!(attrs \\ %{}) do
    n = System.unique_integer([:positive])

    base = %Order{
      order_number: "WK-#{n}",
      status: "pending",
      total: Decimal.new("20.00"),
      currency: "EUR",
      metadata: %{"source" => "shop_checkout", "session_id" => "private-session"},
      line_items: [
        %{
          "type" => "product",
          "name" => "Mug",
          "sku" => "MUG",
          "quantity" => 3,
          "catalogue_item_uuid" => @item_a
        },
        %{
          "type" => "product",
          "name" => "Plate",
          "sku" => nil,
          "quantity" => 1,
          "catalogue_item_uuid" => @item_b
        },
        %{
          "type" => "product",
          "name" => "Legacy thing",
          "quantity" => 2,
          "catalogue_item_uuid" => nil
        },
        %{
          "type" => "shipping",
          "name" => "Shipping: Post",
          "quantity" => 1,
          "catalogue_item_uuid" => @item_a
        }
      ]
    }

    Repo.insert!(struct(base, attrs))
  end

  describe "what the registry is given" do
    test "one kind named shop_order, with the three callbacks Warehouse dispatches to" do
      assert [
               %{
                 kind: "shop_order",
                 label: label,
                 search: search,
                 resolve: resolve,
                 build_lines: lines
               }
             ] = Kind.kinds()

      assert is_binary(label) and label != ""
      assert Kind.kind() == "shop_order"

      # SourceKinds applies `apply(m, f, extra_args ++ dynamic_args)`
      assert {m, f, a} = search
      assert function_exported?(m, f, length(a) + 1)
      assert {m, f, a} = resolve
      assert function_exported?(m, f, length(a) + 1)
      assert {m, f, a} = lines
      assert function_exported?(m, f, length(a) + 2)
    end

    test "the module declares it where Warehouse looks for it" do
      assert PhoenixKitEcommerce.warehouse_source_kinds() == Kind.kinds()
      assert function_exported?(PhoenixKitEcommerce, :warehouse_source_kinds, 0)
    end

    test "every entry passes the filter SourceKinds applies to a module's list" do
      for entry <- PhoenixKitEcommerce.warehouse_source_kinds() do
        assert match?(%{kind: kind} when is_binary(kind), entry)
      end
    end
  end

  describe "search/1" do
    test "finds shop orders by a part of the number, newest first, and nothing else" do
      mine = order!()
      other = order!(%{metadata: %{"source" => "manual"}})

      [hit] = Kind.search(mine.order_number)
      assert hit.uuid == mine.uuid
      assert hit.label =~ mine.order_number
      assert hit.label == "#{mine.order_number} (#{StatusLabels.order("pending")})"
      refute hit.label =~ "pending"
      assert hit.extra == %{status: "pending"}

      assert Kind.search(other.order_number) == []
      assert Enum.any?(Kind.search("WK-"), &(&1.uuid == mine.uuid))
      refute Enum.any?(Kind.search("WK-"), &(&1.uuid == other.uuid))
    end

    test "lists the newest order first, whatever the number" do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      older = order!(%{inserted_at: DateTime.add(now, -3600, :second)})
      newer = order!(%{inserted_at: now})
      oldest = order!(%{inserted_at: DateTime.add(now, -7200, :second)})

      assert "WK-" |> Kind.search() |> Enum.map(& &1.uuid) ==
               [newer.uuid, older.uuid, oldest.uuid]
    end

    test "treats % and _ as text, not as wildcards" do
      order!()
      assert Kind.search("%") == []
      assert Kind.search("WK_") == []
    end

    test "returns at most 20 and is empty while the shop is off" do
      for _ <- 1..21, do: order!()
      assert length(Kind.search("WK-")) == 20

      PhoenixKit.Settings.update_setting("shop_enabled", "false")
      assert Kind.search("WK-") == []
    end

    test "shows no personal data" do
      order =
        order!(%{billing_snapshot: %{"email" => "buyer@example.com", "first_name" => "Ada"}})

      [hit] = Kind.search(order.order_number)
      refute inspect(hit) =~ "buyer@example.com"
      refute inspect(hit) =~ "Ada"
      refute inspect(hit) =~ "private-session"
    end
  end

  describe "resolve/1" do
    test "gives the label and the admin path of a shop order" do
      order = order!()

      assert %{label: label, path: path} = Kind.resolve(order.uuid)
      assert label == "#{order.order_number} (#{StatusLabels.order("pending")})"
      assert path == Routes.path("/admin/billing/orders/#{order.uuid}")
    end

    test "is :error for an unknown order, a manual order and something that is not a uuid" do
      manual = order!(%{metadata: %{"source" => "manual"}})

      assert Kind.resolve(Ecto.UUID.generate()) == :error
      assert Kind.resolve(manual.uuid) == :error
      assert Kind.resolve("not-a-uuid") == :error
    end
  end

  describe "build_lines/2" do
    test "gives the product lines that have a catalogue item, as an internal order imports them" do
      order = order!()

      assert {:ok, lines} = Kind.build_lines(order.uuid, Ecto.UUID.generate())

      assert lines == [
               %{
                 "item_uuid" => @item_a,
                 "name" => "Mug",
                 "sku" => "MUG",
                 "unit" => nil,
                 "catalogue_uuid" => nil,
                 "category_uuid" => nil,
                 "required_quantity" => "3"
               },
               %{
                 "item_uuid" => @item_b,
                 "name" => "Plate",
                 "sku" => nil,
                 "unit" => nil,
                 "catalogue_uuid" => nil,
                 "category_uuid" => nil,
                 "required_quantity" => "1"
               }
             ]
    end

    test "gives one line per item: lines that differ only in options are summed" do
      line = fn name, quantity, specs ->
        %{
          "type" => "product",
          "name" => name,
          "sku" => "MUG-#{name}",
          "quantity" => quantity,
          "selected_specs" => specs,
          "catalogue_item_uuid" => @item_a
        }
      end

      other = %{
        "type" => "product",
        "name" => "Plate",
        "quantity" => 4,
        "catalogue_item_uuid" => @item_b
      }

      order =
        order!(%{
          line_items: [
            line.("red", 3, %{"color" => "red"}),
            other,
            line.("blue", 2, %{"color" => "blue"})
          ]
        })

      assert {:ok, [mug, plate]} = Kind.build_lines(order.uuid, Ecto.UUID.generate())

      assert %{"item_uuid" => @item_a, "name" => "red", "sku" => "MUG-red"} = mug
      assert mug["required_quantity"] == "5"
      assert %{"item_uuid" => @item_b, "required_quantity" => "4"} = plate
    end

    test "leaves out a line that is not a product or whose item id is not a uuid" do
      order =
        order!(%{
          line_items: [
            %{"type" => "shipping", "quantity" => 1, "catalogue_item_uuid" => @item_a},
            %{"type" => "product", "quantity" => 1, "catalogue_item_uuid" => "not-a-uuid"},
            %{
              "type" => "product",
              "name" => "Ok",
              "quantity" => "2",
              "catalogue_item_uuid" => @item_b
            }
          ]
        })

      assert {:ok, [%{"item_uuid" => @item_b, "required_quantity" => "2"}]} =
               Kind.build_lines(order.uuid, Ecto.UUID.generate())
    end

    @tag :catalogue_api
    test "fills unit and catalogue from the catalogue items" do
      catalogue = F.shop_catalogue!()
      {:ok, category} = Catalogue.create_category(%{name: "Mugs", catalogue_uuid: catalogue.uuid})
      item = F.item!(catalogue, %{unit: "pack", category_uuid: category.uuid})

      order =
        order!(%{
          line_items: [
            %{
              "type" => "product",
              "name" => "Real",
              "sku" => "R-1",
              "quantity" => 2,
              "catalogue_item_uuid" => item.uuid
            }
          ]
        })

      assert {:ok, [line]} = Kind.build_lines(order.uuid, Ecto.UUID.generate())

      assert line["unit"] == "pack"
      assert line["catalogue_uuid"] == catalogue.uuid
      assert line["category_uuid"] == category.uuid
      assert line["required_quantity"] == "2"
    end

    test "is :error for an unknown order and for a manual one" do
      manual = order!(%{metadata: %{"source" => "manual"}})

      assert Kind.build_lines(Ecto.UUID.generate(), "actor") == :error
      assert Kind.build_lines(manual.uuid, "actor") == :error
    end
  end

  describe "with Warehouse installed" do
    @describetag :warehouse

    test "Warehouse lists the kind next to a kind the host configured, and renders a stored reference" do
      host_kind = %{
        kind: "host_thing",
        label: "Host thing",
        search: {__MODULE__, :host_search, []},
        resolve: {__MODULE__, :host_search, []}
      }

      previous = Application.get_env(:phoenix_kit_warehouse, :source_kinds)
      Application.put_env(:phoenix_kit_warehouse, :source_kinds, [host_kind])

      on_exit(fn ->
        if previous,
          do: Application.put_env(:phoenix_kit_warehouse, :source_kinds, previous),
          else: Application.delete_env(:phoenix_kit_warehouse, :source_kinds)
      end)

      kinds = Enum.map(SourceKinds.list_kinds(), & &1.kind)
      assert "host_thing" in kinds
      assert "shop_order" in kinds

      order = order!()
      assert %{path: path} = SourceKinds.resolve("shop_order", order.uuid)
      assert path == Routes.path("/admin/billing/orders/#{order.uuid}")
    end
  end

  @doc false
  def host_search(_query), do: []
end
