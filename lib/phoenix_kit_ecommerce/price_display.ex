defmodule PhoenixKitEcommerce.PriceDisplay do
  @moduledoc """
  How a price is written on the storefront: `From €40.00 /hour`.

  Two independent decorations, both optional and both off by default:

    * a **unit** — free text per language (`"per hour"`, `"/m²"`, `"в час"`),
      so a service shop can state its pricing model. Free text rather than a
      vocabulary: nothing here needs to know what an hour is, and every shop
      invents units the next one has never heard of.

    * a **"From" prefix** — set explicitly by the admin, or implied when the
      product's options genuinely produce a price range.

  ## Storage

  Both live under one reserved key in `Product.metadata`:

      %{"_price_display" => %{
          "unit" => %{"en" => "per hour", "ru" => "в час"},
          "from" => true
        }}

  A single versioned namespace rather than two loose top-level keys: the
  metadata map is an advertised extension point, so this module's data
  stays in one place that can grow (and be recognised) without colliding
  with whatever a host already stores there. `_`-prefixed matches the
  existing `_option_values` / `_price_modifiers` convention, and option
  keys may not begin with `_`, so no user-defined option can shadow it.

  ## Context is load-bearing

  `render/4` takes a context because the same product means different
  things on different pages:

    * `:catalog` — the product's *asking* price. May show "From", and the
      amount comes from the product's option-aware range.
    * `:selected` — the price for the options the shopper picked. Exact, so
      never "From"; keeps the unit.
    * `:cart` / `:order` — a SNAPSHOT of what was (or will be) charged.
      Exact, never "From", and the unit comes from the snapshot rather than
      the live product, so an edit or deletion cannot rewrite a line the
      customer already agreed to.

  Absent data renders exactly what the module rendered before this existed.
  """

  # Backend form (not the runtime `Gettext.dgettext/3` call) so "From" is
  # extractable into this module's own catalogue.
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Web.Helpers

  @key "_price_display"

  @doc """
  The reserved metadata key. Consumers that copy metadata around (the CSV
  upsert, the product form) use this to preserve the namespace.
  """
  def metadata_key, do: @key

  @doc """
  Reads the display settings out of a product (or a raw metadata map).

  Returns `%{unit: %{lang => text}, from: boolean, on_request: boolean}` with
  safe defaults.
  """
  def settings(%Product{metadata: metadata}), do: settings(metadata)

  def settings(metadata) when is_map(metadata) do
    raw = Map.get(metadata, @key) || %{}

    %{
      unit: normalize_unit(Map.get(raw, "unit")),
      from: Map.get(raw, "from") == true,
      on_request: Map.get(raw, "on_request") == true
    }
  end

  def settings(_), do: %{unit: %{}, from: false, on_request: false}

  @doc """
  Whether this product's price is negotiated rather than listed
  ("price on request" / "цена договорная").

  Read the LINE's own snapshot for `:cart` and `:order`
  (`metadata["price_on_request"]`), never the live product. A product can be edited or deleted after a line is
  created (`product_uuid` is ON DELETE SET NULL), and a line that was agreed as
  "on request" must not later render as a number, nor a priced line as "on
  request".
  """
  def on_request?(product_or_metadata) do
    settings(product_or_metadata).on_request
  end

  @doc """
  Whether a stored LINE was agreed as "price on request".

  This is the snapshot side of `on_request?/1`, and every page that renders a
  line must ask it rather than reading the live product. It accepts both shapes
  the storefront holds a line in: a `CartItem` (the flag lives under
  `metadata`) and an order line item (a plain map, flag at the top level).

  A helper rather than the inline `(item.metadata || %{})["price_on_request"] ==
  true` this replaces: five templates need the answer — cart, checkout review,
  the product page's "already in cart" notice, the confirmation and order
  details — and the two that expressed it inline were the two that got it, while
  the other three rendered `0.00` for a line with no price.
  """
  def line_on_request?(%{metadata: metadata}), do: (metadata || %{})["price_on_request"] == true
  def line_on_request?(line) when is_map(line), do: line["price_on_request"] == true
  def line_on_request?(_), do: false

  @doc """
  Whether any line in a cart or order was agreed as "price on request".

  Suppressing the amount per line leaves the TOTAL saying something the shop
  does not mean: an on-request line snapshots 0, so a cart holding one reads
  "Total 0.00" beside a "Proceed to Checkout" button, and a mixed cart quietly
  omits the on-request item from a figure the shopper reads as the whole bill.
  The totals themselves stay as they are — they are the amounts billing will
  charge — so the pages that show one disclose what it leaves out.
  """
  def any_line_on_request?(lines) when is_list(lines), do: Enum.any?(lines, &line_on_request?/1)
  def any_line_on_request?(_), do: false

  @doc """
  Builds the storable namespace map from admin form input.

  Blank units are dropped so an untouched form does not persist empty
  strings, and values are length-bounded — this text renders next to a
  price on a public page, it is not a description field.
  """
  def build(unit_map, from?), do: build(unit_map, from?, false)

  def build(unit_map, from?, on_request?) do
    unit = normalize_unit(unit_map)

    if unit == %{} and from? != true and on_request? != true do
      %{}
    else
      base = %{"unit" => unit, "from" => from? == true}

      # Written ONLY when true, so `build/2` still produces exactly the map it
      # always did and an existing product does not silently gain a key on its
      # next save. `settings/1` reads a missing key as false, so absence and
      # `false` are already the same thing to every reader.
      if on_request? == true, do: Map.put(base, "on_request", true), else: base
    end
  end

  @doc """
  The unit text for a language, with default-language fallback.

  Returns nil when the product has no unit — callers render the plain price.
  """
  def unit_for(product_or_metadata, language) do
    %{unit: unit} = settings(product_or_metadata)

    cond do
      unit == %{} ->
        nil

      is_binary(language) and is_binary(unit[language]) ->
        unit[language]

      true ->
        default = Translations.default_language()
        unit[default] || unit |> Map.values() |> List.first()
    end
  end

  @doc """
  Renders a price for display.

  The second argument is a display-currency CODE (`String.t() | nil`) —
  per-domain-currency spec §4.2.1: assigns carry a code, never a struct,
  so a cached struct can never go stale between requests. A `%Currency{}`
  is still accepted, for callers that already have one, and is unwrapped
  to its code immediately; every conversion downstream still goes
  through `Currency.present/3`'s own fresh resolution.

  Which numbers convert is decided by where the number CAME FROM (§2.10),
  not by the context alone:

    * `:catalog` — both bounds of the product's (base-currency) price
      range go through `present/3`.
    * `:selected` — `opts[:amount]` is a LIVE base-currency number just
      computed by `calculate_product_price/2`; converted exactly once,
      here.
    * `:cart` / `:order` — `opts[:amount]` is a STORED snapshot already
      recorded in the record's own currency (a `CartItem`'s `unit_price`,
      an order line's amount); converting it again would double-convert
      a number that is already in the currency being asked for (N1).

  ## Options

    * `:amount` — the exact amount to render (required for `:selected`,
      `:cart` and `:order`; ignored for `:catalog`, which derives the
      product's range).
    * `:unit` — an explicit unit string, used by snapshot contexts so a
      cart line can render the unit it stored rather than the live one.
    * `:language` — the viewer's language, for unit resolution.
    * `:range_style` — `:from` (default) or `:range`, catalog only.
  """
  def render(product, currency, ctx, opts \\ [])

  def render(product, %Currency{code: code}, ctx, opts), do: render(product, code, ctx, opts)

  def render(%Product{} = product, code, :catalog, opts) do
    if on_request?(product) do
      # No number is shown at all: the price does not exist yet. Beats any
      # range/"From" computation below, which would invent one.
      on_request_label()
    else
      do_render_catalog(product, code, opts)
    end
  end

  def render(product_or_nil, code, ctx, opts) when ctx in [:selected, :cart, :order] do
    amount = Keyword.get(opts, :amount)

    # `:on_request` is passed by snapshot callers from the LINE's own metadata.
    # Falling back to the live product is correct only for `:selected`, which is
    # a live product view, not a stored line.
    on_request? =
      case Keyword.fetch(opts, :on_request) do
        {:ok, stored} -> stored == true
        :error -> ctx == :selected and product_or_nil != nil and on_request?(product_or_nil)
      end

    if on_request? do
      on_request_label()
    else
      # Provenance decides, not the context alone (§2.10): :selected hands
      # us a LIVE base amount, so this is the one and only conversion it
      # gets (N1 — do_render_snapshot below must never convert again).
      # :cart/:order hand us a STORED snapshot already in `code`'s
      # currency; converting that would double-convert it.
      amount = if ctx == :selected, do: Currency.present(amount, code), else: amount
      do_render_snapshot(product_or_nil, code, amount, opts)
    end
  end

  defp do_render_catalog(%Product{} = product, code, opts) do
    language = Keyword.get(opts, :language)
    %{from: force_from} = settings(product)
    {min_base, max_base} = PhoenixKitEcommerce.get_price_range(product)
    min_price = Currency.present(min_base, code)
    max_price = Currency.present(max_base, code)

    base =
      cond do
        Decimal.compare(min_price, max_price) != :eq and
            Keyword.get(opts, :range_style, :from) == :range ->
          "#{Helpers.format_price(min_price, code)} - #{Helpers.format_price(max_price, code)}"

        Decimal.compare(min_price, max_price) != :eq or force_from ->
          # A real option range implies "From" regardless of the flag; the
          # flag additionally forces it for a single-price product (a
          # service quoted "from" a starting rate).
          "#{from_label()} #{Helpers.format_price(min_price, code)}"

        true ->
          Helpers.format_price(min_price, code)
      end

    append_unit(base, unit_for(product, language))
  end

  defp do_render_snapshot(product_or_nil, code, amount, opts) do
    unit =
      case Keyword.fetch(opts, :unit) do
        # Snapshot contexts pass their stored unit explicitly — including
        # an explicit nil, which means "this line stored no unit" and must
        # NOT fall back to the live product.
        {:ok, stored} -> stored
        :error -> product_or_nil && unit_for(product_or_nil, Keyword.get(opts, :language))
      end

    Helpers.format_price(amount, code) |> append_unit(unit)
  end

  @doc """
  Strike-through price and discount percent, or `nil` when there is no
  discount (or the product is on request — a negotiated price has no
  "was" to compare against).

  Both numbers pass through `present/3` together with the price they
  accompany (§4.3.1): the discount itself is computed in BASE currency
  first (comparing `product.compare_at_price` against the base amount —
  `opts[:amount]` for `:selected`, the product's own `price` otherwise),
  so `percent` is the TRUE discount regardless of display currency or
  rounding; only the already-decided `compare_at_price` is then
  converted for display, the same way `render/4` converts a `:catalog`/
  `:selected` amount and never a `:cart`/`:order` one.
  """
  @spec compare_at(Product.t(), String.t() | nil, atom(), keyword()) ::
          %{price: String.t(), percent: integer()} | nil
  def compare_at(product, currency, ctx, opts \\ [])

  def compare_at(%Product{compare_at_price: nil}, _code, _ctx, _opts), do: nil

  def compare_at(%Product{} = product, %Currency{code: code}, ctx, opts),
    do: compare_at(product, code, ctx, opts)

  def compare_at(%Product{compare_at_price: compare} = product, code, ctx, opts) do
    base_amount =
      if ctx == :selected,
        do: Keyword.fetch!(opts, :amount),
        else: product.price || Decimal.new("0")

    if on_request?(product) or Decimal.compare(compare, base_amount) != :gt do
      nil
    else
      percent =
        compare
        |> Decimal.sub(base_amount)
        |> Decimal.div(compare)
        |> Decimal.mult(100)
        |> Decimal.round(0)
        |> Decimal.to_integer()

      %{price: Helpers.format_price(Currency.present(compare, code), code), percent: percent}
    end
  end

  defp append_unit(price, nil), do: price
  defp append_unit(price, ""), do: price
  defp append_unit(price, unit), do: "#{price} #{unit}"

  # Gettext-backed so a shop's own catalogue can translate it; the module
  # backend is injected into web/, and this module is context-side.
  defp from_label, do: gettext("From")

  # "Цена договорная" — the price is agreed, not listed.
  defp on_request_label, do: gettext("Price on request")

  defp normalize_unit(unit) when is_map(unit) do
    unit
    |> Enum.filter(fn {lang, text} -> is_binary(lang) and is_binary(text) and text != "" end)
    |> Enum.map(fn {lang, text} -> {lang, text |> String.trim() |> String.slice(0, 32)} end)
    |> Enum.reject(fn {_lang, text} -> text == "" end)
    |> Map.new()
  end

  defp normalize_unit(_), do: %{}
end
