defmodule PhoenixKitEcommerce.Shopify.VariantMapperTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shopify.VariantMapper

  # 2 options (Size, Color) x 6 variants (every combination). Size drives
  # the bigger price swing, Color a smaller one, on TOP of Size's - the
  # exact case the modulel's moduledoc calls out (a single "first variant
  # seen" price would misattribute this).
  defp two_option_product do
    %{
      "id" => 999,
      "options" => [
        %{"name" => "Size", "position" => 1, "values" => ["Small", "Medium", "Large"]},
        %{"name" => "Color", "position" => 2, "values" => ["Red", "Blue"]}
      ],
      "variants" => [
        %{"option1" => "Small", "option2" => "Red", "price" => "10.00"},
        %{"option1" => "Small", "option2" => "Blue", "price" => "11.00"},
        %{"option1" => "Medium", "option2" => "Red", "price" => "12.00"},
        %{"option1" => "Medium", "option2" => "Blue", "price" => "13.00"},
        %{"option1" => "Large", "option2" => "Red", "price" => "15.00"},
        %{"option1" => "Large", "option2" => "Blue", "price" => "16.00"}
      ]
    }
  end

  defp grid(handle, options, rows) do
    %{
      "id" => 1,
      "handle" => handle,
      "options" =>
        options
        |> Enum.with_index(1)
        |> Enum.map(fn {{name, values}, pos} ->
          %{"name" => name, "position" => pos, "values" => values}
        end),
      "variants" =>
        Enum.map(rows, fn {values, price} ->
          values
          |> Enum.with_index(1)
          |> Map.new(fn {v, pos} -> {"option#{pos}", v} end)
          |> Map.merge(%{"title" => Enum.join(values, " / "), "price" => price})
        end)
    }
  end

  @heights ["4", "5", "6", "7", "8", "9", "10"]

  defp figure(handle, with_file, without_file) do
    rows =
      Enum.zip(@heights, with_file)
      |> Enum.map(fn {h, p} -> {["Have", h], p} end)
      |> Kernel.++(
        Enum.zip(@heights, without_file)
        |> Enum.map(fn {h, p} -> {["None", h], p} end)
      )

    grid(
      handle,
      [{"Printing File Ready?", ["Have", "None"]}, {"Print or Figure Height", @heights}],
      rows
    )
  end

  defp personalized,
    do:
      figure(
        "personalized",
        ~w(29.28 35.64 45.36 51.36 58.56 70.56 82.56),
        ~w(215.28 225.24 231.36 239.76 245.76 253.92 263.16)
      )

  defp rapid,
    do:
      figure(
        "rapid",
        ~w(23.28 33.24 39.36 47.76 53.76 62.16 71.76),
        ~w(215.28 225.24 231.24 239.64 244.80 254.16 263.76)
      )

  @colors ~w(Black Matte White Gray Tan Brown MutedRed Red Orange Gold Yellow Green Turquoise Blue Purple Pink)
  @premium [
    {"Black", "White"},
    {"Gray", "Black"},
    {"Gray", "White"},
    {"Gray", "Brown"},
    {"Brown", "White"}
  ]

  defp sculpture do
    rows =
      for liquid <- @colors, cup <- @colors do
        premium? = liquid == cup or {liquid, cup} in @premium
        {[liquid, cup], if(premium?, do: "67.52", else: "35.52")}
      end

    grid("sculpture", [{"Liquid Color", @colors}, {"Cup Color", @colors}], rows)
  end

  # Price a variant the way the storefront does: min variant price + Σ modifiers.
  defp predicted(product, result, variant) do
    min_all = product["variants"] |> Enum.map(&Decimal.new(&1["price"])) |> Enum.min(Decimal)

    result.sets
    |> Enum.reduce(min_all, fn set, sum ->
      Decimal.add(
        sum,
        result.modifiers[set.slug][variant["option#{set.position}"]] || Decimal.new(0)
      )
    end)
  end

  defp assert_never_cheaper(product, result) do
    for v <- product["variants"] do
      assert Decimal.compare(predicted(product, result, v), Decimal.new(v["price"])) in [:gt, :eq],
             "#{v["title"]} priced below Shopify"
    end
  end

  defp strings(map), do: Map.new(map, fn {k, v} -> {k, Decimal.to_string(v)} end)

  describe "build/1 — two real options" do
    setup do
      %{result: VariantMapper.build(two_option_product())}
    end

    test "one set per option, in Shopify's option order", %{result: result} do
      assert [
               %{name: "Size", slug: "size", position: 1, values: ["Small", "Medium", "Large"]},
               %{name: "Color", slug: "color", position: 2, values: ["Red", "Blue"]}
             ] = result.sets
    end

    test "values are ordered by first appearance across variants", %{result: result} do
      [size_set, color_set] = result.sets
      assert size_set.values == ["Small", "Medium", "Large"]
      assert color_set.values == ["Red", "Blue"]
    end

    test "modifier per value is min(price for that value) - min(all prices)", %{result: result} do
      assert %{
               "Small" => small,
               "Medium" => medium,
               "Large" => large
             } = result.modifiers["size"]

      assert Decimal.equal?(small, Decimal.new("0.00"))
      assert Decimal.equal?(medium, Decimal.new("2.00"))
      assert Decimal.equal?(large, Decimal.new("5.00"))

      assert %{"Red" => red, "Blue" => blue} = result.modifiers["color"]
      assert Decimal.equal?(red, Decimal.new("0.00"))
      assert Decimal.equal?(blue, Decimal.new("1.00"))
    end

    test "the cheapest value's modifier prints with two decimals, not bare zero", %{
      result: result
    } do
      assert Decimal.to_string(result.modifiers["size"]["Small"]) == "0.00"
      assert Decimal.to_string(result.modifiers["color"]["Red"]) == "0.00"
    end
  end

  describe "build/1 — additive-matrix check" do
    import ExUnit.CaptureLog

    test "an additive matrix produces no warnings" do
      assert VariantMapper.build(two_option_product()).warnings == []
    end

    # S/L x Red/Blue at 10/12/15/20: S:0, L:5, Red:0, Blue:2 predicts 17
    # for Large/Blue, which Shopify prices at 20 — the exact under-pricing
    # the moduledoc describes. Under :cheapest the modifiers stay the raw
    # M_o and the mismatch is reported as a fit warning (not per-variant
    # any more). Under the default :never_cheaper, Size absorbs the
    # shortfall so no variant is ever predicted below Shopify.
    test "a non-additive matrix gets one product-level warning and log line; default rule is never cheaper" do
      product = %{
        "id" => 42,
        "handle" => "non-additive-tee",
        "options" => [
          %{"name" => "Size", "position" => 1, "values" => ["Small", "Large"]},
          %{"name" => "Color", "position" => 2, "values" => ["Red", "Blue"]}
        ],
        "variants" => [
          %{
            "title" => "Small / Red",
            "option1" => "Small",
            "option2" => "Red",
            "price" => "10.00"
          },
          %{
            "title" => "Small / Blue",
            "option1" => "Small",
            "option2" => "Blue",
            "price" => "12.00"
          },
          %{
            "title" => "Large / Red",
            "option1" => "Large",
            "option2" => "Red",
            "price" => "15.00"
          },
          %{
            "title" => "Large / Blue",
            "option1" => "Large",
            "option2" => "Blue",
            "price" => "20.00"
          }
        ]
      }

      {cheapest, log} = with_log(fn -> VariantMapper.build(product, rule: :cheapest) end)

      assert Decimal.eq?(cheapest.modifiers["size"]["Large"], Decimal.new("5.00"))
      assert Decimal.eq?(cheapest.modifiers["color"]["Blue"], Decimal.new("2.00"))

      assert [warning] = cheapest.warnings
      refute warning =~ "non-additive-tee"
      assert warning =~ "1 of 4"
      assert warning =~ "-3.00"
      assert log =~ "non-additive-tee"

      # Size (position 1) and Color (position 2) tie on total overcharge
      # here (3.00 either way) — the default rule must break the tie by
      # position, so Size (not Color) is the one that absorbs.
      default = VariantMapper.build(product)
      assert Decimal.eq?(default.modifiers["size"]["Large"], Decimal.new("8.00"))
      assert_never_cheaper(product, default)
    end
  end

  describe "build/1 — Shopify's auto-generated default option" do
    test "a lone Title/Default Title option is skipped entirely" do
      product = %{
        "options" => [%{"name" => "Title", "position" => 1, "values" => ["Default Title"]}],
        "variants" => [%{"option1" => "Default Title", "price" => "9.99"}]
      }

      assert %{sets: [], modifiers: %{}, warnings: []} = result = VariantMapper.build(product)
      assert result.fit.exact?
    end

    test "no options/variants at all yields the same empty shape" do
      assert %{sets: [], modifiers: %{}, warnings: []} = result = VariantMapper.build(%{})
      assert result.fit.exact?
    end
  end

  describe "build/2 — additive products are untouched by either rule" do
    test "byte-identical modifiers, exact fit, no warnings" do
      for rule <- [:never_cheaper, :cheapest] do
        result = VariantMapper.build(two_option_product(), rule: rule)

        assert strings(result.modifiers["size"]) == %{
                 "Small" => "0.00",
                 "Medium" => "2.00",
                 "Large" => "5.00"
               }

        assert strings(result.modifiers["color"]) == %{"Red" => "0.00", "Blue" => "1.00"}
        assert result.fit.exact?
        assert result.fit.variants == 6
        assert result.warnings == []
      end
    end
  end

  describe "build/2 — :never_cheaper" do
    test "Personalized: height absorbs, never below Shopify, up to +5.40" do
      product = personalized()
      result = VariantMapper.build(product)

      assert strings(result.modifiers["printing_file_ready"]) == %{
               "Have" => "0.00",
               "None" => "186.00"
             }

      assert strings(result.modifiers["print_or_figure_height"]) ==
               Map.new(Enum.zip(@heights, ~w(0.00 9.96 16.08 24.48 30.48 41.28 53.28)))

      assert %{exact?: false, rule: :never_cheaper, variants: 14, over: 5, under: 0} = result.fit
      assert Decimal.to_string(result.fit.max_over) == "5.40"
      assert_never_cheaper(product, result)
    end

    test "Rapid: never below Shopify, up to +0.96" do
      product = rapid()
      result = VariantMapper.build(product)
      assert %{over: 3, under: 0} = result.fit
      assert Decimal.to_string(result.fit.max_over) == "0.96"
      assert_never_cheaper(product, result)
    end

    test "sculpture: the first option absorbs +32 on every value, every combination 67.52" do
      product = sculpture()
      result = VariantMapper.build(product)

      assert Enum.all?(Map.values(result.modifiers["liquid_color"]), &Decimal.eq?(&1, "32.00"))
      assert Enum.all?(Map.values(result.modifiers["cup_color"]), &Decimal.eq?(&1, "0.00"))
      assert %{variants: 256, over: 235, under: 0} = result.fit
      assert Decimal.to_string(result.fit.max_over) == "32.00"
      assert_never_cheaper(product, result)
    end

    test "three options: invariant holds and no modifier is negative" do
      rows =
        for a <- ~w(A1 A2), b <- ~w(B1 B2), c <- ~w(C1 C2) do
          base =
            10 + if(a == "A2", do: 3, else: 0) + if(b == "B2", do: 2, else: 0) +
              if(c == "C2", do: 1, else: 0)

          bump = if a == "A2" and b == "B2" and c == "C2", do: 4, else: 0
          {[a, b, c], "#{base + bump}.00"}
        end

      product = grid("three", [{"A", ~w(A1 A2)}, {"B", ~w(B1 B2)}, {"C", ~w(C1 C2)}], rows)
      result = VariantMapper.build(product)

      assert_never_cheaper(product, result)

      for {_slug, by_value} <- result.modifiers,
          {_v, amount} <- by_value,
          do: refute(Decimal.negative?(amount))
    end

    test "an option missing on a priced variant is never the absorber" do
      product =
        grid("gap", [{"Size", ~w(S L)}, {"Color", ~w(Red Blue)}], [
          {["S", "Red"], "10.00"},
          {["S", "Blue"], "12.00"},
          {["L", "Red"], "15.00"},
          {["L", "Blue"], "20.00"}
        ])

      product = update_in(product, ["variants"], &[Map.delete(hd(&1), "option2") | tl(&1)])
      result = VariantMapper.build(product)

      assert result.fit.rule == :never_cheaper
      # Color is disqualified (the S/Red variant lost its "option2"), so
      # Size is the only candidate — asserted by NAME, not just by the
      # invariant, so a regression that let Color absorb anyway (its
      # lower total overcharge would otherwise win the tie-break) fails
      # here instead of only tripping `assert_never_cheaper/2`.
      assert strings(result.modifiers["size"]) == %{"S" => "0.00", "L" => "8.00"}
      assert strings(result.modifiers["color"]) == %{"Red" => "5.00", "Blue" => "2.00"}
      assert_never_cheaper(product, result)
    end

    test "a genuine absorber tie breaks by option position, not payload array order" do
      # Same S/L x Red/Blue at 10/12/15/20 as the non-additive-tee test
      # (both Size and Color tie at 3.00 total overcharge) — but here
      # "options" lists Color (position 2) BEFORE Size (position 1), the
      # reverse of their own `position`. Shopify position must still
      # decide the tie: Size absorbs, not whichever option came first in
      # the array.
      product = %{
        "id" => 44,
        "handle" => "reversed-order-tee",
        "options" => [
          %{"name" => "Color", "position" => 2, "values" => ["Red", "Blue"]},
          %{"name" => "Size", "position" => 1, "values" => ["Small", "Large"]}
        ],
        "variants" => [
          %{"option1" => "Small", "option2" => "Red", "price" => "10.00"},
          %{"option1" => "Small", "option2" => "Blue", "price" => "12.00"},
          %{"option1" => "Large", "option2" => "Red", "price" => "15.00"},
          %{"option1" => "Large", "option2" => "Blue", "price" => "20.00"}
        ]
      }

      result = VariantMapper.build(product)

      assert strings(result.modifiers["size"]) == %{"Small" => "0.00", "Large" => "8.00"}
      assert strings(result.modifiers["color"]) == %{"Red" => "0.00", "Blue" => "2.00"}
      assert_never_cheaper(product, result)
    end

    test "no eligible absorber falls back to :cheapest and says so" do
      product = %{
        "handle" => "lonely",
        "options" => [%{"name" => "Size", "position" => 1, "values" => ["A"]}],
        "variants" => [
          %{"option1" => "A", "price" => "10.00"},
          %{"price" => "15.00", "title" => "no option"}
        ]
      }

      assert %{fit: %{rule: :cheapest, under: 1}} = VariantMapper.build(product)
    end
  end

  describe "build/2 — :cheapest" do
    test "sculpture: every combination 35.52, 21 below Shopify by 32" do
      result = VariantMapper.build(sculpture(), rule: :cheapest)

      assert Enum.all?(
               Map.values(result.modifiers["liquid_color"]) ++
                 Map.values(result.modifiers["cup_color"]),
               &Decimal.eq?(&1, "0.00")
             )

      assert %{rule: :cheapest, over: 0, under: 21} = result.fit
      assert Decimal.to_string(result.fit.max_under) == "32.00"
    end

    test "Personalized: today's modifiers, −3.60 … +5.40" do
      result = VariantMapper.build(personalized(), rule: :cheapest)
      assert Decimal.to_string(result.fit.max_under) == "3.60"
      assert Decimal.to_string(result.fit.max_over) == "5.40"
    end
  end

  describe "build/2 — warnings" do
    import ExUnit.CaptureLog

    test "one warning and one log line per approximated product, not per variant" do
      {result, log} = with_log(fn -> VariantMapper.build(sculpture()) end)
      assert [warning] = result.warnings
      assert warning =~ "never_cheaper"
      assert warning =~ "235 of 256"
      assert warning =~ "+32.00"
      assert length(String.split(log, "sculpture")) == 2
    end

    test "a variant without a price is not counted" do
      product =
        update_in(
          personalized(),
          ["variants"],
          &[%{"option1" => "Have", "option2" => "4", "price" => ""} | &1]
        )

      assert VariantMapper.build(product).fit.variants == 14
    end
  end

  describe "build/2 — :base_price (the base the storefront adds modifiers to)" do
    import ExUnit.CaptureLog

    test "a base equal to Shopify's cheapest variant changes nothing" do
      result = VariantMapper.build(two_option_product(), base_price: Decimal.new("10.00"))
      assert result.fit.exact?
      assert Decimal.to_string(result.fit.base_offset) == "0.00"
      assert result.warnings == []
    end

    # Shopify removed the 10.00 variant's cheaper sibling or the base was
    # never re-applied: modifiers still re-anchor to Shopify's cheapest
    # variant, so every storefront price is off by the base's offset.
    test "a base below Shopify's cheapest variant makes an additive product non-exact, and says why" do
      {result, log} =
        with_log(fn ->
          VariantMapper.build(two_option_product(), base_price: Decimal.new("5.00"))
        end)

      assert strings(result.modifiers["size"]) == %{
               "Small" => "0.00",
               "Medium" => "2.00",
               "Large" => "5.00"
             }

      assert %{exact?: false, over: 0, under: 6, variants: 6} = result.fit
      assert Decimal.to_string(result.fit.max_under) == "5.00"
      assert Decimal.to_string(result.fit.base_offset) == "-5.00"
      # The modifiers match Shopify — only the base drifted, which is not an
      # approximation and must not be labelled or counted as one.
      refute result.fit.approximated?
      assert [warning] = result.warnings
      assert warning =~ "the base price is -5.00 off"
      refute warning =~ "prices approximated"
      assert log =~ "base price is -5.00 off"
    end

    test "a non-additive product with a drifted base is both approximated and offset" do
      result = VariantMapper.build(personalized(), base_price: Decimal.new("10.00"))
      assert result.fit.approximated?
      assert [warning] = result.warnings
      assert warning =~ "prices approximated"
      assert warning =~ "base price is -19.28 off"
    end

    # No options, no modifiers for the sync to re-anchor: a base that differs
    # from the one Shopify price is a plain pending price change, and the
    # Changes tab already reports it.
    test "a product with no options never reports a base offset" do
      product = %{"handle" => "plain", "variants" => [%{"price" => "9.99"}]}
      result = VariantMapper.build(product, base_price: Decimal.new("8.00"))
      assert result.fit.exact?
      assert result.warnings == []
    end
  end
end
