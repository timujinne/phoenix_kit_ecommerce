defmodule PhoenixKitEcommerce.Regression.ImportParsingTest do
  @moduledoc """
  Shopify CSV parsing defects found by an adversarial sweep of the import
  subsystem: a feed with unreadable prices published free products, and rows
  with no handle merged into a single product.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Import.CSVParser
  alias PhoenixKitEcommerce.Import.OptionBuilder

  defp write_csv(rows) do
    path =
      Path.join(
        System.tmp_dir!(),
        "shopify-#{System.unique_integer([:positive])}.csv"
      )

    File.write!(path, Enum.join(rows, "\n") <> "\n")
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "grouping" do
    test "rows with no handle stay separate products" do
      path =
        write_csv([
          "Handle,Title,Variant Price",
          ",Red Vase,10.00",
          ",Blue Lamp,20.00"
        ])

      grouped = CSVParser.parse_and_group(path)

      assert map_size(grouped) == 2, "two handle-less products collapsed into one"

      titles =
        grouped
        |> Map.values()
        |> Enum.map(fn [row | _] -> row["Title"] end)
        |> Enum.sort()

      assert titles == ["Blue Lamp", "Red Vase"]
    end

    test "a reordered re-export still yields the same products" do
      forward = write_csv(["Handle,Title,Variant Price", ",Red Vase,10.00", ",Blue Lamp,20.00"])
      reversed = write_csv(["Handle,Title,Variant Price", ",Blue Lamp,20.00", ",Red Vase,10.00"])

      # The grouping key is positional, but it never reaches the product —
      # `handle_value/1` blanks it, so the slug is derived from the title and
      # a re-import matches on that.
      titles = fn path ->
        path
        |> CSVParser.parse_and_group()
        |> Enum.map(fn {_key, [row | _]} -> row["Title"] end)
        |> Enum.sort()
      end

      assert titles.(forward) == titles.(reversed)
      assert titles.(forward) == ["Blue Lamp", "Red Vase"]
    end

    test "a handle-less row does not merge into a real handle with the same title" do
      path =
        write_csv([
          "Handle,Title,Variant Price",
          "mug,Coffee Mug,10.00",
          ",Mug,20.00"
        ])

      grouped = CSVParser.parse_and_group(path)

      assert map_size(grouped) == 2,
             "a title-derived key collided with a handle a merchant actually wrote"

      assert length(grouped["mug"]) == 1
    end

    test "a continuation row stays with the product above it" do
      # Shopify's variant shape: only the first row of a product carries a
      # title. With the handle blank too, the variant must not become its own
      # product (and then fail validation for having no title).
      path =
        write_csv([
          "Handle,Title,Option1 Name,Option1 Value,Variant Price",
          ",Red Vase,Size,S,10.00",
          ",,Size,L,14.00",
          ",Blue Lamp,Size,S,20.00"
        ])

      grouped = CSVParser.parse_and_group(path)

      assert map_size(grouped) == 2

      vase =
        Enum.find_value(grouped, fn {_k, rows} ->
          if List.first(rows)["Title"] == "Red Vase", do: rows
        end)

      assert length(vase) == 2, "the L variant was split off its product"
      assert Enum.map(vase, & &1["Option1 Value"]) == ["S", "L"]
    end

    test "a handle-less group imports under no handle at all" do
      path = write_csv(["Handle,Title,Variant Price", ",Red Vase,10.00"])

      [key] = CSVParser.parse_and_group(path) |> Map.keys()

      refute CSVParser.handle_value(key),
             "a synthetic grouping key must not reach the product as its slug"

      assert is_binary(CSVParser.display_handle(key))
    end

    test "rows sharing a handle stay one product with its variants" do
      path =
        write_csv([
          "Handle,Title,Option1 Name,Option1 Value,Variant Price",
          "mug,Mug,Size,S,10.00",
          "mug,,Size,L,14.00"
        ])

      grouped = CSVParser.parse_and_group(path)

      assert map_size(grouped) == 1
      assert length(grouped["mug"]) == 2
    end
  end

  describe "Shopify's placeholder option" do
    @placeholder [
      %{
        "Option1 Name" => "Title",
        "Option1 Value" => "Default Title",
        "Variant Price" => "12.00"
      }
    ]

    test "a product without variants gets no option at all" do
      assert %{options: [], base_price: price} = OptionBuilder.build_extended(@placeholder)
      assert Decimal.equal?(price, Decimal.new("12.00"))

      assert %{option1_name: nil, option1_values: [], option1_modifiers: modifiers} =
               OptionBuilder.build_from_variants(@placeholder)

      assert modifiers == %{}
    end

    test "a real option that happens to be called Title is kept" do
      rows = [
        %{"Option1 Name" => "Title", "Option1 Value" => "Mr", "Variant Price" => "12.00"},
        %{"Option1 Name" => "Title", "Option1 Value" => "Dr", "Variant Price" => "12.00"}
      ]

      assert %{options: [%{name: "Title", values: ["Mr", "Dr"]}]} =
               OptionBuilder.build_extended(rows)

      assert %{option1_name: "Title"} = OptionBuilder.build_from_variants(rows)
    end

    test "the placeholder beside a real second option drops only itself" do
      rows = [
        %{
          "Option1 Name" => "Title",
          "Option1 Value" => "Default Title",
          "Option2 Name" => "Color",
          "Option2 Value" => "Red",
          "Variant Price" => "12.00"
        }
      ]

      assert %{options: [%{name: "Color", position: 2}]} = OptionBuilder.build_extended(rows)
    end
  end

  describe "pricing" do
    test "a variant set with no readable price yields no price at all" do
      variants = [
        %{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "N/A"}
      ]

      options = OptionBuilder.build_from_variants(variants)

      refute options.base_price,
             "an unreadable price defaulted to zero, publishing a free product"
    end

    test "the base price is the numeric minimum, not the term-order minimum" do
      variants = [
        %{"Option1 Name" => "Size", "Option1 Value" => "L", "Variant Price" => "10.00"},
        %{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "9.99"}
      ]

      options = OptionBuilder.build_from_variants(variants)

      assert Decimal.equal?(options.base_price, Decimal.new("9.99"))
    end

    test "a partially readable variant set still prices from what it can read" do
      variants = [
        %{"Option1 Name" => "Size", "Option1 Value" => "S", "Variant Price" => "12.00"},
        %{"Option1 Name" => "Size", "Option1 Value" => "L", "Variant Price" => ""}
      ]

      options = OptionBuilder.build_from_variants(variants)

      assert Decimal.equal?(options.base_price, Decimal.new("12.00"))
    end
  end
end
