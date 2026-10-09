defmodule PhoenixKitEcommerce.ShippingMethod do
  @moduledoc """
  Shipping method schema for E-Commerce module.

  Supports weight-based, price-based, and geographic restrictions.

  ## Fields

  - `name` - Method name (required)
  - `slug` - URL-friendly identifier (unique, auto-generated)
  - `description` - Method description
  - `price` - Shipping cost
  - `free_above_amount` - Free shipping threshold
  - `min_weight_grams`, `max_weight_grams` - Weight limits
  - `min_order_amount`, `max_order_amount` - Order amount limits
  - `countries` - Allowed countries (empty = all)
  - `excluded_countries` - Excluded countries
  - `active` - Enabled/disabled
  - `position` - Sort order
  - `estimated_days_min`, `estimated_days_max` - Delivery estimate
  - `tracking_supported` - Tracking available
  - `metadata["pay_on_delivery"]` - The buyer pays the carrier's own rates on
    delivery; the shop charges nothing (see `pay_on_delivery?/1`)
  - `metadata["shipping_provider"]` - Where the price comes from: a shipping
    provider, its service, settings and markup (see `shipping_config/1` and
    `PhoenixKitEcommerce.Shipping.MethodConfig`). Absent means the fixed
    price of the method, which is how shipping methods always worked
  """

  use Ecto.Schema

  @type t :: %__MODULE__{}
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEcommerce.LocalizedSlug
  alias PhoenixKitEcommerce.Shipping.{MethodConfig, MethodParams}

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @pay_on_delivery_key "pay_on_delivery"
  @shipping_provider_param "shipping_provider"

  schema "phoenix_kit_shop_shipping_methods" do
    field :name, :string
    field :slug, :string
    field :description, :string

    # Pricing
    field :price, :decimal, default: Decimal.new("0")
    field :currency, :string
    field :free_above_amount, :decimal

    # Constraints
    field :min_weight_grams, :integer, default: 0
    field :max_weight_grams, :integer
    field :min_order_amount, :decimal
    field :max_order_amount, :decimal

    # Geographic
    field :countries, {:array, :string}, default: []
    field :excluded_countries, {:array, :string}, default: []

    # Status
    field :active, :boolean, default: true
    field :position, :integer, default: 0

    # Delivery info
    field :estimated_days_min, :integer
    field :estimated_days_max, :integer
    field :tracking_supported, :boolean, default: false

    field :metadata, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  @required_fields [:name, :price]
  @optional_fields [
    :slug,
    :description,
    :currency,
    :free_above_amount,
    :min_weight_grams,
    :max_weight_grams,
    :min_order_amount,
    :max_order_amount,
    :countries,
    :excluded_countries,
    :active,
    :position,
    :estimated_days_min,
    :estimated_days_max,
    :tracking_supported,
    :metadata
  ]

  @doc """
  Changeset for shipping method creation and updates.
  """
  def changeset(method, attrs) do
    attrs = normalize_booleans(attrs, [:active, :tracking_supported])
    {pay_on_delivery, attrs} = pop_pay_on_delivery(attrs)
    {shipping_provider, attrs} = pop_shipping_provider(attrs)

    method
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> put_pay_on_delivery(pay_on_delivery)
    |> put_shipping_provider(shipping_provider)
    |> zero_pay_on_delivery_price()
    |> validate_required(@required_fields)
    |> validate_length(:name, max: 255)
    |> validate_length(:currency, is: 3)
    |> validate_number(:price, greater_than_or_equal_to: 0)
    |> validate_number(:free_above_amount, greater_than: 0)
    |> validate_number(:min_weight_grams, greater_than_or_equal_to: 0)
    |> validate_number(:max_weight_grams, greater_than: 0)
    |> validate_number(:min_order_amount, greater_than: 0)
    |> validate_number(:max_order_amount, greater_than: 0)
    |> validate_number(:position, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_days_min, greater_than_or_equal_to: 0)
    |> validate_number(:estimated_days_max, greater_than: 0)
    # Keeps an existing slug on rename, romanizes, suffixes -2/-3 until free.
    # max_length applies to the generated value — the old validate_length sat
    # above generation and never saw it.
    |> Slug.put_slug(:name, max_length: 100)
    # slug is NOT NULL. put_slug leaves CJK/Arabic/emoji names blank
    # (slugify returns ""), which is a failed insert, not a missing URL.
    |> LocalizedSlug.put_plain_fallback(:name, max_length: 100)
    |> validate_length(:slug, max: 100)
    |> unique_constraint(:slug, name: :phoenix_kit_shop_shipping_methods_slug_unique)
  end

  @doc """
  Checks if this method is available for given cart parameters.

  ## Examples

      iex> available_for?(method, %{weight_grams: 500, subtotal: Decimal.new("50"), country: "EE"})
      true
  """
  def available_for?(%__MODULE__{active: false}, _params), do: false

  def available_for?(%__MODULE__{} = method, %{
        weight_grams: weight,
        subtotal: subtotal,
        country: country
      }) do
    weight_ok?(method, weight) &&
      amount_ok?(method, subtotal) &&
      country_ok?(method, country)
  end

  def available_for?(%__MODULE__{} = method, params) when is_map(params) do
    weight = Map.get(params, :weight_grams, 0)
    subtotal = Map.get(params, :subtotal, Decimal.new("0"))
    country = Map.get(params, :country)

    available_for?(method, %{weight_grams: weight, subtotal: subtotal, country: country})
  end

  @doc """
  Calculates shipping cost for given subtotal.
  Returns 0 if free shipping threshold is met.
  """
  def calculate_cost(%__MODULE__{free_above_amount: nil, price: price}, _subtotal) do
    price
  end

  def calculate_cost(%__MODULE__{free_above_amount: threshold, price: price}, subtotal) do
    if Decimal.compare(subtotal, threshold) != :lt do
      Decimal.new("0")
    else
      price
    end
  end

  @doc """
  Returns estimated delivery string.

  ## Examples

      iex> delivery_estimate(%ShippingMethod{estimated_days_min: 3, estimated_days_max: 5})
      "3-5 days"

      iex> delivery_estimate(%ShippingMethod{estimated_days_min: 1, estimated_days_max: 1})
      "1 day"
  """
  def delivery_estimate(%__MODULE__{estimated_days_min: nil}), do: nil

  def delivery_estimate(%__MODULE__{estimated_days_min: min, estimated_days_max: nil}) do
    "#{min}+ days"
  end

  def delivery_estimate(%__MODULE__{estimated_days_min: 1, estimated_days_max: 1}) do
    "1 day"
  end

  def delivery_estimate(%__MODULE__{estimated_days_min: min, estimated_days_max: max})
      when min == max do
    "#{min} days"
  end

  def delivery_estimate(%__MODULE__{estimated_days_min: min, estimated_days_max: max}) do
    "#{min}-#{max} days"
  end

  @doc """
  Whether the buyer pays the carrier's own rates on delivery
  (`metadata["pay_on_delivery"]`).

  The shop charges nothing for such a method, so its price is 0 — but it is
  not free shipping, and nothing may present it as such. `false` for `nil`
  and an unloaded association, so a cart's `shipping_method` can be passed
  as is.
  """
  def pay_on_delivery?(%__MODULE__{metadata: %{@pay_on_delivery_key => true}}), do: true
  def pay_on_delivery?(_), do: false

  @doc """
  The provider configuration of the method (`metadata["shipping_provider"]`);
  a method without it is a `"fixed"` provider method. Accepts anything with
  `metadata`, so a cart's `shipping_method` can be passed as is.
  """
  @spec shipping_config(term()) :: MethodConfig.t()
  def shipping_config(method), do: MethodConfig.from_method(method)

  @doc """
  Whether the price of the method comes from a shipping provider other than
  `"fixed"`. A pay-on-delivery method can be calculated too: the carrier
  prices it, the shop still charges nothing.
  """
  @spec calculated?(term()) :: boolean()
  def calculated?(method), do: MethodConfig.calculated?(method)

  @doc """
  Returns true if method is active.
  """
  def active?(%__MODULE__{active: true}), do: true
  def active?(_), do: false

  @doc """
  Checks if shipping is free for the given subtotal.
  """
  def free_for?(%__MODULE__{free_above_amount: nil}, _subtotal), do: false

  def free_for?(%__MODULE__{free_above_amount: threshold}, subtotal) do
    Decimal.compare(subtotal, threshold) != :lt
  end

  # Private helpers

  defp weight_ok?(%{min_weight_grams: min, max_weight_grams: max}, weight) do
    min_ok = is_nil(min) or weight >= min
    max_ok = is_nil(max) or weight <= max
    min_ok and max_ok
  end

  defp amount_ok?(%{min_order_amount: min, max_order_amount: max}, amount) do
    min_ok = is_nil(min) or Decimal.compare(amount, min) != :lt
    max_ok = is_nil(max) or Decimal.compare(amount, max) != :gt
    min_ok and max_ok
  end

  defp country_ok?(%{countries: [], excluded_countries: []}, _country), do: true

  defp country_ok?(%{countries: [], excluded_countries: excluded}, country) do
    is_nil(country) or country not in excluded
  end

  defp country_ok?(%{countries: allowed, excluded_countries: excluded}, country) do
    (is_nil(country) or country in allowed) and
      (is_nil(country) or country not in excluded)
  end

  # The admin form submits the flag as a top-level `pay_on_delivery` param:
  # rendering it as `shipping_method[metadata][pay_on_delivery]` would make
  # `cast/3` replace the whole metadata map and erase every other key in it.
  # `:unset` (no param) leaves whatever the metadata already says.
  defp pop_pay_on_delivery(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :pay_on_delivery) ->
        {value, attrs} = Map.pop(attrs, :pay_on_delivery)
        {to_boolean(value) == true, attrs}

      Map.has_key?(attrs, @pay_on_delivery_key) ->
        {value, attrs} = Map.pop(attrs, @pay_on_delivery_key)
        {to_boolean(value) == true, attrs}

      true ->
        {:unset, attrs}
    end
  end

  defp pop_pay_on_delivery(attrs), do: {:unset, attrs}

  # Stored only while true, as a real boolean, so a method that never had
  # the flag does not gain a key and a "true" string from a form or import
  # cannot slip past `pay_on_delivery?/1`'s strict match.
  defp put_pay_on_delivery(changeset, value) do
    metadata = get_field(changeset, :metadata) || %{}

    flag =
      case value do
        :unset -> to_boolean(Map.get(metadata, @pay_on_delivery_key)) == true
        flag -> flag
      end

    normalized =
      if flag,
        do: Map.put(metadata, @pay_on_delivery_key, true),
        else: Map.delete(metadata, @pay_on_delivery_key)

    if normalized == metadata, do: changeset, else: put_change(changeset, :metadata, normalized)
  end

  # Like `pay_on_delivery`, the provider block arrives as a top-level
  # `shipping_provider` param and is merged into the metadata, so the form
  # can render it without `cast/3` replacing the whole metadata map. `:unset`
  # (no param) leaves the metadata alone.
  defp pop_shipping_provider(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, :shipping_provider) ->
        {param, attrs} = Map.pop(attrs, :shipping_provider)
        {{:set, param}, attrs}

      Map.has_key?(attrs, @shipping_provider_param) ->
        {param, attrs} = Map.pop(attrs, @shipping_provider_param)
        {{:set, param}, attrs}

      true ->
        {:unset, attrs}
    end
  end

  defp pop_shipping_provider(attrs), do: {:unset, attrs}

  defp put_shipping_provider(changeset, :unset), do: changeset

  defp put_shipping_provider(changeset, {:set, param}) do
    case MethodParams.build(param) do
      {:ok, block} ->
        metadata = get_field(changeset, :metadata) || %{}
        key = MethodConfig.metadata_key()

        updated =
          if block, do: Map.put(metadata, key, block), else: Map.delete(metadata, key)

        if updated == metadata, do: changeset, else: put_change(changeset, :metadata, updated)

      {:error, messages} ->
        Enum.reduce(messages, changeset, fn {message, opts}, acc ->
          add_error(acc, :shipping_provider, message, opts)
        end)
    end
  end

  # Forced rather than validated: the shop charges nothing for a
  # pay-on-delivery method, so a price left in the form (or sent by an
  # import) would otherwise be added to the order ON TOP of the carrier's
  # fee, and a free-shipping threshold has nothing to waive. Coercing keeps
  # that invariant on every write path without making the admin clear two
  # fields before the checkbox can be saved.
  defp zero_pay_on_delivery_price(changeset) do
    if pay_on_delivery?(apply_changes(changeset)) do
      changeset
      |> put_change(:price, Decimal.new("0"))
      |> put_change(:free_above_amount, nil)
    else
      changeset
    end
  end

  defp normalize_booleans(attrs, fields) when is_map(attrs) do
    Enum.reduce(fields, attrs, fn field, acc ->
      str_key = to_string(field)

      cond do
        Map.has_key?(acc, field) ->
          Map.update!(acc, field, &to_boolean/1)

        Map.has_key?(acc, str_key) ->
          Map.update!(acc, str_key, &to_boolean/1)

        true ->
          acc
      end
    end)
  end

  defp to_boolean(true), do: true
  defp to_boolean(false), do: false
  defp to_boolean("true"), do: true
  defp to_boolean("false"), do: false
  defp to_boolean(1), do: true
  defp to_boolean(0), do: false
  defp to_boolean("1"), do: true
  defp to_boolean("0"), do: false
  defp to_boolean(nil), do: nil
  defp to_boolean(other), do: other
end
