defmodule PhoenixKitEcommerce.CartItem do
  @moduledoc """
  Cart item schema with price snapshot for consistency.

  When a product is added to the cart, we snapshot the current price and product
  details. This ensures that:

  1. Price changes after adding don't affect the cart total unexpectedly
  2. If the product is deleted, we still have the title and other info
  3. We can show users when prices have changed since they added items

  ## Fields

  - `cart_uuid` - Reference to the cart (required)
  - `product_uuid` - Reference to the product (nullable, ON DELETE SET NULL)
  - `product_title` - Product title snapshot (required)
  - `product_slug` - Product slug snapshot
  - `product_sku` - Product SKU snapshot
  - `product_image` - Product image URL snapshot
  - `unit_price` - Price per unit at time of adding (required)
  - `compare_at_price` - Original price for showing discounts
  - `quantity` - Number of items (required, > 0)
  - `line_total` - Calculated: unit_price * quantity
  - `weight_grams` - Weight for shipping calculation
  - `taxable` - Whether item is taxable
  - `selected_specs` - JSON object for specification-based pricing (e.g., {"material": "PETG", "color": "Gold"})
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Product

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  schema "phoenix_kit_shop_cart_items" do
    belongs_to :cart, Cart, foreign_key: :cart_uuid, references: :uuid, type: UUIDv7
    belongs_to :product, Product, foreign_key: :product_uuid, references: :uuid, type: UUIDv7
    field :variant_uuid, UUIDv7

    # Snapshot
    field :product_title, :string
    field :product_slug, :string
    field :product_sku, :string
    field :product_image, :string

    # Pricing (snapshot)
    field :unit_price, :decimal
    field :compare_at_price, :decimal
    field :currency, :string

    # Quantity
    field :quantity, :integer, default: 1

    # Calculated
    field :line_total, :decimal

    # Physical
    field :weight_grams, :integer, default: 0
    field :taxable, :boolean, default: true

    # Specification-based pricing
    field :selected_specs, :map, default: %{}

    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for cart item creation and updates.
  """
  def changeset(item, attrs) do
    item
    |> cast(attrs, [
      :cart_uuid,
      :product_uuid,
      :variant_uuid,
      :product_title,
      :product_slug,
      :product_sku,
      :product_image,
      :unit_price,
      :compare_at_price,
      :currency,
      :quantity,
      :line_total,
      :weight_grams,
      :taxable,
      :selected_specs,
      :metadata
    ])
    |> validate_required([:cart_uuid, :product_title, :unit_price, :quantity, :currency])
    |> validate_number(:quantity, greater_than: 0)
    |> validate_number(:unit_price, greater_than_or_equal_to: 0)
    |> validate_length(:currency, is: 3)
    |> calculate_line_total()
    |> foreign_key_constraint(:cart_uuid)
    |> foreign_key_constraint(:product_uuid)
  end

  @doc """
  Creates changeset attributes from a product.

  ## Parameters

    - `product` - The Product struct
    - `quantity` - Number of items (default: 1)
    - `language` - Language code for localized fields (default: system default)

  ## Examples

      iex> from_product(product, 2)
      %{
        product_uuid: "01234567-...",
        product_title: "Widget",
        product_slug: "widget",
        unit_price: Decimal.new("19.99"),
        quantity: 2,
        ...
      }

      iex> from_product(product, 1, "ru")
      %{product_title: "Виджет", product_slug: "vidzhet", ...}
  """
  def from_product(product, quantity \\ 1, language_or_opts \\ nil)

  def from_product(%Product{} = product, quantity, opts) when is_list(opts) do
    lang = Keyword.get(opts, :language) || default_language()

    %{
      product_uuid: product.uuid,
      product_title: get_localized_string(product.title, lang),
      product_slug: get_localized_string(product.slug, lang),
      product_image: get_product_image_url(product),
      # An on-request line carries NO amount. The product keeps its price —
      # that is the figure the operator quotes from — but the customer never
      # saw it and never agreed to it, so it must not enter a cart total, an
      # order total or an invoice. Suppressing the number per-line while the
      # total still summed it was incoherent: the cart said "Price on request"
      # and then printed the sum of the very numbers it had just hidden.
      unit_price: if(PriceDisplay.on_request?(product), do: Decimal.new(0), else: product.price),
      compare_at_price:
        if(PriceDisplay.on_request?(product), do: nil, else: product.compare_at_price),
      # Line amounts are summed in the CART's currency frame, so the line
      # snapshots that frame when the caller supplies it; the product's own
      # currency field is usually the schema's untouched default.
      currency: Keyword.get(opts, :currency) || product.currency,
      quantity: quantity,
      weight_grams: product.weight_grams || 0,
      taxable: product.taxable,
      # Snapshotted so cart/checkout logic survives product edits and
      # deletion (product_uuid is ON DELETE SET NULL). Absent on rows
      # created before this shipped - readers fall back to the live
      # product, and only a MISSING product defaults to "requires".
      metadata:
        %{"requires_shipping" => product.requires_shipping}
        |> put_price_unit(product, lang)
    }
  end

  def from_product(%Product{} = product, quantity, language) do
    from_product(product, quantity, language: language)
  end

  # The unit is snapshotted with the line, not read live at render time:
  # cart lines survive product edits and deletion (product_uuid is
  # ON DELETE SET NULL), and a line the customer agreed to must not be
  # relabelled afterwards.
  defp put_price_unit(metadata, product, lang) do
    metadata =
      case PriceDisplay.unit_for(product, lang) do
        nil -> metadata
        unit -> Map.put(metadata, "price_unit", unit)
      end

    put_price_on_request(metadata, product)
  end

  # "Price on request" is snapshotted for the same reason the unit is, and the
  # consequence of NOT doing so is worse: the flag only suppresses a number that
  # still exists on the product, so a line whose flag was lost falls back to
  # formatting its stored unit_price — typically 0 — and renders "0.00" where the
  # customer agreed to "price on request". Free, permanently, on a committed
  # order. Only written when true, so existing rows keep their shape.
  defp put_price_on_request(metadata, product) do
    if PriceDisplay.on_request?(product) do
      Map.put(metadata, "price_on_request", true)
    else
      metadata
    end
  end

  # Get product image URL, preferring new Storage system over legacy
  defp get_product_image_url(%Product{featured_image_uuid: id}) when is_binary(id) do
    alias PhoenixKit.Modules.Storage.URLSigner

    try do
      URLSigner.signed_url(id, "medium")
    rescue
      _ -> nil
    end
  end

  defp get_product_image_url(%Product{featured_image: url}) when is_binary(url), do: url
  defp get_product_image_url(_), do: nil

  # Extract string from localized JSONB map field
  defp get_localized_string(nil, _lang), do: nil
  defp get_localized_string(value, _lang) when is_binary(value), do: value

  defp get_localized_string(map, lang) when is_map(map) do
    map[lang] || map[default_language()] || first_value(map)
  end

  defp get_localized_string(_value, _lang), do: nil

  defp first_value(map) when map == %{}, do: nil
  defp first_value(map), do: map |> Map.values() |> List.first()

  defp default_language do
    alias PhoenixKitEcommerce.Translations
    Translations.default_language()
  end

  @doc """
  Returns true if product data has changed since the item was added.
  Useful for showing price change warnings.
  """
  def product_changed?(%__MODULE__{product_uuid: nil}, _product), do: true

  def product_changed?(%__MODULE__{} = item, %Product{} = product) do
    Decimal.compare(item.unit_price, product.price) != :eq
  end

  @doc """
  Returns the price difference if the product price has changed.
  Positive = price increased, Negative = price decreased.
  """
  def price_difference(%__MODULE__{} = item, %Product{} = product) do
    Decimal.sub(product.price, item.unit_price)
  end

  @doc """
  Returns true if this item is on sale (has compare_at_price > unit_price).
  """
  def on_sale?(%__MODULE__{compare_at_price: nil}), do: false

  def on_sale?(%__MODULE__{compare_at_price: compare, unit_price: price}) do
    Decimal.compare(compare, price) == :gt
  end

  @doc """
  Returns discount percentage for sale items.
  """
  def discount_percentage(%__MODULE__{} = item) do
    if on_sale?(item) do
      diff = Decimal.sub(item.compare_at_price, item.unit_price)

      diff
      |> Decimal.div(item.compare_at_price)
      |> Decimal.mult(100)
      |> Decimal.round(0)
      |> Decimal.to_integer()
    else
      0
    end
  end

  @doc """
  Returns true if the product has been deleted (product_uuid is nil after SET NULL).
  """
  def product_deleted?(%__MODULE__{product_uuid: nil}), do: true
  def product_deleted?(_), do: false

  # Private helpers

  defp calculate_line_total(changeset) do
    quantity = get_field(changeset, :quantity) || 1
    unit_price = get_field(changeset, :unit_price) || Decimal.new("0")
    line_total = Decimal.mult(unit_price, quantity)
    put_change(changeset, :line_total, line_total)
  end
end
