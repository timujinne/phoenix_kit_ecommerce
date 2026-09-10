defmodule PhoenixKitEcommerce.Catalogue.ShopStatusColumn do
  @moduledoc """
  The catalogue admin's "Shop status" extension column — surfaces
  `data["ecommerce"]["shop_status"]` next to the catalogue's OWN
  `status` on the item/category tables.

  The owner's complaint: the catalogue's `status` and the shop's
  `shop_status` are two independent signals — an item can be a live
  catalogue entry that is deliberately not for sale — and only the
  catalogue's own `status` showed on screen, so an item could be
  invisible on the storefront (or, worse, reachable when it shouldn't
  be — see below) for a reason the admin screen never surfaced. This
  column does NOT synchronize the two (that would destroy the
  distinction the owner wants to keep); it shows both, and warns only
  on the one combination that is an actual hazard, not merely a
  disagreement.

  ## Why item and category are two different rules (`item_columns/0`
  ## vs. `category_columns/0` return DIFFERENT column definitions)

  Items and categories share neither their `shop_status` value domain
  nor their storefront-visibility rule:

    * Item `shop_status` — `draft` / `active` / `archived`
      (`PhoenixKitEcommerce.Catalogue.ItemCommerce`). Listing visibility
      (`ProductSource.Catalogue.Query.active_visibility/1`) requires
      `item.status == "active"` AND `COALESCE(shop_status, 'active') ==
      "active"` — an absent `shop_status` defaults to whatever
      `item.status` already says (`View.product_status/2`'s exact
      fallback), so it never disagrees with the catalogue by itself.
    * Category `shop_status` — `active` / `unlisted` / `hidden`
      (`CategoryCommerce`). Only `hidden` removes a category's items
      from listings (`Query.exclude_hidden_categories/2`); `unlisted`
      only hides the category's own nav entry — its page and items stay
      directly reachable. An absent `shop_status` defaults
      UNCONDITIONALLY to `"active"` (`View.category_view/2`:
      `Map.get(ecommerce, "shop_status") || "active"` — no fallback to
      `c.status` at all).

  ## The one case that warrants a warning — and why items and
  ## categories check it DIFFERENTLY

  `ProductSource.Catalogue.Query.active_visibility/1` (the LISTING
  query) unconditionally requires the catalogue's own status to be
  right (`item.status == "active"` / `c.status != "deleted"`) — no
  `shop_status` value overrides that. But the DIRECT product/category
  page does NOT re-check the catalogue status the same way, and the
  two pages gate oppositely:

    * `CatalogProduct.do_mount/3` is an ALLOW-list of one value: it
      redirects on any resolved status `!= "active"`
      (`View.product_status/2` lets an EXPLICIT `shop_status ==
      "active"` win outright regardless of `item.status`). So the
      reachable-despite-a-bad-catalogue-status case is exactly
      `shop_status == "active"`.
    * `CatalogCategory.do_mount/3` is a BLOCK-list of one value: it
      redirects ONLY when the resolved status
      (`View.category_view/2`'s `shop_status || "active"`, again no
      deference to `c.status`) is literally `"hidden"` — `"active"` AND
      `"unlisted"` both fall through to rendering the page. So the
      reachable-despite-a-bad-catalogue-status case here is
      `shop_status != "hidden"`, a strictly LARGER set than "active"
      alone: a soft-deleted (`c.status == "deleted"`) category whose
      `shop_status` is merely `"unlisted"` (not explicitly `"active"`)
      is STILL reachable by direct link, because `"unlisted" !=
      "hidden"` is all `do_mount/3` checks.

  Either way: whatever the catalogue side excludes it, is excluded from
  every listing/count/facet, while still reachable — and purchasable —
  through its direct URL. That is a real leak, not a cosmetic mismatch,
  and is the ONLY thing this column warns on: `render_item/1` compares
  `shop_key == "active"` against the catalogue side; `render_category/1`
  compares `shop_key != "hidden"` — deliberately NOT the same predicate
  shape, because the pages themselves are not the same shape.

  Every other disagreement — catalogue active while the shop says
  `draft`/`archived` (items) or `hidden` (categories) — is simply how
  the owner deliberately keeps something out of the shop while it
  stays a live catalogue entry, and renders with no warning. An absent
  `shop_status` is shown as the value it effectively resolves to (per
  the fallbacks above), marked "(default)" rather than as an alarming
  "Unknown" — it is not a misconfiguration, just a namespace the Shop
  section has never written.

  One consequence worth naming explicitly: because the category gate
  is a block-list, a category the catalogue has soft-deleted stays
  reachable unless its `shop_status` happens to be `"hidden"` —
  `"unlisted"` (or simply never having been touched — the
  unconditional-active default) is not enough to hide it. That is the
  same CLASS of leak `phoenix_kit_ecommerce` PR #53 fixes on the item
  side (tightening `item.status` deference); this column does not fix
  it for categories — it only makes it visible.

  Reached only through `PhoenixKitEcommerce.Catalogue.Extension`'s
  `item_columns/0`/`category_columns/0` — see that module's moduledoc
  for the discovery contract, and `PhoenixKitCatalogue.Extension`'s
  typedoc (in the optional `phoenix_kit_catalogue` dependency) for the
  exact `%{id:, label:, render:}` shape this returns. Written
  duck-typed on purpose: nothing here references a `PhoenixKitCatalogue`
  module, so it compiles and behaves identically whether or not that
  dependency, or the extension-column slot it implements, is present at
  all.

  ## Badge colours

  Core's `PhoenixKitWeb.Components.Core.Badge.status_badge/1` has no
  case for `unlisted`/`hidden`/an unrecognized value — all three fall
  through to the same grey `badge-ghost`, which would render three
  semantically different category shop-statuses identically. Rather
  than edit core, this module picks its own explicit badge class per
  status (see `item_shop_badge/1`, `category_shop_badge/1`,
  `catalogue_badge/1`) instead of delegating to `status_badge/1`.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitWeb.Components.Core.Icon

  @item_shop_statuses ~w(draft active archived)
  @category_shop_statuses ~w(active unlisted hidden)

  @doc "The `item_columns/0` entry — see this module's moduledoc."
  @spec item_columns() :: [map()]
  def item_columns, do: [%{id: "shop_status", label: &label/0, render: &render_item/1}]

  @doc "The `category_columns/0` entry — see this module's moduledoc."
  @spec category_columns() :: [map()]
  def category_columns, do: [%{id: "shop_status", label: &label/0, render: &render_category/1}]

  defp label, do: gettext("Shop status")

  # ============================================================
  # Items
  # ============================================================

  # `record` is the catalogue item struct the table is rendering a row
  # for (duck-typed: only `.status`/`.data` are read).
  defp render_item(record) do
    catalogue_status = record |> Map.get(:status) |> normalize_catalogue_status()
    catalogue_active? = catalogue_status == "active"
    raw_shop = record |> shop_status_raw() |> normalize_shop(@item_shop_statuses)

    {shop_key, shop_default?} =
      case raw_shop do
        nil -> {if(catalogue_active?, do: "active", else: "archived"), true}
        value -> {value, false}
      end

    # The one hazard this column exists to catch — see moduledoc "The
    # one case that warrants a warning". An absent `shop_status`
    # resolving to "active" only ever happens when `catalogue_active?`
    # is already true (the fallback mirrors `View.product_status/2`),
    # so it can never itself trigger this — only an EXPLICIT "active"
    # shop status against a non-active catalogue status can.
    contradiction = raw_shop == "active" and not catalogue_active?

    cell(%{
      catalogue: catalogue_badge(catalogue_status),
      shop: item_shop_badge(shop_key, shop_default?),
      catalogue_status: catalogue_status,
      shop_status: raw_shop || "default",
      contradiction: contradiction
    })
  end

  defp item_shop_badge("active", false), do: {gettext("Active"), "badge-success", false}
  defp item_shop_badge("active", true), do: {gettext("Active"), "badge-ghost", true}
  defp item_shop_badge("draft", false), do: {gettext("Draft"), "badge-warning", false}
  defp item_shop_badge("archived", false), do: {gettext("Archived"), "badge-ghost", false}
  defp item_shop_badge("archived", true), do: {gettext("Archived"), "badge-ghost", true}

  # ============================================================
  # Categories
  # ============================================================

  # `record` is the catalogue category struct the table is rendering a
  # row for.
  defp render_category(record) do
    catalogue_status = record |> Map.get(:status) |> normalize_catalogue_status()
    catalogue_ok? = catalogue_status != "deleted"
    raw_shop = record |> shop_status_raw() |> normalize_shop(@category_shop_statuses)

    {shop_key, shop_default?} =
      case raw_shop do
        nil -> {"active", true}
        value -> {value, false}
      end

    # NOT a mirror of `render_item/1`'s predicate — the two pages gate
    # oppositely. `CatalogProduct.do_mount/3` is an ALLOW-list: only a
    # resolved status of "active" passes, so items compare `shop_key ==
    # "active"`. `CatalogCategory.do_mount/3` is a BLOCK-list: it
    # redirects only on the resolved status being literally "hidden"
    # (`catalog_category.ex:53-58, 210-215`) — "active" AND "unlisted"
    # both fall through to rendering the page. So the set that's
    # reachable despite a non-ok catalogue status is "anything but
    # hidden", not just "active": a `shop_key == "active"` predicate
    # here silently missed `deleted` + `unlisted` (soft-deleted, but
    # resolved status "unlisted" != "hidden", so the page still
    # renders). An absent `shop_status` still defaults UNCONDITIONALLY
    # to "active" (`View.category_view/2` — no fallback to `c.status`),
    # so it can combine with a non-ok catalogue status same as before.
    contradiction = shop_key != "hidden" and not catalogue_ok?

    cell(%{
      catalogue: catalogue_badge(catalogue_status),
      shop: category_shop_badge(shop_key, shop_default?),
      catalogue_status: catalogue_status,
      shop_status: raw_shop || "default",
      contradiction: contradiction
    })
  end

  defp category_shop_badge("active", false), do: {gettext("Active"), "badge-success", false}
  defp category_shop_badge("active", true), do: {gettext("Active"), "badge-ghost", true}
  defp category_shop_badge("unlisted", false), do: {gettext("Unlisted"), "badge-warning", false}
  defp category_shop_badge("hidden", false), do: {gettext("Hidden"), "badge-error", false}

  # ============================================================
  # Shared
  # ============================================================

  # The catalogue's OWN status: item `active`/`inactive`/`discontinued`/
  # `deleted`, category `active`/`deleted`. One mapping covers both —
  # the two domains don't collide on any value.
  defp catalogue_badge("active"), do: {gettext("Active"), "badge-success", false}
  defp catalogue_badge("inactive"), do: {gettext("Inactive"), "badge-ghost", false}
  defp catalogue_badge("discontinued"), do: {gettext("Discontinued"), "badge-warning", false}
  defp catalogue_badge("deleted"), do: {gettext("Deleted"), "badge-error", false}
  defp catalogue_badge(_unknown), do: {gettext("Unknown"), "badge-ghost", false}

  # Absent `:data`, a nil/non-map `:data`, an absent/non-map "ecommerce"
  # namespace, an absent "shop_status" key, or a non-binary value all
  # fall through to `nil` here.
  defp shop_status_raw(record) do
    with data when is_map(data) <- Map.get(record, :data),
         ecommerce when is_map(ecommerce) <- Map.get(data, "ecommerce"),
         shop_status when is_binary(shop_status) <- Map.get(ecommerce, "shop_status") do
      shop_status
    else
      _ -> nil
    end
  end

  # Catalogue `status` display: always a real string (`"unknown"` for a
  # nil/non-binary/blank value), since `data-catalogue-status` needs one
  # to render at all — `catalogue_badge/1`'s catch-all already treats
  # `"unknown"` (or any other unrecognized string) the same way.
  defp normalize_catalogue_status(value) when is_binary(value) and value != "", do: value
  defp normalize_catalogue_status(_), do: "unknown"

  # A raw value that isn't one of `kind`'s known statuses (absent,
  # non-binary, or simply not recognized) is treated exactly like an
  # absent one — the per-record-type fallback in `render_item/1` /
  # `render_category/1` decides what to show and whether it counts as
  # "active" for the warning, matching how `View.product_status/2` /
  # `View.category_view/2` themselves treat an unrecognized value.
  defp normalize_shop(value, kind) do
    if value in kind, do: value, else: nil
  end

  attr :catalogue, :any, required: true
  attr :shop, :any, required: true
  attr :catalogue_status, :string, required: true
  attr :shop_status, :string, required: true
  attr :contradiction, :boolean, required: true

  # No `id` attribute anywhere below: the SAME call renders the row's
  # desktop-table cell AND its mobile-card fact, both present in the DOM
  # on one page load — an id scoped only by the record would duplicate.
  # `data-*` carries everything a test (or future JS) needs instead.
  defp cell(assigns) do
    {catalogue_label, catalogue_class, _catalogue_default?} = assigns.catalogue
    {shop_label, shop_class, shop_default?} = assigns.shop

    assigns =
      Map.merge(assigns, %{
        catalogue_label: catalogue_label,
        catalogue_class: catalogue_class,
        shop_label: shop_label,
        shop_class: shop_class,
        shop_default?: shop_default?
      })

    ~H"""
    <div
      class={["flex items-center gap-1 flex-wrap", @contradiction && "ring-1 ring-warning rounded px-1"]}
      data-shop-status-cell
      data-catalogue-status={@catalogue_status}
      data-shop-status={@shop_status}
      data-contradiction={to_string(@contradiction)}
      title={@contradiction && contradiction_title()}
    >
      <span class={["badge badge-xs h-auto", @catalogue_class]}>{@catalogue_label}</span>
      <span class={["badge badge-xs h-auto", @shop_class]}>
        {@shop_label}<span :if={@shop_default?} class="opacity-70"> ({gettext("default")})</span>
      </span>
      <.icon :if={@contradiction} name="hero-exclamation-triangle" class="w-4 h-4 text-warning shrink-0" />
    </div>
    """
  end

  defp contradiction_title do
    gettext(
      "The shop reports this as active while the catalogue does not — it is excluded from listings but may still be reachable by direct link."
    )
  end
end
