defmodule PhoenixKitEcommerce.Catalogue.ShopSectionsParcelTest do
  @moduledoc """
  The parcel inputs of the catalogue item and category "Shop" sections, and
  that what they post is stored by the extension. No database needed.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias PhoenixKitEcommerce.Catalogue.Extension

  describe "item section" do
    test "renders the size inputs next to the weight with the stored values" do
      html =
        render_component(&Extension.item_section/1,
          form: nil,
          item: nil,
          data: %{
            "ecommerce" => %{
              "weight_grams" => 750,
              "length_mm" => 400,
              "width_mm" => 300,
              "height_mm" => 200
            }
          },
          current_language: "en"
        )

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "#ext-ecommerce-dimensions") |> Enum.count() == 1
      assert input_value(document, "item[ecommerce][weight_grams]") == "750"
      assert input_value(document, "item[ecommerce][length_mm]") == "400"
      assert input_value(document, "item[ecommerce][width_mm]") == "300"
      assert input_value(document, "item[ecommerce][height_mm]") == "200"
    end

    test "the size is stored by the extension and a blank clears it" do
      assert {:ok, data} =
               Extension.cast_item(
                 %{"length_mm" => "400", "width_mm" => "300", "height_mm" => "200"},
                 %{}
               )

      assert {data["length_mm"], data["width_mm"], data["height_mm"]} == {400, 300, 200}

      assert {:ok, cleared} =
               Extension.cast_item(
                 %{"length_mm" => "", "width_mm" => "", "height_mm" => ""},
                 data
               )

      assert {cleared["length_mm"], cleared["width_mm"], cleared["height_mm"]} ==
               {nil, nil, nil}
    end

    test "a negative side is refused" do
      assert {:error, errors} = Extension.cast_item(%{"length_mm" => "-1"}, %{})
      assert Keyword.has_key?(errors, :length_mm)
    end
  end

  describe "category section" do
    test "renders the default parcel with the stored values" do
      html =
        render_component(&Extension.category_section/1,
          form: nil,
          category: nil,
          data: %{
            "ecommerce" => %{
              "parcel_length_mm" => 500,
              "parcel_width_mm" => 400,
              "parcel_height_mm" => 300,
              "parcel_weight_g" => 2500
            }
          },
          current_language: "en"
        )

      document = LazyHTML.from_fragment(html)

      assert LazyHTML.query(document, "#ext-ecommerce-parcel-defaults") |> Enum.count() == 1
      assert input_value(document, "category[ecommerce][parcel_length_mm]") == "500"
      assert input_value(document, "category[ecommerce][parcel_width_mm]") == "400"
      assert input_value(document, "category[ecommerce][parcel_height_mm]") == "300"
      assert input_value(document, "category[ecommerce][parcel_weight_g]") == "2500"
    end

    test "the default parcel is stored by the extension and a blank clears it" do
      assert {:ok, data} =
               Extension.cast_category(
                 %{
                   "parcel_length_mm" => "500",
                   "parcel_width_mm" => "400",
                   "parcel_height_mm" => "300",
                   "parcel_weight_g" => "2500"
                 },
                 %{}
               )

      assert data["parcel_length_mm"] == 500
      assert data["parcel_weight_g"] == 2500

      assert {:ok, cleared} = Extension.cast_category(%{"parcel_length_mm" => ""}, data)
      assert cleared["parcel_length_mm"] == nil
    end
  end

  defp input_value(document, name) do
    document
    |> LazyHTML.query(~s(input[name="#{name}"]))
    |> LazyHTML.attribute("value")
    |> List.first()
  end
end
