defmodule PhoenixKitEcommerce.Web.ShippingDisplayTest do
  @moduledoc """
  The lines a carrier quote becomes for the buyer: the delivery time, the
  reason a method cannot serve a cart, and what an order page keeps of a
  carrier-priced shipping line (the same component serves the confirmation
  page and the order details of the account).
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias PhoenixKitEcommerce.Web.Components.ShippingDisplay

  describe "eta_text/1" do
    test "a date" do
      assert ShippingDisplay.eta_text(%{date: ~D[2026-10-12]}) =~ "2026-10-12"
      assert ShippingDisplay.eta_text(%{"date" => "2026-10-12"}) =~ "2026-10-12"
    end

    test "a range of days, or one number" do
      assert ShippingDisplay.eta_text(%{min_days: 1, max_days: 3, date: nil}) =~ "1–3"
      assert ShippingDisplay.eta_text(%{"min_days" => 2, "max_days" => 2}) =~ "2"
      assert ShippingDisplay.eta_text(%{min_days: nil, max_days: 4, date: nil}) =~ "4"
    end

    test "nothing to say" do
      assert ShippingDisplay.eta_text(nil) == nil
      assert ShippingDisplay.eta_text(%{min_days: nil, max_days: nil, date: nil}) == nil
      assert ShippingDisplay.eta_text("soon") == nil
    end
  end

  describe "unavailable_text/1" do
    test "each reason has its own words, the rest share one" do
      texts =
        for reason <- ~w(too_heavy too_large service_unavailable unsupported_destination) do
          ShippingDisplay.unavailable_text(reason)
        end

      assert length(Enum.uniq(texts)) == 4

      generic = ShippingDisplay.unavailable_text("unknown_provider")
      assert generic == ShippingDisplay.unavailable_text("unknown_service")
      assert generic == ShippingDisplay.unavailable_text(nil)
      refute generic in texts
    end
  end

  describe "order_shipping_details/1" do
    test "where it goes, when, the carrier's fee" do
      item = %{
        "type" => "shipping",
        "destination_label" => "Poltava, Branch 1",
        "eta" => %{"min_days" => 1, "max_days" => 2, "date" => nil}
      }

      metadata = %{
        "shipping_quote" => %{
          "status" => "ok",
          "quote" => %{"amount" => "100", "currency" => "EUR", "cod_fee" => "20"}
        }
      }

      html =
        render_component(&ShippingDisplay.order_shipping_details/1,
          item: item,
          metadata: metadata
        )

      document = LazyHTML.from_fragment(html)

      assert [_] = document |> LazyHTML.query("#order-shipping-destination") |> Enum.to_list()
      assert [_] = document |> LazyHTML.query("#order-shipping-eta") |> Enum.to_list()
      assert [_] = document |> LazyHTML.query("#order-shipping-cod-fee") |> Enum.to_list()
      assert [] = document |> LazyHTML.query("#order-shipping-fallback") |> Enum.to_list()
    end

    test "an estimated price is flagged, a zero fee is not shown" do
      item = %{"type" => "shipping", "destination_label" => "Poltava"}

      metadata = %{
        "shipping_quote" => %{
          "status" => "fallback",
          "quote" => %{"amount" => "7", "currency" => "EUR", "cod_fee" => "0"}
        }
      }

      html =
        render_component(&ShippingDisplay.order_shipping_details/1,
          item: item,
          metadata: metadata
        )

      document = LazyHTML.from_fragment(html)

      assert [_] = document |> LazyHTML.query("#order-shipping-fallback") |> Enum.to_list()
      assert [] = document |> LazyHTML.query("#order-shipping-cod-fee") |> Enum.to_list()
    end

    test "an ordinary line has nothing to add" do
      html =
        render_component(&ShippingDisplay.order_shipping_details/1,
          item: %{"type" => "shipping", "name" => "Shipping: Post"},
          metadata: %{}
        )

      document = LazyHTML.from_fragment(html)
      assert [] = document |> LazyHTML.query("#order-shipping-details") |> Enum.to_list()
    end
  end
end
