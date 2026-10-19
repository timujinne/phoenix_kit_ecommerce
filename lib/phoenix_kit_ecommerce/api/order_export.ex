defmodule PhoenixKitEcommerce.API.OrderExport do
  @moduledoc """
  An order as an external system reads it: one JSON-ready map (string keys,
  money as decimal strings) that the order tools answer with and that a caller
  can send as the body of a push to the external system.

      OrderExport.serialize(order, contacts: true)
      OrderExport.serialize_many(orders, include: [:lines, :payment])

  The map holds `id`, `number`, `status`, the timestamps, `currency`, `totals`
  (`subtotal`, `discount`, `shipping`, `tax`, `total`), `sync`, `notes` (with
  contacts only) and the sections `lines`, `shipping`, `payment` and `customer`.

  There is no flag saying whether prices include tax: the shop has no such
  setting, it works out `tax` from its tax rate and adds it to `total`. A caller
  reads `totals.tax` and the `taxable` flag of each line.

  ## Options

    * `:include` - the sections to build, any of `:lines`, `:shipping`,
      `:payment`, `:customer`; all four by default.
    * `:contacts` - whether the buyer-entered data is included: in `customer`
      the name, phone, email, company, tax id and address, in `shipping` the
      delivery address, and the order's `notes`. Without it `customer` holds
      only the buyer's `id` and `type`, the delivery address is `nil` and
      `notes` is absent, so a caller without the right to personal data cannot
      get it by asking for a section. Default `false`.

  ## Lines

  A product line is any order line that is not the shipping charge, numbered
  from 1 in order. `taxable` is whether the product was subject to tax when it
  was bought; a line recorded before the shop kept that (or written by hand)
  reads as `true`, the product default. `sku`, `external_id` and `unit` come from the catalogue item
  at the time of the call; the `sku` the order line itself recorded at purchase
  is `sku_at_order`, present only when the two differ. A line of a product the
  catalogue no longer has keeps the recorded `sku`, and has no `external_id`.

  ## Sync

  The `sync` block is `PhoenixKitBilling.Order.sync/1`: `state` is `pending`
  for an order without a mark and for one that changed after its mark, so it
  tells a caller whether the order must be taken (again).
  """

  import Ecto.Query, warn: false

  # Optional dependency, and a billing older than `Order.sync/1`.
  @compile {:no_warn_undefined,
            [PhoenixKitCatalogue.Schemas.Item, {PhoenixKitBilling.Order, :sync, 1}]}

  alias PhoenixKit.RepoHelper
  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.API.Money
  alias PhoenixKitEcommerce.ShippingMethod

  @sections [:lines, :shipping, :payment, :customer]

  @doc "The sections `:include` can name."
  @spec sections() :: [atom()]
  def sections, do: @sections

  @doc "The order as a map; see the moduledoc for the options."
  @spec serialize(struct(), keyword()) :: map()
  def serialize(%Order{} = order, opts \\ []), do: [order] |> serialize_many(opts) |> hd()

  @doc "Several orders, looking the catalogue items and shipping methods up once."
  @spec serialize_many([struct()], keyword()) :: [map()]
  def serialize_many(orders, opts \\ [])
  def serialize_many([], _opts), do: []

  def serialize_many(orders, opts) when is_list(orders) do
    include = Keyword.get(opts, :include, @sections)
    contacts? = Keyword.get(opts, :contacts, false) == true
    orders = preload(orders)

    lookups = %{
      items: if(:lines in include, do: items_of(orders), else: %{}),
      methods: if(:shipping in include, do: methods_of(orders), else: %{})
    }

    Enum.map(orders, &build(&1, include, contacts?, lookups))
  end

  defp preload(orders), do: RepoHelper.repo().preload(orders, [:billing_profile, :payment_option])

  defp build(order, include, contacts?, lookups) do
    shipping_lines = Enum.filter(lines_of(order), &shipping_line?/1)

    %{
      "id" => order.uuid,
      "number" => order.order_number,
      "status" => order.status,
      "created_at" => time(order.inserted_at),
      "updated_at" => time(order.updated_at),
      "confirmed_at" => time(order.confirmed_at),
      "paid_at" => time(order.paid_at),
      "cancelled_at" => time(order.cancelled_at),
      "currency" => order.currency,
      "totals" => totals(order, shipping_lines),
      "sync" => Order.sync(order)
    }
    |> put_notes(order, contacts?)
    |> put_section(:lines, include, fn -> lines(order, lookups.items) end)
    |> put_section(:shipping, include, fn ->
      shipping(order, shipping_lines, lookups.methods, contacts?)
    end)
    |> put_section(:payment, include, fn -> payment(order) end)
    |> put_section(:customer, include, fn -> customer(order, contacts?) end)
  end

  # The buyer types the notes, and what they type is often a phone number or an
  # address: they go with the contacts, and without them the key is absent.
  defp put_notes(map, order, true), do: Map.put(map, "notes", order.notes)
  defp put_notes(map, _order, false), do: map

  defp put_section(map, section, include, build) do
    if section in include, do: Map.put(map, Atom.to_string(section), build.()), else: map
  end

  # -- totals -----------------------------------------------------------------

  defp totals(order, shipping_lines) do
    shipping =
      Enum.reduce(shipping_lines, Decimal.new(0), fn line, sum ->
        Decimal.add(sum, Money.to_decimal(line["total"]) || Decimal.new(0))
      end)

    %{
      "subtotal" => Money.format(order.subtotal),
      "discount" => Money.format(order.discount_amount),
      "shipping" => Money.format(shipping),
      "tax" => Money.format(order.tax_amount),
      "total" => Money.format(order.total)
    }
  end

  # -- lines ------------------------------------------------------------------

  defp lines_of(%Order{line_items: items}) when is_list(items), do: Enum.filter(items, &is_map/1)
  defp lines_of(_order), do: []

  defp shipping_line?(line), do: line["type"] == "shipping"

  defp lines(order, items) do
    order
    |> lines_of()
    |> Enum.reject(&shipping_line?/1)
    |> Enum.with_index(1)
    |> Enum.map(fn {line, number} -> line(line, number, Map.get(items, line_item_uuid(line))) end)
  end

  defp line(line, number, item) do
    recorded_sku = blank_to_nil(line["sku"])
    sku = (item && blank_to_nil(item.sku)) || recorded_sku

    %{
      "line" => number,
      "product_id" => line_item_uuid(line),
      "sku" => sku,
      "external_id" => item && item.external_id,
      "name" => line["name"],
      "quantity" => quantity(line["quantity"]),
      "unit" => (item && item.unit) || "piece",
      "unit_price" => amount(line["unit_price"]),
      "total" => amount(line["total"]),
      "taxable" => line["taxable"] != false,
      "price_on_request" => line["price_on_request"] == true
    }
    |> put_sku_at_order(sku, recorded_sku)
  end

  defp put_sku_at_order(line, sku, recorded_sku) when sku != recorded_sku,
    do: Map.put(line, "sku_at_order", recorded_sku)

  defp put_sku_at_order(line, _sku, _recorded_sku), do: line

  defp line_item_uuid(line) do
    case line["catalogue_item_uuid"] do
      uuid when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  defp quantity(value) do
    case Money.to_decimal(value) do
      nil -> to_string(value)
      decimal -> decimal |> Decimal.normalize() |> Decimal.to_string(:normal)
    end
  end

  defp amount(value) do
    case Money.to_decimal(value) do
      nil -> nil
      decimal -> Money.format(decimal)
    end
  end

  # The catalogue is an optional dependency: without it, or for a line of the
  # legacy product source, the recorded line is all there is.
  defp items_of(orders) do
    uuids =
      for order <- orders, line <- lines_of(order), uuid = line_item_uuid(line), uniq: true do
        uuid
      end

    if uuids != [] and Code.ensure_loaded?(PhoenixKitCatalogue.Schemas.Item) do
      from(i in PhoenixKitCatalogue.Schemas.Item,
        where: i.uuid in ^uuids,
        select: %{uuid: i.uuid, sku: i.sku, unit: i.unit, data: i.data}
      )
      |> RepoHelper.repo().all()
      |> Map.new(fn item -> {item.uuid, Map.put(item, :external_id, external_id(item.data))} end)
    else
      %{}
    end
  end

  defp external_id(%{"api" => %{"external_id" => id}}) when is_binary(id) and id != "", do: id
  defp external_id(_data), do: nil

  # -- shipping ---------------------------------------------------------------

  defp methods_of(orders) do
    uuids =
      for order <- orders,
          uuid = metadata(order)["shipping_method_uuid"],
          is_binary(uuid),
          uniq: true do
        uuid
      end

    if uuids == [] do
      %{}
    else
      from(m in ShippingMethod, where: m.uuid in ^uuids)
      |> RepoHelper.repo().all()
      |> Map.new(&{&1.uuid, &1})
    end
  end

  defp shipping(order, shipping_lines, methods, contacts?) do
    metadata = metadata(order)
    method = Map.get(methods, metadata["shipping_method_uuid"])
    line = List.first(shipping_lines)

    if is_nil(method) and is_nil(line) do
      nil
    else
      provider = map_or_empty(metadata["shipping_provider"])

      %{
        "method_id" => metadata["shipping_method_uuid"],
        "method_code" => method && method.slug,
        "name" => (method && method.name) || (line && line["name"]),
        "provider" => provider["provider"],
        "service" => provider["service"],
        "destination" => destination(metadata["shipping_destination"], contacts?),
        "pay_on_delivery" => metadata["shipping_pay_on_delivery"] == true,
        "amount" => line && amount(line["total"])
      }
    end
  end

  # The city and the pickup point (a branch or a locker) are public places. The
  # buyer's own delivery address is personal data and goes with the contacts only.
  defp destination(%{} = destination, contacts?) do
    locality = map_or_empty(destination["locality"])
    point = map_or_empty(destination["pickup_point"])
    address = if contacts?, do: map_or_empty(destination["address"]), else: %{}

    %{
      "city" => locality["name"],
      "city_ref" => locality["id"],
      "warehouse" => point["name"] || point["number"],
      "warehouse_ref" => point["id"],
      "country" => locality["country"],
      "postcode" => address["postcode"] || point["postcode"] || locality["postcode"],
      "address" => address_line(address) || point["address"]
    }
  end

  defp destination(_other, _contacts?), do: nil

  # A free-text line when the buyer typed one, otherwise street, house and
  # apartment joined, as the shop shows it.
  defp address_line(address) do
    case blank_to_nil(address["line"]) do
      nil ->
        [address["street"], address["house"], address["apartment"]]
        |> Enum.map(&blank_to_nil/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")
        |> blank_to_nil()

      line ->
        line
    end
  end

  # -- payment ----------------------------------------------------------------

  defp payment(order) do
    option = order.payment_option

    %{
      "option_code" => metadata(order)["payment_option_code"] || (option && option.code),
      "name" => option && option.name,
      "status" => payment_status(order)
    }
  end

  defp payment_status(%Order{status: "refunded"}), do: "refunded"
  defp payment_status(%Order{status: "paid"}), do: "paid"
  defp payment_status(%Order{paid_at: %DateTime{}}), do: "paid"
  defp payment_status(_order), do: "unpaid"

  # -- customer ---------------------------------------------------------------

  defp customer(order, contacts?) do
    base = %{
      "type" => if(guest?(order), do: "guest", else: "user"),
      "id" => order.user_uuid
    }

    if contacts?, do: Map.merge(base, contact_details(order)), else: base
  end

  defp guest?(order), do: metadata(order)["guest_checkout"] == true or is_nil(order.user_uuid)

  defp contact_details(order) do
    snapshot = map_or_empty(order.billing_snapshot)
    field = &contact_field(snapshot, order.billing_profile, &1)

    %{
      "first_name" => field.(:first_name),
      "last_name" => field.(:last_name),
      "middle_name" => field.(:middle_name),
      "phone" => field.(:phone),
      "email" => field.(:email) || blank_to_nil(metadata(order)["guest_checkout_email"]),
      "company" => field.(:company_name),
      "tax_id" => field.(:company_vat_number),
      "address" => %{
        "country" => field.(:country),
        "city" => field.(:city),
        "postal_code" => field.(:postal_code),
        "line1" => field.(:address_line1),
        "line2" => field.(:address_line2)
      }
    }
  end

  # The snapshot is what the order was billed to; the profile only fills what
  # the snapshot lacks.
  defp contact_field(snapshot, profile, key) do
    blank_to_nil(snapshot[Atom.to_string(key)]) ||
      (profile && blank_to_nil(Map.get(profile, key)))
  end

  # -- helpers ----------------------------------------------------------------

  defp metadata(%Order{metadata: %{} = metadata}), do: metadata
  defp metadata(_order), do: %{}

  defp map_or_empty(%{} = map), do: map
  defp map_or_empty(_other), do: %{}

  defp blank_to_nil(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp blank_to_nil(_value), do: nil

  defp time(nil), do: nil
  defp time(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp time(%NaiveDateTime{} = value),
    do: value |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
end
