defmodule PhoenixKitEcommerce.API.CartView do
  @moduledoc """
  What an agent sees of a cart: lines, totals, shipping,
  thresholds, a revision, and the difference between two revisions.

  `build/1` needs a cart with its lines and shipping method preloaded (every
  cart `API.CartStore` hands out is). Nothing here writes.

  A line agreed as "price on request" carries `price_on_request: true` and no
  prices, and the view says `totals_incomplete: true`: the totals are what
  billing will charge, and they leave such a line out.

  The **revision** is a hash of the lines (product id, neutral options,
  quantity) and the shipping choice, not of prices: a price move
  must not make an agent's `expected_revision` stale. A **snapshot** is the
  material of that hash (`"lines"` and `"shipping"`); `API.CartStore` keeps the
  last 10 stamped snapshots so `changes/2` can say what happened since an
  older revision.
  """

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartMoney
  alias PhoenixKitEcommerce.API.CartOptions
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.SelectedSpecs
  alias PhoenixKitEcommerce.ShippingMethod

  @doc """
  The view of an active cart. `language` is the one the option labels of the
  lines are written in (`nil`: the product source's default).
  """
  @spec build(Cart.t(), String.t() | nil) :: map()
  def build(%Cart{} = cart, language \\ nil) do
    ensure_loaded!(cart)
    items = sorted_items(cart)
    records = records_by_id(items, language)

    %{
      status: "open",
      revision: revision(cart),
      read_at: now_iso(),
      currency: cart.currency,
      lines: Enum.map(items, &line(&1, cart, records)),
      totals: totals(cart),
      totals_incomplete: PriceDisplay.any_line_on_request?(cart.items),
      shipping: shipping(cart),
      thresholds: thresholds(cart)
    }
  end

  # An unloaded shipping method would read as "no method chosen" and an unloaded
  # item list as an empty cart; a view must never invent that.
  defp ensure_loaded!(%Cart{items: items, shipping_method: method}) do
    unless Ecto.assoc_loaded?(items) and Ecto.assoc_loaded?(method) do
      raise ArgumentError, "CartView needs a cart with its items and shipping method preloaded"
    end

    :ok
  end

  @doc "The view of a token that has not written yet: an empty open cart."
  @spec empty(String.t() | nil) :: map()
  def empty(currency) do
    zero = Decimal.new(0)
    money = CartMoney.new(zero, currency)

    %{
      status: "open",
      revision: revision(nil),
      read_at: now_iso(),
      currency: currency,
      lines: [],
      totals_incomplete: false,
      totals: %{subtotal: money, discount: money, shipping: money, tax: money, total: money},
      shipping: %{country: nil, method: nil},
      thresholds: []
    }
  end

  @doc "The view of a claimed cart: `checking_out`, and no lines."
  @spec locked(String.t() | nil) :: map()
  def locked(currency) do
    %{status: "checking_out", revision: nil, read_at: now_iso(), currency: currency, lines: []}
  end

  @doc """
  Drops every `nil` value of a response, at any depth (lists are walked; empty
  lists, `false` and `0` stay). The public read tools omit nil values and the
  declared output schemas have no nullable types, so a client that validates
  `structuredContent` against `outputSchema` must not meet an explicit null
  (a claimed cart's revision, the product id of a line whose product was
  deleted, a shipping method's `reason`). Applied by `API.CartHandlers` to
  every success and preview answer; the views themselves keep their keys.
  """
  @spec compact(term()) :: term()
  def compact(%{} = map) when not is_struct(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new(fn {key, value} -> {key, compact(value)} end)
  end

  def compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  def compact(other), do: other

  @doc "The totals of a cart as money objects in the cart's currency."
  @spec totals(Cart.t()) :: map()
  def totals(%Cart{} = cart) do
    zero = Decimal.new(0)
    money = fn amount -> CartMoney.new(amount || zero, cart.currency) end

    %{
      subtotal: money.(cart.subtotal),
      discount: money.(cart.discount_amount),
      shipping: money.(cart.shipping_amount),
      tax: money.(cart.tax_amount),
      total: money.(cart.total)
    }
  end

  @doc """
  The id of the product behind a line: the catalogue item uuid for a
  catalogue-backed line (its `product_uuid` column is nil), else the legacy
  product uuid, nil when the product has been deleted.
  """
  @spec line_product_id(CartItem.t()) :: String.t() | nil
  def line_product_id(%CartItem{metadata: metadata, product_uuid: product_uuid}) do
    (metadata || %{})["catalogue_item_uuid"] || product_uuid
  end

  # --- revision, snapshots, changes -------------------------------------------

  @doc "The revision of a cart (`nil` = the empty cart of a token without a row)."
  @spec revision(Cart.t() | nil) :: String.t()
  def revision(cart_or_nil), do: cart_or_nil |> snapshot() |> revision_of()

  @doc "The material of a revision: sorted lines and the shipping choice."
  @spec snapshot(Cart.t() | nil) :: map()
  def snapshot(nil), do: raw_snapshot([], nil, nil)

  def snapshot(%Cart{} = cart) do
    lines =
      cart.items
      |> Enum.map(&snapshot_line/1)
      |> Enum.sort_by(&{&1["product_id"] || "", &1["options"], &1["item"] || ""})

    raw_snapshot(lines, cart.shipping_method_uuid, cart.shipping_country)
  end

  # A line whose product is gone has no product id to tell it from another such
  # line with the same options, so it carries its own item uuid.
  defp snapshot_line(item) do
    product_id = line_product_id(item)

    line = %{
      "product_id" => product_id,
      "options" => item |> CartOptions.from_item(nil) |> CartOptions.canonical(),
      "quantity" => item.quantity
    }

    if product_id, do: line, else: Map.put(line, "item", item.uuid)
  end

  defp raw_snapshot(lines, method, country) do
    %{"lines" => lines, "shipping" => %{"method" => method, "country" => country}}
  end

  @doc ~S|A snapshot with its "revision" and the time it was taken ("at"), ready to store.|
  @spec stamp(map()) :: map()
  def stamp(snapshot) do
    Map.merge(snapshot, %{"revision" => revision_of(snapshot), "at" => now_iso()})
  end

  defp revision_of(%{"lines" => lines, "shipping" => shipping}) do
    material = [
      Enum.map(lines, &[&1["product_id"], &1["options"], &1["quantity"]]),
      [shipping["method"], shipping["country"]]
    ]

    :sha256
    |> :crypto.hash(Jason.encode!(material))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  What changed from `old` to `new` (two snapshots): `added`, `removed` and
  `changed` lines (each `%{product_id, options, from, to}`, `from`/`to` are
  quantities) and `shipping` (`%{from: %{method, country}, to: ...}` or nil).
  """
  @spec changes(map(), map()) :: map()
  def changes(old, new) do
    old_lines = index(old["lines"])
    new_lines = index(new["lines"])

    added =
      for {key, line} <- new_lines,
          not Map.has_key?(old_lines, key),
          do: change(line, nil, line["quantity"])

    removed =
      for {key, line} <- old_lines,
          not Map.has_key?(new_lines, key),
          do: change(line, line["quantity"], nil)

    changed = Enum.flat_map(new_lines, fn {key, line} -> changed_line(line, old_lines[key]) end)

    %{
      added: ordered(added),
      removed: ordered(removed),
      changed: ordered(changed),
      shipping: shipping_change(old, new)
    }
  end

  defp ordered(changes), do: Enum.sort_by(changes, &{&1.product_id || "", &1.options})

  defp changed_line(_line, nil), do: []
  defp changed_line(%{"quantity" => same}, %{"quantity" => same}), do: []
  defp changed_line(line, old_line), do: [change(line, old_line["quantity"], line["quantity"])]

  defp index(lines), do: Map.new(lines, &{{&1["product_id"], &1["options"], &1["item"]}, &1})

  defp change(line, from, to) do
    %{
      product_id: line["product_id"],
      options:
        Enum.map(line["options"], fn [key, value] -> %{attribute_key: key, value_key: value} end),
      from: from,
      to: to
    }
  end

  defp shipping_change(%{"shipping" => same}, %{"shipping" => same}), do: nil

  defp shipping_change(%{"shipping" => old}, %{"shipping" => new}) do
    %{
      from: %{method: old["method"], country: old["country"]},
      to: %{method: new["method"], country: new["country"]}
    }
  end

  # --- lines ----------------------------------------------------------------

  defp sorted_items(%Cart{items: items}) do
    Enum.sort_by(items, &{DateTime.to_unix(&1.inserted_at), &1.uuid})
  end

  # One batch read through the public API's loader, so a line is "ok" exactly
  # when `shop.get_products` would list its product and the cart would accept
  # it again (the one visibility rule, `API.Visibility`).
  defp records_by_id(items, language) do
    ids = items |> Enum.map(&line_product_id/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    Loader.load(ids, if(language, do: [language: language], else: []))
  end

  @doc """
  The options of each line of `cart` with their labels in `language`, by item
  uuid: what the claim page shows. See `build/2` and `CartOptions.labelled/3`.
  """
  @spec labelled_options(Cart.t(), String.t() | nil) :: %{String.t() => [CartOptions.labelled()]}
  def labelled_options(%Cart{} = cart, language) do
    ensure_loaded!(cart)
    items = sorted_items(cart)
    records = records_by_id(items, language)

    Map.new(items, fn item ->
      record = Map.get(records, Loader.canonical_uuid(line_product_id(item)))
      {item.uuid, labelled(item, record && record.product)}
    end)
  end

  defp labelled(%CartItem{} = item, product) do
    item
    |> CartOptions.from_item(product)
    |> CartOptions.labelled(product, SelectedSpecs.labels(item))
  end

  defp line(%CartItem{} = item, %Cart{} = cart, records) do
    product_id = line_product_id(item)
    record = Map.get(records, Loader.canonical_uuid(product_id))
    product = record && record.product
    on_request? = PriceDisplay.line_on_request?(item)

    %{
      product_id: product_id,
      title: item.product_title,
      options: labelled(item, product),
      quantity: item.quantity,
      price_on_request: on_request?,
      unit_price: line_money(on_request?, item.unit_price, cart.currency),
      line_total: line_money(on_request?, item.line_total, cart.currency),
      status: if(record && record.state == :listed, do: "ok", else: "unavailable")
    }
  end

  # A line agreed as "price on request" snapshots a price of 0, which is not a
  # price: it is left out, so it can never read as a free line.
  defp line_money(true, _amount, _currency), do: nil
  defp line_money(false, amount, currency), do: CartMoney.new(amount, currency)

  # --- shipping and thresholds ------------------------------------------------

  defp shipping(%Cart{shipping_method: %ShippingMethod{} = method} = cart) do
    shown = Shop.present_shipping_method(cart, method)

    %{
      country: cart.shipping_country,
      method: %{
        id: method.uuid,
        name: method.name,
        price: shipping_price(shown, cart.currency),
        free: shown.free?,
        pay_on_delivery: shown.pay_on_delivery?,
        calculated: ShippingMethod.calculated?(method),
        quote_status: Atom.to_string(shown.quote_status)
      }
    }
  end

  defp shipping(%Cart{} = cart), do: %{country: cart.shipping_country, method: nil}

  # The price of a carrier method is the carrier's: it exists once the buyer has
  # picked a destination at checkout. Until then `price` would be the method's
  # fallback figure, which is not what the buyer will pay, so it is left out.
  defp shipping_price(%{quote_status: status} = shown, currency)
       when status in [:not_needed, :ok, :fallback],
       do: CartMoney.new(shown.price, currency)

  defp shipping_price(_pending, _currency), do: nil

  defp thresholds(%Cart{items: [_ | _]} = cart) do
    case threshold_method(cart) do
      nil -> []
      %ShippingMethod{} = method -> threshold_rows(cart, method)
    end
  end

  defp thresholds(_cart), do: []

  defp threshold_method(%Cart{shipping_method: %ShippingMethod{} = method}), do: method

  defp threshold_method(%Cart{} = cart) do
    case Shop.get_available_shipping_methods(cart) do
      [] ->
        nil

      methods ->
        Enum.min_by(
          methods,
          &(&1.price || Decimal.new(0)),
          &(Decimal.compare(&1, &2) != :gt)
        )
    end
  end

  defp threshold_rows(%Cart{} = cart, %ShippingMethod{} = method) do
    base_code = cart.base_currency || cart.currency
    current = cart.subtotal || Decimal.new(0)
    current_base = Shop.cart_amount_to_base(cart, current)

    [
      {"min_order", method.min_order_amount},
      {"max_order", method.max_order_amount},
      {"free_shipping", method.free_above_amount}
    ]
    |> Enum.reject(fn {_type, base} -> is_nil(base) end)
    |> Enum.map(fn {type, base} ->
      remaining_base = Decimal.max(Decimal.sub(base, current_base), Decimal.new(0))

      %{
        type: type,
        method: method.uuid,
        base: CartMoney.new(base, base_code),
        current: CartMoney.new(current, cart.currency),
        remaining: CartMoney.new(Shop.cart_amount_from_base(remaining_base, cart), cart.currency)
      }
    end)
  end

  defp now_iso, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
