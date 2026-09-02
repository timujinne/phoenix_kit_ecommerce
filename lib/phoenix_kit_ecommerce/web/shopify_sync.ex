defmodule PhoenixKitEcommerce.Web.ShopifySync do
  @moduledoc """
  Admin LiveView for the Shopify → shop one-way sync.

  Fetches products from the Shopify Admin API connection registered in
  `PhoenixKitEcommerce.Shopify.Provider`, diffs them against the local
  catalog (`PhoenixKitEcommerce.Shopify.Sync.check/2`), and lets an
  operator apply changes — nothing is written without an explicit click.
  When the Admin API token is rejected, `Sync.check/2` falls back to a
  price-only storefront read instead of failing outright; this LiveView
  surfaces that with a banner so an operator never mistakes a price-only
  report for a complete one, and only ever renders the Prices section in
  that mode (see `visible_sections/2`).

  Changes are grouped into field sections (Prices, Titles, Descriptions,
  HTML texts, Tags, Statuses, Vendors — in that order, price first). One
  product's change can appear in more than one section if more than one
  of its fields differs. Sections are collapsed by default and show a
  count; expanding one reveals its rows, 25 at a time (see the module
  attribute doc on `@per_page` for why pagination here is a correctness
  requirement, not polish). An operator can apply a single field on a
  single product, a whole section, or every pending change at once —
  always through `PhoenixKitEcommerce.Shopify.Sync`'s existing
  `apply_change/2` / `apply_changes/2`, never by writing to a product
  directly.

  Only updates products that already exist locally (matched by Shopify's
  `handle` against the product's slug). A Shopify product with no local
  match is skipped — creating new products is the CSV import's job, not
  this sync's.
  """

  use PhoenixKitEcommerce.Web, :live_view

  import PhoenixKitWeb.Components.Core.AdminPageHeader

  alias PhoenixKit.Integrations
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
  alias PhoenixKitEcommerce.Shopify.Sync
  alias PhoenixKitEcommerce.Shopify.TextDiff
  alias PhoenixKitEcommerce.Web.Authz

  # Section order — price first, per spec. Each row's plural label; used
  # for the section headers only (`field_label/1` below carries the
  # singular per-field wording used in row/confirm text).
  @sections [
    {:price, "Prices"},
    {:title, "Titles"},
    {:description, "Descriptions"},
    {:body_html, "HTML texts"},
    {:tags, "Tags"},
    {:status, "Statuses"},
    {:vendor, "Vendors"}
  ]
  @section_labels Map.new(@sections)

  @field_labels %{
    title: "Title",
    body_html: "Description (HTML)",
    description: "Description",
    vendor: "Vendor",
    tags: "Tags",
    status: "Status",
    price: "Price"
  }

  # Fields long enough to need a word-level diff instead of a plain
  # current → incoming line. `TextDiff.summary/2` and `TextDiff.words/2`
  # are only ever called for these.
  @text_fields [:title, :description, :body_html]

  # Rows rendered per page within an expanded section. Not a display
  # preference: `TextDiff`'s own moduledoc measures a wholly-rewritten
  # 1.7 KB body_html at 12 ms per row, and the live catalog's ~500
  # products commonly differ in title, description, AND body_html at
  # once — rendering a full section in one pass can spend several
  # seconds computing summaries inside the LiveView process, on top of
  # producing a DOM no operator can usefully scroll. Bounding to 25 rows
  # bounds both costs at once; summaries are computed only for the rows
  # on the current page (`build_section/2` below).
  @per_page 25

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Shopify Sync"))
     |> assign(:connection, shopify_connection())
     |> assign(:checking, false)
     |> assign(:changes, nil)
     |> assign(:error, nil)
     |> assign(:source, nil)
     |> assign(:fallback_reason, nil)
     |> assign(:expanded_sections, MapSet.new())
     |> assign(:expanded_rows, MapSet.new())
     |> assign(:page, %{})
     |> assign(:applied_any?, false)}
  end

  @impl true
  def handle_event("check", _params, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      case socket.assigns.connection do
        nil ->
          {:noreply, socket}

        %{uuid: uuid} ->
          {:noreply,
           socket
           |> assign(
             checking: true,
             changes: nil,
             error: nil,
             source: nil,
             fallback_reason: nil,
             expanded_sections: MapSet.new(),
             expanded_rows: MapSet.new(),
             page: %{},
             applied_any?: false
           )
           |> start_async(:check_diff, fn -> Sync.check(uuid) end)}
      end
    end)
  end

  def handle_event("toggle_section", %{"field" => field_str}, socket) do
    case to_field(field_str) do
      nil ->
        {:noreply, socket}

      field ->
        {:noreply,
         assign(socket, :expanded_sections, toggle(socket.assigns.expanded_sections, field))}
    end
  end

  def handle_event("toggle_row", %{"field" => field_str, "uuid" => uuid}, socket) do
    case to_field(field_str) do
      nil ->
        {:noreply, socket}

      field ->
        {:noreply,
         assign(socket, :expanded_rows, toggle(socket.assigns.expanded_rows, {field, uuid}))}
    end
  end

  def handle_event("page_prev", %{"field" => field_str}, socket) do
    {:noreply, bump_page(socket, field_str, -1)}
  end

  def handle_event("page_next", %{"field" => field_str}, socket) do
    {:noreply, bump_page(socket, field_str, 1)}
  end

  def handle_event("apply_row", %{"field" => field_str, "uuid" => uuid}, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      changes = socket.assigns.changes || []

      with field when not is_nil(field) <- to_field(field_str),
           change when not is_nil(change) <-
             Enum.find(changes, &(&1.product_uuid == uuid and Map.has_key?(&1.changes, field))) do
        apply_row_change(socket, changes, change, field)
      else
        _ -> {:noreply, socket}
      end
    end)
  end

  def handle_event("apply_section", %{"field" => field_str}, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      case to_field(field_str) do
        nil -> {:noreply, socket}
        field -> apply_section_changes(socket, field)
      end
    end)
  end

  def handle_event("apply_everything", _params, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      changes = socket.assigns.changes || []
      {eligible, _excluded} = applicable_for_everything(changes, socket.assigns.source)
      %{succeeded: succeeded, failed: failed} = Sync.apply_changes(eligible, :all)

      socket =
        if succeeded != [] do
          Activity.log("shop.shopify_sync_bulk_apply_all",
            actor_uuid: Activity.actor_uuid(socket),
            actor_role: Activity.actor_role(socket),
            metadata: %{"count" => length(succeeded)}
          )

          assign(socket, :applied_any?, true)
        else
          socket
        end

      succeeded_uuids = MapSet.new(succeeded, & &1.product_uuid)
      remaining = Enum.reject(changes, &MapSet.member?(succeeded_uuids, &1.product_uuid))

      {:noreply,
       socket
       |> assign(:changes, remaining)
       |> flash_everything_result(succeeded, failed)}
    end)
  end

  @impl true
  def handle_async(
        :check_diff,
        {:ok, {:ok, %{changes: changes, source: source, fallback_reason: reason}}},
        socket
      ) do
    {:noreply,
     assign(socket, checking: false, changes: changes, source: source, fallback_reason: reason)}
  end

  def handle_async(:check_diff, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, checking: false, changes: nil, error: format_error(reason))}
  end

  def handle_async(:check_diff, {:exit, reason}, socket) do
    {:noreply, assign(socket, checking: false, changes: nil, error: inspect(reason))}
  end

  defp apply_row_change(socket, changes, change, field) do
    case Sync.apply_change(change, [field]) do
      {:ok, _product} ->
        Activity.log("shop.shopify_sync_apply",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "product",
          resource_uuid: change.product_uuid,
          metadata: %{"fields" => [to_string(field)]}
        )

        {:noreply,
         socket
         |> assign(:changes, remove_field_for(changes, [change], field))
         |> assign(:applied_any?, true)
         |> put_flash(
           :info,
           gettext("Updated %{title}'s %{field}.",
             title: change.title,
             field: field_label(field)
           )
         )}

      {:error, _changeset} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Could not update %{title}'s %{field}.",
             title: change.title,
             field: field_label(field)
           )
         )}
    end
  end

  defp apply_section_changes(socket, field) do
    changes = socket.assigns.changes || []
    section_changes = Enum.filter(changes, &Map.has_key?(&1.changes, field))
    {eligible, _excluded} = split_bulk_eligible(section_changes, field)
    %{succeeded: succeeded, failed: failed} = Sync.apply_changes(eligible, [field])

    socket =
      if succeeded != [] do
        Activity.log("shop.shopify_sync_bulk_field_apply",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          metadata: %{"count" => length(succeeded), "field" => to_string(field)}
        )

        assign(socket, :applied_any?, true)
      else
        socket
      end

    {:noreply,
     socket
     |> assign(:changes, remove_field_for(changes, succeeded, field))
     |> flash_bulk_result(succeeded, failed, field)}
  end

  # A bulk apply (section or everything) must never write an extreme price
  # change — that guard existed on the old page's only bulk action
  # (`price_only_safe?/1`) and this store has had a real price-corruption
  # incident before. It stays applicable per-row, where the "large change"
  # badge is visible and the operator is looking at that one product.
  # Extreme-ness is a price concept only — every other field's bulk apply
  # passes every row through untouched (`excluded` is always `[]`).
  defp split_bulk_eligible(section_changes, :price) do
    Enum.split_with(section_changes, &(not &1.price_extreme?))
  end

  defp split_bulk_eligible(section_changes, _field), do: {section_changes, []}

  # `apply_everything` touches every field on a change via `:all`, so a
  # change with an extreme price component is excluded WHOLESALE here
  # (not just its price field) — there is no per-field split available
  # through `Sync.apply_changes/2`'s single `:all` sentinel. The operator
  # still reaches its other fields individually, via that product's rows
  # in their own sections.
  defp applicable_for_everything(changes, source) do
    changes
    |> visible_changes(source)
    |> Enum.split_with(&(not &1.price_extreme?))
  end

  # The set of changes `apply_everything` may touch: every change reachable
  # through `visible_sections/2`, deduplicated (one Change struct can
  # appear under more than one field). Going through the same filter that
  # gates rendering is deliberate — see `visible_sections/2`'s doc: without
  # it, a broken upstream guarantee would make the page correctly HIDE a
  # section while `apply_everything` still WROTE it, which is exactly the
  # failure that filter exists to prevent.
  defp visible_changes(changes, source) do
    changes
    |> visible_sections(source)
    |> Enum.flat_map(fn {_field, matching} -> matching end)
    |> Enum.uniq_by(& &1.product_uuid)
  end

  # Drops `field` from every change whose product_uuid is in `succeeded`
  # — a change that still has other fields differing stays (minus this
  # field), a change left with no fields differing is dropped entirely.
  # Used for both a single-row apply (`succeeded` is a one-element list)
  # and a whole-section bulk apply.
  defp remove_field_for(changes, succeeded, field) do
    succeeded_uuids = MapSet.new(succeeded, & &1.product_uuid)

    changes
    |> Enum.map(fn c ->
      if MapSet.member?(succeeded_uuids, c.product_uuid) do
        %{c | changes: Map.delete(c.changes, field)}
      else
        c
      end
    end)
    |> Enum.reject(&(&1.changes == %{}))
  end

  defp flash_bulk_result(socket, succeeded, failed, field) do
    socket =
      if succeeded != [] do
        put_flash(
          socket,
          :info,
          ngettext(
            "Updated %{count} product's %{field}.",
            "Updated %{count} products' %{field}.",
            length(succeeded),
            count: length(succeeded),
            field: field_label(field)
          )
        )
      else
        socket
      end

    if failed != [] do
      put_flash(
        socket,
        :error,
        ngettext(
          "Could not update %{count} product's %{field} — try again or apply individually.",
          "Could not update %{count} products' %{field} — try again or apply individually.",
          length(failed),
          count: length(failed),
          field: field_label(field)
        )
      )
    else
      socket
    end
  end

  defp flash_everything_result(socket, succeeded, failed) do
    socket =
      if succeeded != [] do
        put_flash(
          socket,
          :info,
          ngettext(
            "Applied %{count} change from Shopify.",
            "Applied %{count} changes from Shopify.",
            length(succeeded),
            count: length(succeeded)
          )
        )
      else
        socket
      end

    if failed != [] do
      put_flash(
        socket,
        :error,
        ngettext(
          "Could not apply %{count} change — try again or apply individually.",
          "Could not apply %{count} changes — try again or apply individually.",
          length(failed),
          count: length(failed)
        )
      )
    else
      socket
    end
  end

  defp toggle(set, item) do
    if MapSet.member?(set, item), do: MapSet.delete(set, item), else: MapSet.put(set, item)
  end

  defp bump_page(socket, field_str, delta) do
    case to_field(field_str) do
      nil ->
        socket

      field ->
        current = Map.get(socket.assigns.page, field, 1)
        assign(socket, :page, Map.put(socket.assigns.page, field, current + delta))
    end
  end

  # `phx-value-field` is always rendered from a known `@sections` field
  # (see the template), so this succeeds for any legitimate client
  # interaction; a bogus/tampered event value fails closed to `nil`
  # instead of crashing the LiveView process.
  defp to_field(field_str) do
    String.to_existing_atom(field_str)
  rescue
    ArgumentError -> nil
  end

  defp shopify_connection do
    case Integrations.list_connections("shopify", owner: :system) do
      [connection | _rest] -> connection
      [] -> nil
    end
  end

  # Groups `changes` by field, in `@sections` order, dropping fields with
  # no matching changes. A change appears once per field it differs on.
  defp group_by_field(changes) do
    for {field, _label} <- @sections,
        matching = Enum.filter(changes, &Map.has_key?(&1.changes, field)),
        matching != [],
        do: {field, matching}
  end

  @doc false
  # Public (not documented as API) so it can be unit-tested directly with
  # a synthetic multi-field change list. That is not a style choice: for
  # real input this restriction can never be exercised through the full
  # check → render flow — `StorefrontClient` trims every fetched product
  # to `"handle"`/`"variants"` before `ProductDiff` ever sees it, and
  # `Source` hands `ProductDiff.diff/4` `only: [:price]` for the
  # storefront path — so `@changes` structurally cannot carry a
  # non-price field when `@source == :storefront`. The filter below is
  # the second, independent guard for that same guarantee at the page
  # layer; without a direct unit test on synthetic data, no mutation
  # that deletes it could ever be caught by an end-to-end test, because
  # no real scenario reaches the branch it protects.
  @spec visible_sections([Change.t()], :admin | :storefront | nil) :: [{atom(), [Change.t()]}]
  def visible_sections(changes, source) do
    changes
    |> group_by_field()
    |> Enum.filter(fn {field, _matching} -> source != :storefront or field == :price end)
  end

  defp build_sections(%{changes: nil}), do: []

  defp build_sections(assigns) do
    assigns.changes
    |> visible_sections(assigns.source)
    |> Enum.map(&build_section(&1, assigns))
  end

  defp build_section({field, field_changes}, assigns) do
    count = length(field_changes)
    page = current_page(assigns.page, field, count)
    expanded? = MapSet.member?(assigns.expanded_sections, field)
    {eligible, excluded} = split_bulk_eligible(field_changes, field)

    rows =
      if expanded? do
        field_changes
        |> Enum.slice((page - 1) * @per_page, @per_page)
        |> Enum.map(&build_row(&1, field, assigns))
      else
        []
      end

    %{
      field: field,
      label: section_label(field),
      count: count,
      bulk_eligible_count: length(eligible),
      bulk_excluded_count: length(excluded),
      expanded?: expanded?,
      page: page,
      total_pages: total_pages(count),
      rows: rows
    }
  end

  defp build_everything(%{changes: nil}), do: %{eligible_count: 0, excluded_count: 0}

  defp build_everything(assigns) do
    {eligible, excluded} = applicable_for_everything(assigns.changes, assigns.source)
    %{eligible_count: length(eligible), excluded_count: length(excluded)}
  end

  defp build_row(change, field, assigns) do
    %{current: current, incoming: incoming} = Map.fetch!(change.changes, field)
    text? = field in @text_fields
    expanded? = MapSet.member?(assigns.expanded_rows, {field, change.product_uuid})

    %{
      change: change,
      product_uuid: change.product_uuid,
      title: change.title,
      current: current,
      incoming: incoming,
      text?: text?,
      expanded?: expanded?,
      summary: text? && TextDiff.summary(current || "", incoming || ""),
      words: text? && expanded? && TextDiff.words(current || "", incoming || "")
    }
  end

  defp section_label(field), do: Map.fetch!(@section_labels, field)
  defp field_label(field), do: Map.get(@field_labels, field, Atom.to_string(field))

  # `:body_html` never reaches here — it's in `@text_fields`, so its row
  # always takes the `row.text?` branch in the template, never the
  # `format_value/2` current/incoming line below.
  defp format_value(:tags, value) when is_list(value), do: Enum.join(value, ", ")
  defp format_value(:price, %Decimal{} = value), do: Decimal.to_string(value)
  defp format_value(_field, value), do: to_string(value)

  defp confirm_row(field, row) when field in @text_fields do
    gettext("Update %{title}'s %{field} from Shopify?",
      title: row.title,
      field: field_label(field)
    )
  end

  defp confirm_row(field, row) do
    gettext("Update %{title}: %{field} → %{value}?",
      title: row.title,
      field: field_label(field),
      value: format_value(field, row.incoming)
    )
  end

  defp confirm_section(field, eligible_count, excluded_count) do
    base =
      ngettext(
        "Apply %{count} %{field} change from Shopify?",
        "Apply %{count} %{field} changes from Shopify?",
        eligible_count,
        count: eligible_count,
        field: field_label(field)
      )

    append_excluded_notice(base, excluded_count)
  end

  defp confirm_everything(eligible_count, excluded_count) do
    base =
      ngettext(
        "Apply pending changes for %{count} product across all sections?",
        "Apply pending changes for %{count} products across all sections?",
        eligible_count,
        count: eligible_count
      )

    append_excluded_notice(base, excluded_count)
  end

  defp append_excluded_notice(base, 0), do: base

  defp append_excluded_notice(base, excluded_count) do
    base <>
      " " <>
      ngettext(
        "%{count} extreme price change is excluded and must be applied individually.",
        "%{count} extreme price changes are excluded and must be applied individually.",
        excluded_count,
        count: excluded_count
      )
  end

  defp row_summary_text(%{fragments: fragments, length_delta: delta}) do
    ngettext(
      "%{count} changed region (%{delta})",
      "%{count} changed regions (%{delta})",
      fragments,
      count: fragments,
      delta: delta_text(delta)
    )
  end

  defp delta_text(delta) when delta > 0, do: "+#{delta}"
  defp delta_text(delta) when delta < 0, do: Integer.to_string(delta)
  defp delta_text(0), do: gettext("no length change")

  defp fragment_class(:eq), do: "diff-eq"
  defp fragment_class(:del), do: "diff-del line-through opacity-60"
  defp fragment_class(:ins), do: "diff-ins bg-success/20"

  defp total_pages(count), do: max(ceil_div(count, @per_page), 1)
  defp ceil_div(a, b), do: div(a + b - 1, b)

  defp current_page(page_map, field, count) do
    page_map
    |> Map.get(field, 1)
    |> max(1)
    |> min(total_pages(count))
  end

  defp page_info_text(page, count) do
    start_idx = (page - 1) * @per_page + 1
    end_idx = min(page * @per_page, count)
    "#{start_idx}-#{end_idx} of #{count}"
  end

  defp format_error(:unauthorized) do
    gettext("Shopify rejected the access token — check the connection's credentials.")
  end

  defp format_error(:shop_not_found) do
    gettext("Shop domain not found — check the connection's shop domain.")
  end

  defp format_error(:rate_limited) do
    gettext("Shopify rate-limited this request — try again shortly.")
  end

  defp format_error(:missing_credentials) do
    gettext("The Shopify connection is missing its shop domain or access token.")
  end

  defp format_error(reason) do
    gettext("Could not reach Shopify: %{reason}", reason: inspect(reason))
  end

  defp format_fallback_reason(:unauthorized) do
    gettext("the access token was rejected")
  end

  defp format_fallback_reason(:forbidden) do
    gettext("the access token is missing the required scope")
  end

  defp format_fallback_reason(:missing_credentials) do
    # Reaching this path at all requires a usable shop domain (Source's
    # fallback guard), so this specific reason can only mean the access
    # token itself is blank — never the domain.
    gettext("the connection is missing its access token")
  end

  defp format_fallback_reason(reason) do
    gettext("the Admin API request was rejected (%{reason})", reason: inspect(reason))
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:sections, build_sections(assigns))
      |> assign(:everything, build_everything(assigns))

    ~H"""
    <div class="container mx-auto px-4 py-6 max-w-5xl">
      <.admin_page_header title={gettext("Shopify Sync")}>
        <:actions>
          <button
            :if={@connection}
            class="btn btn-primary"
            phx-click="check"
            disabled={@checking}
            id="check-shopify-changes"
          >
            <span :if={@checking} class="loading loading-spinner loading-sm"></span>
            {gettext("Check for changes")}
          </button>
        </:actions>
      </.admin_page_header>

      <div class="space-y-6 mt-6">
        <div :if={is_nil(@connection)} class="alert alert-warning">
          <span>
            {gettext("Shopify isn't connected yet.")}
            <.link navigate={Routes.path("/admin/settings/integrations/website")} class="link">
              {gettext("Connect it in Integrations settings.")}
            </.link>
          </span>
        </div>

        <div :if={@connection} class="text-sm text-base-content/70">
          {gettext("Connected: %{name}", name: @connection.name)}
        </div>

        <div :if={@error} class="alert alert-error">
          <span>{@error}</span>
        </div>

        <div
          :if={@source == :storefront}
          id="storefront-fallback-notice"
          class="alert alert-warning"
        >
          <span>
            {gettext(
              "Showing price-only changes — %{reason}. Connect a valid Admin API token to see the full diff.",
              reason: format_fallback_reason(@fallback_reason)
            )}
          </span>
        </div>

        <%!-- Reserved: once the owner decides, a line reporting how many
             Shopify products have no local counterpart goes here — right
             after the connection/fallback banners, before the diff
             results, so it reads as a summary of what this check covered. --%>

        <div :if={@changes == [] && @source == :admin} class="alert alert-success">
          {gettext("No changes — the shop matches Shopify.")}
        </div>

        <div
          :if={@changes == [] && @source == :storefront}
          id="storefront-no-price-changes"
          class="alert alert-info"
        >
          <%= if @applied_any? do %>
            {gettext("All price changes have been applied.")}
          <% else %>
            {gettext(
              "No price differences found. Other fields were not compared — see the notice above."
            )}
          <% end %>
        </div>

        <div :if={@changes not in [nil, []]} class="space-y-4">
          <div class="flex items-center justify-end">
            <button
              type="button"
              id="apply-everything"
              class="btn btn-sm btn-primary"
              phx-click="apply_everything"
              disabled={@everything.eligible_count == 0}
              data-confirm={confirm_everything(@everything.eligible_count, @everything.excluded_count)}
            >
              {gettext("Apply everything")}
            </button>
          </div>

          <div
            :for={section <- @sections}
            id={"field-section-#{section.field}"}
            class="border border-base-300 rounded-lg bg-base-100"
          >
            <div class="flex items-center justify-between gap-4 p-3">
              <button
                type="button"
                id={"toggle-section-#{section.field}"}
                phx-click="toggle_section"
                phx-value-field={section.field}
                class="flex items-center gap-2 font-semibold"
              >
                <.icon
                  name="hero-chevron-right"
                  class={
                    "w-4 h-4 transition-transform" <>
                      if(section.expanded?, do: " rotate-90", else: "")
                  }
                />
                {section.label}
                <span class="badge badge-neutral badge-sm">{section.count}</span>
              </button>

              <button
                :if={section.expanded?}
                type="button"
                id={"apply-section-#{section.field}"}
                class="btn btn-xs btn-primary"
                phx-click="apply_section"
                phx-value-field={section.field}
                disabled={section.bulk_eligible_count == 0}
                data-confirm={confirm_section(section.field, section.bulk_eligible_count, section.bulk_excluded_count)}
              >
                {gettext("Apply section")}
              </button>
            </div>

            <div :if={section.expanded?} class="border-t border-base-300 divide-y divide-base-200">
              <div
                :for={row <- section.rows}
                id={"change-row-#{section.field}-#{row.product_uuid}"}
                class="p-3"
              >
                <div class="flex items-center justify-between gap-3">
                  <div class="min-w-0">
                    <div class="font-medium truncate">{row.title}</div>

                    <div :if={row.text?} class="text-sm text-base-content/70">
                      {row_summary_text(row.summary)}
                    </div>
                    <div
                      :if={not row.text?}
                      class="text-sm text-base-content/70 flex items-center gap-1 flex-wrap"
                    >
                      <span>{format_value(section.field, row.current)}</span>
                      <span>→</span>
                      <span>{format_value(section.field, row.incoming)}</span>
                      <span
                        :if={section.field == :price && row.change.price_extreme?}
                        class="badge badge-warning badge-sm ml-1"
                      >
                        {gettext("large change")}
                      </span>
                    </div>
                  </div>

                  <div class="flex items-center gap-2 shrink-0">
                    <button
                      :if={row.text?}
                      type="button"
                      id={"toggle-diff-#{section.field}-#{row.product_uuid}"}
                      phx-click="toggle_row"
                      phx-value-field={section.field}
                      phx-value-uuid={row.product_uuid}
                      class="btn btn-xs btn-ghost"
                    >
                      {if row.expanded?, do: gettext("Hide diff"), else: gettext("Show diff")}
                    </button>

                    <button
                      type="button"
                      id={"apply-row-#{section.field}-#{row.product_uuid}"}
                      class="btn btn-xs btn-primary"
                      phx-click="apply_row"
                      phx-value-field={section.field}
                      phx-value-uuid={row.product_uuid}
                      data-confirm={confirm_row(section.field, row)}
                    >
                      {gettext("Apply")}
                    </button>
                  </div>
                </div>

                <div :if={row.expanded? && row.text?} class="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
                  <div>
                    <div class="text-xs font-semibold uppercase text-base-content/50 mb-1">
                      {gettext("Current")}
                    </div>
                    <pre class="whitespace-pre-wrap text-sm bg-base-200 rounded p-2 max-h-64 overflow-y-auto"><span
                        :for={{op, text} <- row.words}
                        :if={op != :ins}
                        class={fragment_class(op)}
                        phx-no-curly-interpolation
                      ><%= text %></span></pre>
                  </div>
                  <div>
                    <div class="text-xs font-semibold uppercase text-base-content/50 mb-1">
                      {gettext("Incoming")}
                    </div>
                    <pre class="whitespace-pre-wrap text-sm bg-base-200 rounded p-2 max-h-64 overflow-y-auto"><span
                        :for={{op, text} <- row.words}
                        :if={op != :del}
                        class={fragment_class(op)}
                        phx-no-curly-interpolation
                      ><%= text %></span></pre>
                  </div>
                </div>
              </div>

              <div
                :if={section.total_pages > 1}
                class="flex items-center justify-between p-2 bg-base-200/50"
              >
                <button
                  type="button"
                  id={"page-prev-#{section.field}"}
                  phx-click="page_prev"
                  phx-value-field={section.field}
                  class="btn btn-xs"
                  disabled={section.page == 1}
                >
                  « {gettext("Prev")}
                </button>
                <span id={"page-info-#{section.field}"} class="text-xs text-base-content/60">
                  {page_info_text(section.page, section.count)}
                </span>
                <button
                  type="button"
                  id={"page-next-#{section.field}"}
                  phx-click="page_next"
                  phx-value-field={section.field}
                  class="btn btn-xs"
                  disabled={section.page == section.total_pages}
                >
                  {gettext("Next")} »
                </button>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
