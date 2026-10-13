defmodule PhoenixKitEcommerce.Web.Helpers do
  @moduledoc """
  Shared helper functions for Shop public LiveViews.

  Centralizes utility functions that were duplicated across shop_catalog,
  catalog_category, catalog_product, cart_page, checkout_page, and checkout_complete.
  """

  # `catalogue_edit_path/2` below is only ever reached once
  # `admin_edit_path/3`'s own `Code.ensure_loaded?(PhoenixKitCatalogue.Paths)`
  # guard has already passed, same duck-typed pattern as
  # `ProductSource.Catalogue.View`'s `@compile` tag on `Catalogue` — the
  # tag only quietens the compiler's static xref check for hosts that
  # don't declare the optional dependency.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Paths}

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.StorefrontCache
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
  # Currency refresh
  # ---------------------------------------------------------------------------

  @doc """
  Re-marks `@currency` as changed so every price expression that reads it
  re-evaluates on the next render — the ONE way a mounted storefront picks
  up a currency-table change (§4.2.1 п.5).

  The rate is deliberately not in assigns (§12.4), so nothing in the
  socket knows it moved; `Phoenix.Component.assign/3` skips an equal value
  and HEEx re-evaluates an expression only when one of ITS assigns
  changed. Passing through a sentinel value marks the key changed while
  the code itself stays what the request resolved. Base numbers
  (`@products`, `@calculated_price`) are unchanged and are not re-read.
  """
  @spec refresh_display_currency(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def refresh_display_currency(socket) do
    code = PhoenixKitEcommerce.get_display_currency_code()

    socket
    |> Phoenix.Component.assign(:currency, :refreshing)
    |> Phoenix.Component.assign(:currency, code)
  end

  @doc """
  Coalesces the product RELOAD a `{:currencies_changed, _}` broadcast asks
  for into one `:fx_reload` message per burst.

  Billing broadcasts once per currency per rate refresh, and a base
  change touches every row — so a storefront tab that re-queried its
  products on every message ran N full catalog queries for one event,
  on every open tab at once. The cheap part (`refresh_display_currency/1`,
  re-marking `@currency` so loaded prices re-present) stays immediate;
  the re-fetch is deferred by `delay_ms` and scheduled at most once while
  `:fx_reload_pending` is set. The page's `handle_info(:fx_reload, _)`
  clause clears the flag (`fx_reload_done/1`) and does the reload.
  """
  def schedule_fx_reload(socket, delay_ms \\ 250) do
    if socket.assigns[:fx_reload_pending] do
      socket
    else
      Process.send_after(self(), :fx_reload, delay_ms)
      Phoenix.Component.assign(socket, :fx_reload_pending, true)
    end
  end

  @doc "Clears the `schedule_fx_reload/2` flag; call first in `handle_info(:fx_reload, _)`."
  def fx_reload_done(socket), do: Phoenix.Component.assign(socket, :fx_reload_pending, false)

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
  Whether a product's tags may be shown on a page rendered in `language`.

  Tags arrive from Shopify as one untranslated list on
  `data["ecommerce"]["tags"]` — there is no per-language variant of them.
  Rendering that list on a translated page puts the only untranslated text
  on the card, so tags stay on the default-language storefront and are
  hidden elsewhere until translated tags exist.
  """
  @spec tags_visible?(String.t() | nil) :: boolean()
  def tags_visible?(language) when is_binary(language) do
    # Compare bases, not dialects. The page language is resolved to a
    # canonical dialect (`"en"` → `"en-US"`) while the configured default
    # is stored verbatim (`"en"`, `"en-GB"`, `"en-US"` are all legitimate).
    # Dialect equality hid tags on a shop whose default is a non-canonical
    # dialect (`en-GB` vs the page's `en-US`). Same-base secondary dialects
    # (`en-GB` visitor on an `en-US`-default shop) also show tags — they
    # are untranslated default-language text either way.
    DialectMapper.extract_base(language) ==
      DialectMapper.extract_base(Translations.default_language())
  end

  def tags_visible?(_language), do: false

  @doc """
  Whether the storefront's category navigation is switched on
  (`shop_sidebar_show_categories`, default `true`). Read by every public page
  that renders a category list, so the catalog aside, the catalog grid and
  the product page's category panel cannot disagree about the default.
  """
  @spec sidebar_categories_enabled?() :: boolean()
  def sidebar_categories_enabled? do
    PhoenixKit.Settings.get_setting_cached("shop_sidebar_show_categories", "true") == "true"
  end

  @doc """
  `PhoenixKitEcommerce.list_active_categories/1` through
  `PhoenixKitEcommerce.StorefrontCache`, for the storefront's category
  navigation: one list shared by every visitor for about a minute (up to
  ~66 s).

  The key carries the product source (switchable at runtime) and the
  options. The list is language-independent - category views hold every
  translation and the query takes no language - so the language, which comes
  from the URL, is deliberately not part of the key: a client cannot mint
  entries for this list at all, and each language does not pay its own cold
  miss. The list holds nothing viewer-specific.
  """
  def list_active_categories_cached(opts \\ []) do
    StorefrontCache.fetch(
      {:categories, ProductSource.current(), opts},
      fn -> PhoenixKitEcommerce.list_active_categories(opts) end
    )
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
    # Billing's own backend too: checkout renders billing's profile form, and
    # its labels would otherwise stay English beside a translated page.
    Enum.each(
      [PhoenixKitEcommerce.Gettext, PhoenixKitBilling.Gettext],
      &put_backend_locale(&1, language)
    )

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

  defp put_backend_locale(backend, language) do
    known = Gettext.known_locales(backend)
    base = language |> String.split(~r/[-_]/) |> List.first()

    cond do
      language in known ->
        Gettext.put_locale(backend, language)

      base in known ->
        Gettext.put_locale(backend, base)

      true ->
        # Reset rather than no-op. `put_locale/2` is process-scoped, and the dead
        # render runs in a connection process that is reused across keep-alive
        # requests — leaving it untouched means a request for an unsupported
        # locale inherits whatever the PREVIOUS request on that connection set,
        # so a French visitor could be served a Russian storefront.
        Gettext.put_locale(backend, default_gettext_locale(backend))
    end
  end

  defp default_gettext_locale(backend) do
    known = Gettext.known_locales(backend)
    default = Translations.default_language()
    base = default |> to_string() |> String.split(~r/[-_]/) |> List.first()

    cond do
      default in known -> default
      base in known -> base
      true -> Gettext.get_locale(backend)
    end
  end

  @doc """
  The entity's own language code (e.g. `"fr-FR"`) when it has a non-empty slug
  for `language`, base-matched, else `nil` — i.e. whether it is genuinely
  translated into the language a URL asked for.

  The one definition of "translated" the storefront uses: the redirect
  decision, the canonical language and the hreflang list all ask it, so a
  blank slug (`""`, `nil`) counts as no translation everywhere.
  """
  @spec requested_translation_lang(map(), String.t()) :: String.t() | nil
  def requested_translation_lang(entity, language) do
    slug_language(entity.slug || %{}, language)
  end

  @doc "Whether `slug_map` holds a non-empty slug for `language` (base-matched)."
  @spec slug_translated?(map() | nil, String.t()) :: boolean()
  def slug_translated?(slug_map, language), do: slug_language(slug_map || %{}, language) != nil

  defp slug_language(slug_map, language) do
    base = DialectMapper.extract_base(language)

    Enum.find(Map.keys(slug_map), fn code ->
      DialectMapper.extract_base(code) == base and Map.get(slug_map, code) not in [nil, ""]
    end)
  end

  @doc """
  Build a localized URL path, adding language prefix for non-default languages.
  Delegates to Routes.path which handles default vs non-default consistently;
  a single-language site gets no locale segment at all (`PhoenixKitEcommerce.url_locale/1`).
  """
  def build_lang_url(path, lang) do
    Routes.path(path, locale: PhoenixKitEcommerce.url_locale(lang))
  end

  @doc """
  A storefront path for the page being rendered, in the page's own language.

  `assigns` is the socket's (or a template's) assigns: the language comes from
  `:current_locale`, falling back to the site's primary one. Every link a page
  renders goes through this (or `PhoenixKitEcommerce.*_url/1`), so none of them
  takes its locale segment from whatever Gettext happens to hold.

  `query` (a map or keyword list) is appended as an encoded query string;
  `Routes.path/2` reads only `:locale` and would drop it.
  """
  @spec page_path(map(), String.t(), Enumerable.t()) :: String.t()
  def page_path(assigns, path, query \\ []) do
    language = assigns[:current_locale] || Translations.default_language()
    base = Routes.path(path, locale: PhoenixKitEcommerce.url_locale(language))

    if Enum.empty?(query), do: base, else: base <> "?" <> URI.encode_query(query)
  end

  @doc """
  Whether the storefront serves a single language: multi-language support is
  off, so there is no other language to redirect a visitor to and no link
  carries a locale segment.
  """
  @spec single_language?() :: boolean()
  def single_language?, do: not Languages.enabled?()

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
  # Unhandled messages
  # ---------------------------------------------------------------------------

  @doc """
  The `handle_info/2` catch-all of every shop LiveView: notes the message
  it ignored at `:debug` and carries on.

  Only the message's SHAPE is logged (`{:cart_updated, _}`), never its
  contents — the payloads here are carts, orders and products.
  """
  @spec ignore_message(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def ignore_message(message, socket) do
    Logger.debug(fn ->
      "[Shop] #{inspect(socket.view)} ignored message #{message_shape(message)}"
    end)

    {:noreply, socket}
  end

  @doc """
  The `handle_event/3` catch-all of every public shop LiveView: an event
  the page does not know, or a known one pushed with a payload its clause
  does not take, is noted at `:debug` and dropped instead of crashing the
  view. Anyone can push anything at a public page.

  Only the event NAME is logged, bounded - never the params.
  """
  @spec ignore_event(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def ignore_event(event, socket) do
    Logger.debug(fn ->
      "[Shop] #{inspect(socket.view)} ignored event #{event |> inspect() |> String.slice(0, 80)}"
    end)

    {:noreply, socket}
  end

  @doc false
  def message_shape(message) when is_atom(message), do: inspect(message)

  def message_shape(message) when is_tuple(message) and tuple_size(message) > 0 do
    case elem(message, 0) do
      tag when is_atom(tag) ->
        "{" <>
          Enum.join([inspect(tag) | List.duplicate("_", tuple_size(message) - 1)], ", ") <> "}"

      _ ->
        "a #{tuple_size(message)}-tuple"
    end
  end

  def message_shape(%module{}), do: "%#{inspect(module)}{}"
  def message_shape(message) when is_map(message), do: "a map"
  def message_shape(message) when is_list(message), do: "a list"
  def message_shape(_message), do: "a term"

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
  defdelegate humanize_key(key), to: PhoenixKitEcommerce.Options

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

  # ---------------------------------------------------------------------------
  # Admin edit link (storefront -> admin)
  # ---------------------------------------------------------------------------

  @admin_edit_helper_mod PhoenixKitWeb.AdminEditHelper

  @doc """
  Assigns `:admin_edit_url`/`:admin_edit_label` on `socket` for an admin
  visitor, via core's `PhoenixKitWeb.AdminEditHelper.assign_admin_edit/3`.

  `permission` is what the LINKED PAGE actually requires, and it defaults
  to `"shop.manage_catalog"` because most of these links open a catalog
  editor. Core's own helper gates on "can this visitor reach the admin
  area at all", which is broader: an admin with, say, only order-desk
  permissions used to be shown an Edit button that landed them on a form
  they could not submit. But the gate must not run ahead of the target
  either — the shop index's "Manage Shop" link opens the dashboard at
  `/admin/shop`, which asks for base `"shop"` — so that call site passes
  its own weaker permission rather than inheriting the catalog one.

  `permission` may also be a list when the target needs several keys — a
  catalogue item's editor belongs to the catalogue module, so it asks for
  `"catalogue"` on top of the shop capability (see `admin_edit_permissions/1`).
  Every key must pass `Scope.can?/2`; core's helper takes one key, so it is
  handed the last of them, the one most specific to the editor. `nil` or an
  empty list names no permission and yields no link.

  Guarded with `Code.ensure_loaded?/1` + `function_exported?/3` rather than
  calling the helper directly: ecommerce pins `phoenix_kit` with a `~>`
  requirement, not an exact version, so a host running an older core that
  predates the helper must not crash storefront pages. Returns `socket`
  unchanged when the helper isn't available or the visitor isn't an admin.
  """
  def maybe_assign_admin_edit(socket, path, label, opts \\ []) do
    mod = @admin_edit_helper_mod
    permissions = opts |> Keyword.get(:permission, "shop.manage_catalog") |> List.wrap()

    # `[]` is "no permission named", which `Enum.all?/2` would read as
    # "every one held" — a link for anybody who can reach the admin area.
    # An absent requirement must fail closed.
    if permissions != [] and Code.ensure_loaded?(mod) and
         function_exported?(mod, :assign_admin_edit, 3) and
         Enum.all?(permissions, &can?(socket, &1)) do
      mod.assign_admin_edit(socket, path, label: label, permission: List.last(permissions))
    else
      socket
    end
  end

  defp can?(socket, permission) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> false
      scope -> Scope.can?(scope, permission)
    end
  end

  @doc """
  The permissions the admin edit link for `record` (a product or a
  category) needs, for `maybe_assign_admin_edit/4`.

  A legacy record opens the shop's own form: `"shop.manage_catalog"`. A
  catalogue record opens `phoenix_kit_catalogue`'s editor, a different
  module with its own gate, so the visitor also needs `"catalogue"` — without
  it the button led an operator with shop rights only to a refusal.
  """
  @spec admin_edit_permissions(Product.t() | Category.t()) :: [String.t()]
  def admin_edit_permissions(record) do
    if catalogue_record?(record),
      do: ["shop.manage_catalog", "catalogue"],
      else: ["shop.manage_catalog"]
  end

  @doc """
  Where the admin edit link for `record` should point, and where the editor
  should send the visitor back to.

  `kind` is `:item` for a product and `:category` for a category. The editor
  is chosen by the record's own ORIGIN (`origin` on the struct): a record
  built from a `phoenix_kit_catalogue` item or category opens the catalogue
  editor, a row of the shop's own tables opens the shop form. It is
  deliberately not decided by the global `shop_product_source` switch — that
  says what the storefront lists, not what a given record is, and a store
  holding both (legacy rows an import left behind next to catalogue items, a
  source flipped after products existed) sent the operator to an editor
  that has no such record.

  `return_to` is where the editor should send the visitor
  back to — the catalogue forms and the legacy shop forms all validate it
  (the legacy ones with `safe_return_to/1`) and use it for their exit, so
  "edit, save, back to the page I was on" works without reaching for the
  browser's back button. It is the page's
  canonical URL rather than the exact one the visitor typed, and query
  state (a filter, a page number) is not carried back. Two reasons, and
  the second is the one that matters: these links are built in `mount/3`,
  while core assigns `:url_path` from its `handle_params` hook, which
  runs later — but `:url_path` is a path, parsed out of the URL with the
  query discarded, so building the link later would not carry the query
  either.

  A catalogue record falls back to the shop path when the catalogue module
  isn't loaded at all (it is an optional dependency).

  **Deprecated:** a bare uuid in place of the record still works and keeps
  the old behaviour — the editor is picked by the global product source,
  since a uuid alone says nothing about where the record lives. Hosts that
  built links with `admin_edit_path(:item, uuid, ...)` should pass the
  record.
  """
  @spec admin_edit_path(
          :item | :category,
          Product.t() | Category.t() | Ecto.UUID.t(),
          String.t() | nil
        ) :: String.t()
  def admin_edit_path(kind, record, return_to \\ nil)

  def admin_edit_path(kind, uuid, return_to) when is_binary(uuid) do
    origin = if catalogue_source?(), do: :catalogue, else: :legacy
    edit_path(kind, uuid, origin, return_to)
  end

  def admin_edit_path(kind, record, return_to) when kind in [:item, :category] do
    origin = if catalogue_record?(record), do: :catalogue, else: :legacy
    edit_path(kind, record.uuid, origin, return_to)
  end

  defp edit_path(kind, uuid, origin, return_to) do
    path =
      if origin == :catalogue and Code.ensure_loaded?(PhoenixKitCatalogue.Paths) do
        catalogue_edit_path(kind, uuid)
      else
        legacy_edit_path(kind, uuid)
      end

    append_return_to(path, return_to)
  end

  defp catalogue_edit_path(:item, uuid), do: PhoenixKitCatalogue.Paths.item_edit(uuid)
  defp catalogue_edit_path(:category, uuid), do: PhoenixKitCatalogue.Paths.category_edit(uuid)

  defp legacy_edit_path(:item, uuid), do: Routes.path("/admin/shop/products/#{uuid}/edit")
  defp legacy_edit_path(:category, uuid), do: Routes.path("/admin/shop/categories/#{uuid}/edit")

  defp catalogue_source?, do: ProductSource.current() == ProductSource.Catalogue

  defp catalogue_record?(%{origin: :catalogue}), do: true
  defp catalogue_record?(_record), do: false

  defp append_return_to(path, return_to) when is_binary(return_to) and return_to != "" do
    separator = if String.contains?(path, "?"), do: "&", else: "?"
    path <> separator <> URI.encode_query(%{"return_to" => return_to})
  end

  defp append_return_to(path, _return_to), do: path

  @doc """
  The `return_to` query value if it is safe to navigate to, else `nil`.

  The Edit links `admin_edit_path/3` builds append `?return_to=<page the
  visitor came from>`, and the legacy product and category forms they can
  open send the operator back there. The value is user input, so only a
  path on this host is honoured: core's `Routes.local_path?/1` (a leading
  `/`, but not `//` or `/\\`, no control characters) plus the two shapes
  `push_navigate/2` itself refuses by raising, a backslash anywhere and
  `/%09`. Anything else is ignored rather than followed, so the form behaves
  as if no `return_to` was sent.
  """
  @spec safe_return_to(term()) :: String.t() | nil
  def safe_return_to(path) when is_binary(path) do
    if Routes.local_path?(path) and not String.contains?(path, ["\\", "/%09"]), do: path
  end

  def safe_return_to(_path), do: nil

  @doc """
  The valid UUIDs in a client-supplied selection, canonicalised.

  A bulk action's `uuids` payload is client input that ends up in
  `where x.uuid in ^ids`, where Ecto raises `Ecto.Query.CastError` on
  anything that is not a UUID. Entries that are not UUIDs are dropped, and
  anything that is not a list is an empty selection.
  """
  @spec cast_uuids(term()) :: [Ecto.UUID.t()]
  def cast_uuids(uuids) when is_list(uuids) do
    Enum.flat_map(uuids, fn uuid ->
      case Ecto.UUID.cast(uuid) do
        {:ok, uuid} -> [uuid]
        :error -> []
      end
    end)
  end

  def cast_uuids(_other), do: []

  @doc """
  A client-supplied single UUID: `{:ok, nil}` for the empty string ("no
  parent", "no category"), `{:ok, uuid}` for a valid one, `:error` otherwise.
  """
  @spec cast_optional_uuid(term()) :: {:ok, Ecto.UUID.t() | nil} | :error
  def cast_optional_uuid(""), do: {:ok, nil}
  def cast_optional_uuid(uuid) when is_binary(uuid), do: Ecto.UUID.cast(uuid)
  def cast_optional_uuid(_other), do: :error
end
