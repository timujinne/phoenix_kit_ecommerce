defmodule PhoenixKitEcommerce.Shipping.Packer.SingleBoxTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias PhoenixKitEcommerce.Shipping.Packer
  alias PhoenixKitEcommerce.Shipping.Packer.{Defaults, SingleBox}
  alias PhoenixKitEcommerce.Shipping.{PackItem, Parcel}

  defp item(attrs), do: struct(%PackItem{}, attrs)

  describe "build/2 weight" do
    test "sums quantity times weight" do
      items = [item(weight_g: 300, quantity: 2), item(weight_g: 150, quantity: 1)]

      assert [%Parcel{weight_g: 750}] = SingleBox.build(items, %Defaults{})
    end

    test "no items, no parcels" do
      assert SingleBox.build([], %Defaults{}) == []
    end

    test "zero quantity positions are skipped" do
      assert [%Parcel{weight_g: 100}] =
               SingleBox.build(
                 [item(weight_g: 100), item(weight_g: 5000, quantity: 0)],
                 %Defaults{}
               )
    end

    test "uses the item default weight, then the shop default, and warns once" do
      items = [
        item(weight_g: nil, default_weight_g: 200, quantity: 2),
        item(weight_g: nil, default_weight_g: nil, quantity: 1),
        item(weight_g: 100, quantity: 1)
      ]

      log =
        capture_log(fn ->
          assert [%Parcel{weight_g: 800}] = SingleBox.build(items, %Defaults{weight_g: 300})
        end)

      assert log =~ "2 cart position(s) without a weight"
      assert length(String.split(log, "without a weight")) == 2
    end

    test "a zero weight counts as missing" do
      log =
        capture_log(fn ->
          assert [%Parcel{weight_g: 250}] =
                   SingleBox.build([item(weight_g: 0)], %Defaults{weight_g: 250})
        end)

      assert log =~ "1 cart position(s) without a weight"
    end

    test "no weight anywhere gives weight 0" do
      capture_log(fn ->
        assert [%Parcel{weight_g: 0}] = SingleBox.build([item(weight_g: nil)], %Defaults{})
      end)
    end

    test "does not warn when every position has a weight" do
      log =
        capture_log(fn ->
          SingleBox.build([item(weight_g: 100)], %Defaults{weight_g: 500})
        end)

      refute log =~ "without a weight"
    end
  end

  describe "build/2 dimensions" do
    test "no dimensions anywhere gives nil dimensions" do
      assert [%Parcel{length_mm: nil, width_mm: nil, height_mm: nil}] =
               SingleBox.build([item(weight_g: 100)], %Defaults{})
    end

    test "the default box alone is used when items have no dimensions" do
      assert [%Parcel{length_mm: 300, width_mm: 200, height_mm: 100}] =
               SingleBox.build([item(weight_g: 100)], %Defaults{box_mm: [100, 300, 200]})
    end

    test "a small item keeps the default box" do
      items = [item(weight_g: 100, dims_mm: [50, 40, 30])]

      assert [%Parcel{length_mm: 300, width_mm: 200, height_mm: 100}] =
               SingleBox.build(items, %Defaults{box_mm: [300, 200, 100]})
    end

    test "an item bigger than the default box widens it side by side" do
      items = [item(weight_g: 100, dims_mm: [100, 500, 250])]

      assert [%Parcel{length_mm: 500, width_mm: 250, height_mm: 100}] =
               SingleBox.build(items, %Defaults{box_mm: [300, 200, 100]})
    end

    test "item dimensions are sorted before comparing" do
      items = [item(weight_g: 100, dims_mm: [10, 400, 20])]

      assert [%Parcel{length_mm: 400, width_mm: 20, height_mm: 10}] =
               SingleBox.build(items, %Defaults{})
    end

    test "without a box the envelope of the items is used" do
      items = [
        item(weight_g: 100, dims_mm: [300, 100, 50]),
        item(weight_g: 100, dims_mm: [200, 150, 20])
      ]

      assert [%Parcel{length_mm: 300, width_mm: 150, height_mm: 50}] =
               SingleBox.build(items, %Defaults{})
    end

    test "the shortest side grows when the volume exceeds the box" do
      # 4 units of 100x100x100 = 4_000_000 mm3 in a 100x100x100 envelope
      # -> height = ceil(4_000_000 / (100 * 100)) = 400, sorted desc.
      items = [item(weight_g: 100, dims_mm: [100, 100, 100], quantity: 4)]

      assert [%Parcel{length_mm: 400, width_mm: 100, height_mm: 100}] =
               SingleBox.build(items, %Defaults{})
    end

    test "growth is relative to the (already widened) envelope" do
      items = [
        item(weight_g: 10, dims_mm: [300, 200, 100], quantity: 2),
        item(weight_g: 10, dims_mm: [100, 100, 100], quantity: 1)
      ]

      # envelope 300x200x100 = 6_000_000 mm3, volume = 13_000_000 mm3, so the
      # shortest side becomes ceil(13_000_000 / (300 * 200)) = 217.
      assert [%Parcel{length_mm: 300, width_mm: 217, height_mm: 200}] =
               SingleBox.build(items, %Defaults{})
    end

    test "volume that fits does not grow the box" do
      items = [item(weight_g: 10, dims_mm: [100, 100, 100], quantity: 1)]

      assert [%Parcel{length_mm: 300, width_mm: 200, height_mm: 100}] =
               SingleBox.build(items, %Defaults{box_mm: [300, 200, 100]})
    end

    test "invalid dimension triples are ignored" do
      items = [
        item(weight_g: 10, dims_mm: [100, 100]),
        item(weight_g: 10, dims_mm: [100, 0, 100]),
        item(weight_g: 10, dims_mm: nil)
      ]

      assert [%Parcel{length_mm: nil}] = SingleBox.build(items, %Defaults{})
    end
  end

  describe "Packer.pack/2" do
    test "dispatches to SingleBox by default" do
      assert [%Parcel{weight_g: 300}] =
               Packer.pack([item(weight_g: 150, quantity: 2)], %Defaults{})
    end
  end

  describe "build/2 default weights and rounding" do
    test "a non-positive item default falls through to the shop default" do
      capture_log(fn ->
        assert [%Parcel{weight_g: 300}] =
                 SingleBox.build(
                   [item(weight_g: nil, default_weight_g: 0)],
                   %Defaults{weight_g: 300}
                 )

        assert [%Parcel{weight_g: 0}] =
                 SingleBox.build(
                   [item(weight_g: nil, default_weight_g: -5)],
                   %Defaults{weight_g: 0}
                 )
      end)
    end

    test "weights are whole grams, rounded up" do
      assert [%Parcel{weight_g: weight}] =
               SingleBox.build([item(weight_g: 10.2, quantity: 3)], %Defaults{})

      assert weight == 33
      assert is_integer(weight)

      capture_log(fn ->
        assert [%Parcel{weight_g: 22}] =
                 SingleBox.build(
                   [item(weight_g: nil, default_weight_g: 10.5, quantity: 2)],
                   %Defaults{}
                 )
      end)
    end

    test "the grown side is an integer computed without floats" do
      # 13 units of 11 x 7 x 3 = 3003 mm3 over an 11 x 7 base -> 3003 / 77 = 39
      items = [item(weight_g: 1, dims_mm: [11, 7, 3], quantity: 13)]

      assert [%Parcel{length_mm: 39, width_mm: 11, height_mm: 7} = parcel] =
               SingleBox.build(items, %Defaults{})

      assert is_integer(parcel.length_mm)
    end
  end
end
