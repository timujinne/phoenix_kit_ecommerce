defmodule PhoenixKitEcommerce.Shipping.Providers.TableTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shipping.{Context, Parcel, Quote, RateRequest, Service}
  alias PhoenixKitEcommerce.Shipping.Providers.Table
  alias PhoenixKitEcommerce.ShippingMethod

  @rates """
  0.5 70
  1 90
  5 150
  30 400
  """

  defp ctx(settings \\ %{}) do
    %Context{
      method: %ShippingMethod{price: Decimal.new("49"), currency: "UAH"},
      settings: Map.put_new(settings, "rates", @rates)
    }
  end

  defp request(parcels), do: %RateRequest{parcels: parcels}
  defp parcel(grams, dims \\ [nil, nil, nil]), do: parcel_with(grams, dims)

  defp parcel_with(grams, [l, w, h]),
    do: %Parcel{weight_g: grams, length_mm: l, width_mm: w, height_mm: h}

  defp amount({:ok, %Quote{amount: amount}}), do: Decimal.to_string(amount, :normal)

  test "identifies itself" do
    assert Table.key() == "table"
    assert is_binary(Table.label())
  end

  describe "parse_rates/1" do
    test "parses lines and sorts by weight" do
      assert [{max1, price1}, {max2, price2}] = Table.parse_rates("5 150\n1 90")
      assert {Decimal.to_string(max1), Decimal.to_string(price1)} == {"1", "90"}
      assert {Decimal.to_string(max2), Decimal.to_string(price2)} == {"5", "150"}
    end

    test "accepts a decimal comma, tabs, CRLF and extra blanks" do
      assert [{max, price}, _] = Table.parse_rates("0,5\t70,50\r\n  2   100  \r\n")
      assert Decimal.equal?(max, "0.5")
      assert Decimal.equal?(price, "70.5")
    end

    test "drops comments, blanks and malformed lines" do
      text = "# header\n\n1 90\nnonsense\n2\n3 abc\n-1 5\n0 10\n4 -2\n5 100 extra\n6 120"

      assert [{one, _}, {six, _}] = Table.parse_rates(text)
      assert Decimal.equal?(one, 1)
      assert Decimal.equal?(six, 6)
    end

    test "non-text is empty" do
      assert Table.parse_rates(nil) == []
      assert Table.parse_rates(42) == []
    end
  end

  describe "services/1" do
    test "no destination by default" do
      assert [%Service{key: "default", destination: :none, point_code_label: nil}] =
               Table.services(ctx())
    end

    test "address and manual pickup point" do
      assert [%Service{destination: :address}] =
               Table.services(ctx(%{"destination" => "address"}))

      assert [%Service{destination: :pickup_point, lookup: :manual, point_code_label: label}] =
               Table.services(ctx(%{"destination" => "pickup_point"}))

      assert is_binary(label)
    end
  end

  describe "quote/2 weight bands" do
    test "picks the first band that fits" do
      assert amount(Table.quote(request([parcel(300)]), ctx())) == "70"
      assert amount(Table.quote(request([parcel(500)]), ctx())) == "70"
      assert amount(Table.quote(request([parcel(501)]), ctx())) == "90"
      assert amount(Table.quote(request([parcel(1000)]), ctx())) == "90"
      assert amount(Table.quote(request([parcel(4999)]), ctx())) == "150"
      assert amount(Table.quote(request([parcel(30_000)]), ctx())) == "400"
    end

    test "heavier than the last band is too heavy" do
      assert {:error, :too_heavy} = Table.quote(request([parcel(30_001)]), ctx())
    end

    test "sums the weight of several parcels" do
      assert amount(Table.quote(request([parcel(400), parcel(400)]), ctx())) == "90"
    end

    test "no parcels costs the first band" do
      assert amount(Table.quote(request([]), ctx())) == "70"
    end

    test "decimal commas in the rates" do
      ctx = ctx(%{"rates" => "0,5 70,50\n2 100"})

      assert amount(Table.quote(request([parcel(400)]), ctx)) == "70.50"
    end

    test "no usable rates" do
      assert {:error, :no_rates} = Table.quote(request([parcel(1)]), ctx(%{"rates" => "junk"}))
      assert {:error, :no_rates} = Table.quote(request([parcel(1)]), ctx(%{"rates" => nil}))
    end

    test "quote metadata" do
      assert {:ok, %Quote{} = quote} = Table.quote(request([parcel(750)]), ctx())

      assert quote.source == :table
      assert quote.currency == "UAH"
      assert quote.eta == nil

      assert quote.breakdown == %{
               "actual_kg" => "0.75",
               "billable_kg" => "0.75",
               "rate_up_to_kg" => "1"
             }
    end

    test "context currency wins" do
      ctx = %{ctx() | currency: "USD"}
      assert {:ok, %Quote{currency: "USD"}} = Table.quote(request([parcel(1)]), ctx)
    end
  end

  describe "quote/2 volumetric weight" do
    # 400x300x200 mm = 24 000 cm3 -> 4.8 kg at a divisor of 5000
    @big [400, 300, 200]

    test "is ignored when the divisor is missing or zero" do
      assert amount(Table.quote(request([parcel(500, @big)]), ctx())) == "70"

      assert amount(
               Table.quote(request([parcel(500, @big)]), ctx(%{"volumetric_divisor" => "0"}))
             ) == "70"
    end

    test "raises the billable weight above the actual one" do
      ctx = ctx(%{"volumetric_divisor" => "5000"})

      assert {:ok, %Quote{amount: amount, breakdown: breakdown}} =
               Table.quote(request([parcel(500, @big)]), ctx)

      assert Decimal.equal?(amount, 150)
      assert breakdown["actual_kg"] == "0.5"
      assert breakdown["billable_kg"] == "4.8"
    end

    test "never lowers the weight" do
      ctx = ctx(%{"volumetric_divisor" => "5000"})

      assert amount(Table.quote(request([parcel(4000, [100, 100, 100])]), ctx)) == "150"
    end

    test "a heavy volumetric weight can make the parcel too heavy" do
      ctx = ctx(%{"volumetric_divisor" => "1000"})

      assert {:error, :too_heavy} = Table.quote(request([parcel(500, [800, 600, 100])]), ctx)
    end

    test "parcels without dimensions use the actual weight" do
      ctx = ctx(%{"volumetric_divisor" => "5000"})

      assert amount(Table.quote(request([parcel(500)]), ctx)) == "70"
    end

    test "a divisor with a decimal comma" do
      ctx = ctx(%{"volumetric_divisor" => "5000,0"})

      assert amount(Table.quote(request([parcel(500, @big)]), ctx)) == "150"
    end
  end

  describe "quote/2 eta" do
    test "comes from the settings" do
      ctx = ctx(%{"eta_min_days" => "1", "eta_max_days" => 3})

      assert {:ok, %Quote{eta: %{min_days: 1, max_days: 3, date: nil}}} =
               Table.quote(request([parcel(100)]), ctx)
    end

    test "a single bound fills both" do
      assert {:ok, %Quote{eta: %{min_days: 2, max_days: 2}}} =
               Table.quote(request([parcel(100)]), ctx(%{"eta_min_days" => "2"}))
    end

    test "is nil when not set" do
      assert {:ok, %Quote{eta: nil}} = Table.quote(request([parcel(100)]), ctx())
    end
  end
end
