defmodule PhoenixKitEcommerce.Web.Helpers do
  @moduledoc """
  Shared helper functions for Shop public LiveViews.

  Centralizes utility functions that were duplicated across shop_catalog,
  catalog_category, catalog_product, cart_page, checkout_page, and checkout_complete.
  """

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce.Translations

  # ---------------------------------------------------------------------------
  # Price formatting
  # ---------------------------------------------------------------------------

  @doc """
  Format a price value with currency. Returns "-" for nil price.

  Accepts the amount as a Decimal, number, or numeric string (order line
  items persist their amounts as strings). The currency may be a
  `Currency` struct, a bare code string (`Shop.currency_for_code/1`
  falls back to the code when the record's currency no longer resolves —
  showing "12.50 XYZ" is honest, borrowing today's default symbol is not),
  or nil (no default currency configured at all — legacy `$`).
  """
  def format_price(nil, _currency), do: "-"

  def format_price(price, currency) when is_binary(price) do
    case Decimal.parse(price) do
      {decimal, ""} -> format_price(decimal, currency)
      _ -> "-"
    end
  end

  def format_price(price, nil) do
    "$#{trim_decimals(price, 2)}"
  end

  def format_price(price, code) when is_binary(code) do
    case PhoenixKitEcommerce.currency_for_code(code) do
      %Currency{} = currency -> format_price(price, currency)
      _ -> "#{trim_decimals(price, 2)} #{code}"
    end
  end

  def format_price(price, currency) do
    # Trimming is done by handing billing a currency whose `decimal_places` is 0,
    # NOT by a newer billing API. That keeps this working against the PUBLISHED
    # billing every host actually resolves, and keeps the symbol and thousands
    # separator billing's business rather than ours.
    #
    # An earlier version called a new `format_amount/3` behind a
    # `function_exported?/3` guard. It was dead on arrival: the published billing
    # has no such arity, so the guard was always false and the setting did nothing
    # for any real consumer — it only appeared to work on a dev box, which
    # resolves billing through a path dep. Cross-repo gates like that belong in a
    # PR body, not in a shim that hides the feature being unreachable.
    Currency.format_amount(price, display_currency(currency, price))
  end

  # A DISPLAY-ONLY copy. Never persisted, and never handed to billing's invoice,
  # receipt or credit-note rendering, which must keep the currency's real
  # decimal_places — two decimals is the auditable form.
  #
  # The amount is load-bearing. `format_amount/2` ROUNDS to decimal_places, so
  # handing it 0 unconditionally does not "hide .00", it restates the price:
  # 40.50 rendered as "41" and 1,234.99 as "1,235", on the catalog, the cart
  # line, the tax row and the total — a figure the shopper is not charged. Zero
  # the places only for an amount that has nothing to lose, which is the same
  # rule `trim_decimals/2` applies to the plain-code branches.
  defp display_currency(%{decimal_places: places} = currency, price) do
    if hide_zero_decimals?() and whole?(price, places),
      do: %{currency | decimal_places: trimmed_places(places)},
      else: currency
  end

  defp display_currency(currency, _price), do: currency

  defp trimmed_places(places) when is_integer(places) and places > 0, do: 0
  defp trimmed_places(places), do: places

  # Whether rounding to zero places loses nothing at this currency's precision.
  # Anything that is not a Decimal or an integer amount answers "no" and keeps
  # the currency's own precision: billing accepts shapes `Decimal.round/2` will
  # not (a float raises), and the wrong answer here misstates a price.
  defp whole?(%Decimal{} = price, places) when is_integer(places) do
    rounded = Decimal.round(price, places)
    Decimal.equal?(rounded, Decimal.round(rounded, 0))
  end

  defp whole?(price, places) when is_integer(price) and is_integer(places), do: true
  defp whole?(_price, _places), do: false

  @doc """
  Whether the storefront drops an all-zero fractional part ("40" rather than
  "40.00").

  Off by default, because dropping the decimals is wrong for most shops. It exists
  for shops whose prices are round by nature — services quoted in whole units,
  where "40.00 EUR" reads as unnecessarily precise and, as one operator put it,
  faintly alarming.

  Storefront only. Invoices, receipts and credit notes keep two decimals: they are
  accounting documents, and this setting must never reach them.
  """
  def hide_zero_decimals? do
    PhoenixKit.Settings.get_setting_cached("shop_hide_zero_decimals", "false") == "true"
  end

  # Only drops the fraction when nothing is lost: 40.00 -> 40, but 40.50 stays.
  defp trim_decimals(price, places) do
    rounded = Decimal.round(price, places)

    if hide_zero_decimals?() and Decimal.equal?(rounded, Decimal.round(rounded, 0)) do
      Decimal.round(rounded, 0)
    else
      rounded
    end
  end

  # ---------------------------------------------------------------------------
  # Current user
  # ---------------------------------------------------------------------------

  @doc "Extract current user from socket assigns scope."
  def get_current_user(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: _} = user} -> user
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Language helpers
  # ---------------------------------------------------------------------------

  @doc """
  Determine language from URL params.

  Uses locale param if present, otherwise falls back to Translations.default_language/0.
  Used by catalog and category pages (non-product pages).
  """
  def get_language_from_params_or_default(%{"locale" => locale}) when is_binary(locale) do
    DialectMapper.resolve_dialect(locale)
  end

  def get_language_from_params_or_default(_params) do
    Translations.default_language()
  end

  @doc """
  Point this module's Gettext backend at `language`, falling back to the base
  language when the catalogue has no dialect.

  Without this the storefront renders English in every locale, however complete
  the catalogues are. The content language here is a DIALECT (`resolve_dialect/1`
  returns "ru-RU", "et-EE", "en-US"), and that is also what core puts into the
  process locale — but this module ships `priv/gettext/{en,ru,et}`, plain codes
  with no region. Gettext does not fall back from "ru-RU" to "ru" on its own, so
  every lookup missed and returned its msgid, which is the English source string.

  Core's own catalogue has the same plain-code shape, so this is not specific to
  the shop; it is why a fully translated module can still render entirely in
  English. Verified on a dev box: `put_locale("ru")` translates,
  `put_locale("ru-RU")` does not.

  Called from `mount/3`, which runs once per process for both the dead render and
  the connected mount, so the whole lifecycle of that LiveView is covered.
  """
  def put_content_locale(language) when is_binary(language) do
    known = Gettext.known_locales(PhoenixKitEcommerce.Gettext)
    base = language |> String.split(~r/[-_]/) |> List.first()

    cond do
      language in known ->
        Gettext.put_locale(PhoenixKitEcommerce.Gettext, language)

      base in known ->
        Gettext.put_locale(PhoenixKitEcommerce.Gettext, base)

      true ->
        # Reset rather than no-op. `put_locale/2` is process-scoped, and the dead
        # render runs in a connection process that is reused across keep-alive
        # requests — leaving it untouched means a request for an unsupported
        # locale inherits whatever the PREVIOUS request on that connection set,
        # so a French visitor could be served a Russian storefront.
        Gettext.put_locale(PhoenixKitEcommerce.Gettext, default_gettext_locale())
    end

    language
  end

  def put_content_locale(language), do: language

  @doc """
  Sets the content locale from a socket, falling back to the shop's CONFIGURED
  default rather than a hardcoded "en".

  `:current_locale` is supplied by core's live_session `on_mount`; a host that
  mounts these LiveViews outside it gets `nil`, and a hardcoded English fallback
  would force English on a shop whose default language is Russian.
  """
  def put_content_locale_from(socket) do
    put_content_locale(socket.assigns[:current_locale] || Translations.default_language())
  end

  defp default_gettext_locale do
    known = Gettext.known_locales(PhoenixKitEcommerce.Gettext)
    default = Translations.default_language()
    base = default |> to_string() |> String.split(~r/[-_]/) |> List.first()

    cond do
      default in known -> default
      base in known -> base
      true -> Gettext.get_locale(PhoenixKitEcommerce.Gettext)
    end
  end

  @doc """
  Find the best enabled language that has a slug for this entity.

  Prefers the default language, then checks other enabled languages.
  Returns nil if no valid language found.
  """
  def best_redirect_language(slug_map) when slug_map == %{}, do: nil

  def best_redirect_language(slug_map) do
    enabled = Languages.get_enabled_languages()
    default_first = Enum.sort_by(enabled, fn l -> if l.is_default, do: 0, else: 1 end)

    Enum.find_value(default_first, fn lang ->
      code = lang.code
      base = DialectMapper.extract_base(code)
      if Map.has_key?(slug_map, code) or Map.has_key?(slug_map, base), do: code
    end)
  end

  @doc """
  Build a localized URL path, adding language prefix for non-default languages.
  Delegates to Routes.path which handles default vs non-default consistently.
  """
  def build_lang_url(path, lang) do
    base = DialectMapper.extract_base(lang)
    Routes.path(path, locale: base)
  end

  # ---------------------------------------------------------------------------
  # Pagination helpers
  # ---------------------------------------------------------------------------

  @doc "Parse page param with validation. Returns 1 for invalid/missing values."
  def parse_page(nil), do: 1
  def parse_page(""), do: 1

  def parse_page(page) when is_binary(page) do
    case Integer.parse(page) do
      {p, ""} when p > 0 -> p
      _ -> 1
    end
  end

  def parse_page(page) when is_integer(page) and page > 0, do: page
  def parse_page(_), do: 1

  @doc """
  Parse an integer from a LiveView event payload, falling back to `default`.

  `String.to_integer/1` raises on anything non-numeric, and a raise inside
  `handle_event/3` takes the whole LiveView down — so any hand-crafted or
  merely stale `phx-value-*` produced a crashed socket rather than an
  ignored event. That is reachable unauthenticated on the storefront
  (quantity fields) and by any admin elsewhere.

  Returns `default` for nil, blank, partially-numeric ("3abc") and
  non-binary input. Callers that need a floor should still apply one —
  this only guarantees you get an integer back.
  """
  def parse_int(value, default \\ 0)

  def parse_int(value, default) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> int
      _ -> default
    end
  end

  def parse_int(value, _default) when is_integer(value), do: value
  def parse_int(_value, default), do: default

  # ---------------------------------------------------------------------------
  # Image helpers (for catalog list pages - uses featured_image_uuid)
  # ---------------------------------------------------------------------------

  @doc """
  Get the first image URL for a product.

  Handles Storage-based images (new format with featured_image_uuid or image_uuids)
  and legacy URL-based images (Shopify imports).
  Returns nil if no image is available.
  """
  def first_image(%{featured_image_uuid: id}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  def first_image(%{image_uuids: [id | _]}) when is_binary(id) do
    get_storage_image_url(id, "small")
  end

  # Legacy URL-based images (Shopify imports)
  def first_image(%{images: [%{"src" => src} | _]}), do: src
  def first_image(%{images: [first | _]}) when is_binary(first), do: first
  def first_image(_), do: nil

  @doc """
  Get signed URL for a Storage image file.

  Returns nil if file or variant not found (unlike product detail page
  which returns a placeholder). Falls back to original variant if
  requested variant is not available.
  """
  def get_storage_image_url(file_uuid, variant) do
    case Storage.get_file(file_uuid) do
      %{uuid: uuid} ->
        resolve_storage_variant(file_uuid, uuid, variant)

      nil ->
        nil
    end
  end

  defp resolve_storage_variant(file_uuid, uuid, variant) do
    case Storage.get_file_instance_by_name(uuid, variant) do
      nil ->
        case Storage.get_file_instance_by_name(uuid, "original") do
          nil -> nil
          _instance -> URLSigner.signed_url(file_uuid, "original")
        end

      _instance ->
        URLSigner.signed_url(file_uuid, variant)
    end
  end

  # ---------------------------------------------------------------------------
  # UI helpers
  # ---------------------------------------------------------------------------

  @doc """
  Convert a key string to human-readable format.

  Example: "material_type" -> "Material Type"
  """
  def humanize_key(key) when is_binary(key) do
    key
    |> String.replace("_", " ")
    |> String.split(" ")
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  def humanize_key(key), do: to_string(key)

  # ---------------------------------------------------------------------------
  # Billing profile helpers
  # ---------------------------------------------------------------------------

  @doc "Format display name for a billing profile."
  def profile_display_name(%{type: "company"} = profile) do
    profile.company_name || "#{profile.first_name} #{profile.last_name}"
  end

  def profile_display_name(profile) when is_struct(profile) do
    "#{profile.first_name} #{profile.last_name}"
  end

  # An order's `billing_snapshot` is a plain MAP, and it is the record of
  # who the order was actually billed to. Same rendering, different shape.
  def profile_display_name(%{} = snapshot) do
    case snapshot["type"] do
      "company" ->
        snapshot["company_name"] || joined_name(snapshot)

      _ ->
        joined_name(snapshot)
    end
  end

  defp joined_name(snapshot) do
    [snapshot["first_name"], snapshot["last_name"]]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(" ")
  end

  @doc "Format address for a billing profile struct or an order's snapshot map."
  def profile_address(profile) when is_struct(profile) do
    [profile.address_line1, profile.city, profile.postal_code, profile.country]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  def profile_address(%{} = snapshot) do
    [
      snapshot["address_line1"],
      snapshot["city"],
      snapshot["postal_code"],
      snapshot["country"]
    ]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.join(", ")
  end

  @doc """
  Contact email from a billing profile STRUCT or an order's snapshot MAP.

  The snapshot is a plain map, so `profile.email` raises on it — the crash
  a rendered confirmation page hit after order pages started preferring
  the snapshot. Same shape problem as `profile_display_name/1`.
  """
  def profile_email(profile) when is_struct(profile), do: profile.email
  def profile_email(%{} = snapshot), do: snapshot["email"]
  def profile_email(_), do: nil

  @doc """
  The billing identity an order was placed with.

  Prefers the order's immutable `billing_snapshot` over the live billing
  profile: the profile is editable, so reading it made a historical order
  claim an address it was never billed to (and deleting the profile made
  the true one reappear). The live profile is a fallback only for orders
  placed before snapshots existed.
  """
  def order_billing_identity(%{billing_snapshot: snapshot}) when is_map(snapshot) do
    if map_size(snapshot) > 0, do: snapshot
  end

  def order_billing_identity(_order), do: nil
end
