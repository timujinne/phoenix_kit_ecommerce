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

  ## Applying changes: request → confirm, never a direct write

  Every apply affordance (one field on one product, a whole section, the
  checked rows in a section, or everything) is two-phase: a `request_*`
  event validates the click and stashes what it would do in `@pending`,
  then renders `<.confirm_modal>` describing it; only `"confirm_apply"`
  (the modal's own confirm button) calls into `Sync.apply_change/2` /
  `apply_changes/2`. `"cancel_apply"` — and re-deriving what to write from
  live `@changes` at confirm time rather than trusting whatever `@pending`
  captured at request time — both exist so a stale or cancelled
  confirmation can never turn into a write; see `clear_pending/1` and the
  `do_confirm_*` functions. This replaces the page's previous
  `data-confirm` (a bare browser `confirm()`, which cannot show the
  extreme-price exclusion notice below) with PhoenixKit's own modal.

  ## Selection is a bulk scope, scoped to one section, one page

  A checkbox column (`<.bulk_select_scope>` / `bulk_select_cell`) lets an
  operator pick specific rows within one expanded section and apply just
  that field to just those products via "Apply selection" — distinct from
  "Apply section" (every row) and a single row's own "Apply" button.
  Selection is client-side (see `BulkSelectScope`'s JS-hook moduledoc) and
  scoped to the section's CURRENT PAGE of `@per_page`; paging re-renders
  the row set, which prunes any selection that isn't on the new page — so
  selection deliberately does not persist across pages. Like "Apply
  section", it excludes extreme price changes (`price_extreme?`) from the
  bulk write; see `split_bulk_eligible/2`.
  """

  use PhoenixKitEcommerce.Web, :live_view

  import PhoenixKitWeb.Components.Core.AdminPageHeader
  import PhoenixKitWeb.Components.Core.BulkSelect
  import PhoenixKitWeb.Components.Core.EmptyState

  alias PhoenixKit.Integrations
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Activity
  alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
  alias PhoenixKitEcommerce.Shopify.Sync
  alias PhoenixKitEcommerce.Shopify.TextDiff
  alias PhoenixKitEcommerce.Web.Authz

  # Section order — price first, per spec. Order only: the plural section
  # headers live in `section_label/1` and the singular per-field wording
  # in `field_label/1`, both as one `gettext/1` call per field. They used
  # to be string literals carried in this attribute and a `@field_labels`
  # map, which is why every section header and every `%{field}` binding
  # on this page rendered in English under a translated locale: a module
  # attribute holds a compile-time literal that `mix gettext.extract`
  # never sees, and `gettext/1` refuses a runtime variable as its key, so
  # there was no way to translate them from where they were stored.
  @sections [:price, :title, :description, :body_html, :tags, :status, :vendor]

  # Fields long enough to need a word-level diff instead of a plain
  # current → incoming line. `TextDiff.summary/2` and `TextDiff.words/2`
  # are only ever called for these.
  #
  # `:title` is deliberately NOT here, even though it's short prose like
  # the other two: a title row is what an operator looks at most (title
  # differences dominate a real sync's change set), and the word-level
  # summary ("N changed regions (+5)") never shows the actual incoming
  # text — only expanding the row's diff panel does. A row the operator
  # applies without ever reading what they're applying is a worse
  # trade-off for a short field than for `:description`/`:body_html`,
  # where the summary view is what makes a paragraph-or-more diff
  # tractable at all. `:title` gets the plain current → incoming line
  # `row_change_summary/1` already renders for `:vendor`/`:tags`/etc.
  @text_fields [:description, :body_html]

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
    # Design §4.7: `shop_shopify_enabled` gates this page's mere reachability
    # — a direct link to a turned-off sync must not open it, mirroring
    # `Web.Translations`' own guard for `shop_translations_enabled`.
    if Shop.shopify_enabled?() do
      {:ok,
       socket
       |> assign(:page_title, gettext("Shopify Sync"))
       |> assign(:connection, shopify_connection())
       |> assign(:checking, false)
       |> assign(:changes, nil)
       |> assign(:error, nil)
       |> assign(:source, nil)
       |> assign(:fallback_reason, nil)
       |> assign(:total_shopify_products, nil)
       |> assign(:matched_local_products, nil)
       |> assign(:expanded_sections, MapSet.new())
       |> assign(:expanded_rows, MapSet.new())
       |> assign(:page, %{})
       |> assign(:applied_any?, false)
       |> assign(:pending, nil)}
    else
      {:ok,
       socket
       |> put_flash(
         :error,
         gettext("Shopify sync is turned off. Turn it on in E-Commerce settings first.")
       )
       |> push_navigate(to: Routes.path("/admin/shop"))}
    end
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
             total_shopify_products: nil,
             matched_local_products: nil,
             expanded_sections: MapSet.new(),
             expanded_rows: MapSet.new(),
             page: %{},
             applied_any?: false,
             pending: nil
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

  # --- Request phase: validate the click, stash what it would do in
  # @pending, open the confirm modal. Nothing is written here — see the
  # moduledoc section on the request -> confirm flow.

  def handle_event("request_apply_row", %{"field" => field_str, "uuid" => uuid}, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      changes = socket.assigns.changes || []

      # Through `visible_field_changes/3`, like the section/selection/
      # everything paths — a row apply is the third way into a write and
      # `Map.has_key?(&1.changes, field)` alone doesn't know `field` is
      # hidden for the current `source`. See `visible_changes/2`'s doc.
      with field when not is_nil(field) <- to_field(field_str),
           true <-
             changes
             |> visible_field_changes(socket.assigns.source, field)
             |> Enum.any?(&(&1.product_uuid == uuid)) do
        {:noreply, assign(socket, :pending, %{scope: :row, field: field, uuid: uuid})}
      else
        _ -> {:noreply, socket}
      end
    end)
  end

  def handle_event("request_apply_section", %{"field" => field_str}, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      case to_field(field_str) do
        nil ->
          {:noreply, socket}

        field ->
          changes = socket.assigns.changes || []
          section_changes = visible_field_changes(changes, socket.assigns.source, field)
          {eligible, _excluded} = split_bulk_eligible(section_changes, field)
          open_pending(socket, eligible, %{scope: :section, field: field})
      end
    end)
  end

  def handle_event("request_apply_everything", _params, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      changes = socket.assigns.changes || []
      {eligible, _excluded} = applicable_for_everything(changes, socket.assigns.source)
      open_pending(socket, eligible, %{scope: :everything})
    end)
  end

  # Field is smuggled into the event name (not the payload) because the
  # `BulkSelectScope` JS hook's `data-bulk-action` click handler always
  # pushes exactly `%{"uuids" => [...]}` — it has no way to attach an
  # extra `phx-value-*` to that payload. One event name per section field
  # is the same technique the hook already documents for `on_open_reorder`
  # (a single fixed event) generalised to N sections.
  def handle_event("request_apply_selection:" <> field_str, %{"uuids" => uuids}, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      case to_field(field_str) do
        nil ->
          {:noreply, socket}

        field ->
          uuid_set = MapSet.new(uuids)
          changes = socket.assigns.changes || []
          field_changes = visible_field_changes(changes, socket.assigns.source, field)
          matching = Enum.filter(field_changes, &MapSet.member?(uuid_set, &1.product_uuid))
          {eligible, excluded} = split_bulk_eligible(matching, field)

          open_pending(socket, eligible, %{
            scope: :selection,
            field: field,
            uuids: MapSet.new(eligible, & &1.product_uuid),
            excluded_count: length(excluded)
          })
      end
    end)
  end

  # --- Confirm phase: re-derive what to write from LIVE @changes (never
  # from @pending's own snapshot) so a stale confirmation — e.g. one of
  # the pending rows/uuids was already applied or dropped by the time the
  # operator clicks Confirm — can only ever act on what's still actually
  # pending, the same principle `apply_row`'s old `Map.has_key?` guard
  # protected before this file had a modal at all.

  def handle_event("confirm_apply", _params, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      case socket.assigns.pending do
        nil -> {:noreply, socket}
        %{scope: :row, field: field, uuid: uuid} -> confirm_row_apply(socket, field, uuid)
        %{scope: :section, field: field} -> confirm_section_apply(socket, field)
        %{scope: :selection} = pending -> confirm_selection_apply(socket, pending)
        %{scope: :everything} -> confirm_everything_apply(socket)
      end
    end)
  end

  # No Authz guard: cancelling has no side effect beyond clearing UI
  # state, and an operator whose permission was revoked mid-session must
  # still be able to dismiss the modal.
  def handle_event("cancel_apply", _params, socket) do
    {:noreply, assign(socket, :pending, nil)}
  end

  defp confirm_row_apply(socket, field, uuid) do
    changes = socket.assigns.changes || []
    visible = visible_field_changes(changes, socket.assigns.source, field)

    case Enum.find(visible, &(&1.product_uuid == uuid)) do
      nil -> {:noreply, assign(socket, :pending, nil)}
      change -> socket |> apply_row_change(changes, change, field) |> clear_pending()
    end
  end

  defp confirm_section_apply(socket, field) do
    socket |> apply_section_changes(field) |> clear_pending()
  end

  defp confirm_selection_apply(socket, %{field: field, uuids: uuids}) do
    changes = socket.assigns.changes || []
    field_changes = visible_field_changes(changes, socket.assigns.source, field)
    matching = Enum.filter(field_changes, &MapSet.member?(uuids, &1.product_uuid))

    # Re-run the extreme-price guard rather than trusting `uuids` (already
    # excluded once, at request time): a Change struct is never mutated
    # in place today, so this is currently a no-op re-check — but making
    # it an explicit re-check instead of an implicit invariant means the
    # guard survives even if that stops being true.
    {eligible, _excluded} = split_bulk_eligible(matching, field)
    %{succeeded: succeeded, failed: failed} = Sync.apply_changes(eligible, [field])

    socket =
      if succeeded != [] do
        Activity.log("shop.shopify_sync_bulk_selection_apply",
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
    |> clear_pending()
  end

  defp confirm_everything_apply(socket) do
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
    |> clear_pending()
  end

  # Always clears @pending, win or lose — a failed write still leaves the
  # failing row visible in its section (see `flash_bulk_result`'s error
  # branch), it just shouldn't leave a stale confirmation hanging open.
  defp clear_pending({:noreply, socket}), do: {:noreply, assign(socket, :pending, nil)}

  # Common guard for the three bulk request handlers: an empty eligible
  # set (nothing pending, or everything pending is an extreme-price
  # change) never opens the modal — matches the buttons' own `disabled`
  # state, and stops a stale/tampered event from opening a confirmation
  # for zero actual writes.
  defp open_pending(socket, [], _pending), do: {:noreply, socket}
  defp open_pending(socket, _eligible, pending), do: {:noreply, assign(socket, :pending, pending)}

  @impl true
  def handle_async(
        :check_diff,
        {:ok,
         {:ok,
          %{
            changes: changes,
            source: source,
            fallback_reason: reason,
            total_shopify_products: total_shopify_products,
            matched_local_products: matched_local_products
          }}},
        socket
      ) do
    {:noreply,
     assign(socket,
       checking: false,
       changes: changes,
       source: source,
       fallback_reason: reason,
       total_shopify_products: total_shopify_products,
       matched_local_products: matched_local_products
     )}
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
    section_changes = visible_field_changes(changes, socket.assigns.source, field)
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

  @doc false
  # Public for the same reason as `visible_sections/2` below: a real
  # check → render flow can never carry a hidden field on a :storefront
  # change, so only a direct call with synthetic data can prove this
  # trims rather than merely filters — see the note below.
  #
  # The changes `apply_everything` may touch — each trimmed down to ONLY
  # the fields `field_visible?/2` allows for `source`. Trimming, not just
  # filtering which changes survive, is the part that actually matters:
  # `confirm_everything_apply` hands the result straight to
  # `Sync.apply_changes(eligible, :all)`, and `:all` writes every key
  # still present in `change.changes` — a change kept here with its
  # full, untrimmed field map would let `:all` write a field
  # `visible_sections/2` hides from the very same `source`, even though
  # the change itself "passed" the filter on some OTHER, visible field.
  # (An earlier version of this function filtered changes but left each
  # one's `changes` map untouched — passing 634 tests while doing
  # exactly that, because no real check → render flow can ever produce a
  # :storefront change carrying a second, hidden field to catch it with.
  # Read `field_visible?/2`'s doc before trusting an end-to-end test to
  # prove this kind of thing again.)
  @spec visible_changes([Change.t()], :admin | :storefront | nil) :: [Change.t()]
  def visible_changes(changes, source) do
    changes
    |> Enum.map(&trim_to_visible_fields(&1, source))
    |> Enum.reject(&(&1.changes == %{}))
  end

  defp trim_to_visible_fields(change, source) do
    %{
      change
      | changes: Map.filter(change.changes, fn {field, _} -> field_visible?(field, source) end)
    }
  end

  @doc false
  # Public (not documented as API), same reason as `visible_sections/2`
  # above: a real check → render flow can't reach the branch this
  # protects either (a `:storefront` result structurally can't carry a
  # non-`:price` field), so only a direct test with synthetic data can
  # ever catch a mutation that deletes this filtering.
  #
  # The rows a bulk write to one `field` may touch — every change
  # `visible_sections/2` would actually render for that field. "Apply
  # section" and "Apply selection" both need this, not just
  # `apply_everything`: the same failure `visible_changes/2`'s doc warns
  # about (a broken upstream guarantee letting a write reach a section
  # the page is hiding) is just as reachable through either of them —
  # `Map.has_key?(&1.changes, field)` alone doesn't know `field` is
  # hidden for the current `source`.
  @spec visible_field_changes([Change.t()], :admin | :storefront | nil, atom()) :: [Change.t()]
  def visible_field_changes(changes, source, field) do
    changes
    |> visible_sections(source)
    |> List.keyfind(field, 0, {field, []})
    |> elem(1)
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
        # The CLAMPED current page, not the raw stored one: applying a
        # section's last row shrinks its count, which can snap the
        # DISPLAYED page back (`current_page/3`'s own clamp) while the
        # STORED value stays at the now-out-of-range page it was on.
        # Reading raw here would then compute the next page relative to
        # a page the operator was never actually looking at, and a Prev
        # click right after such an apply would silently move the
        # stored value without moving the display — a no-op the operator
        # has no way to explain. See the regression test for the exact
        # 51-row repro.
        count = field_change_count(socket, field)
        current = current_page(socket.assigns.page, field, count)

        # A pending confirmation is scoped to the rows visible when it was
        # opened (a row's or a selection's uuids belong to THAT page) — see
        # the moduledoc's note that selection deliberately doesn't persist
        # across pages. Paging away must not leave a modal open that could
        # still confirm into a write for rows no longer on screen.
        socket
        |> assign(:page, Map.put(socket.assigns.page, field, current + delta))
        |> assign(:pending, nil)
    end
  end

  defp field_change_count(socket, field) do
    (socket.assigns.changes || [])
    |> visible_field_changes(socket.assigns.source, field)
    |> length()
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
    for field <- @sections,
        matching = Enum.filter(changes, &Map.has_key?(&1.changes, field)),
        matching != [],
        do: {field, matching}
  end

  # Whether `field` is part of what `source` can legitimately carry — the
  # single predicate `visible_sections/2` (which section headers render)
  # and `visible_changes/2` (which fields a bulk write may touch) both
  # filter through, so the two can't independently drift out of sync the
  # way `visible_changes/2`'s own doc describes actually happening once.
  defp field_visible?(field, source), do: source != :storefront or field == :price

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
    |> Enum.filter(fn {field, _matching} -> field_visible?(field, source) end)
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
      per_page: @per_page,
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

  # Plural section headers, one `gettext/1` call per field so the literal
  # is extractable. `Map.fetch!`'s old crash-on-unknown-field behaviour is
  # kept deliberately: `build_section/2` only ever passes a `@sections`
  # field, and a silent English fallback there would hide a section added
  # to `@sections` without a header.
  defp section_label(:price), do: gettext("Prices")
  defp section_label(:title), do: gettext("Titles")
  defp section_label(:description), do: gettext("Descriptions")
  defp section_label(:body_html), do: gettext("HTML texts")
  defp section_label(:tags), do: gettext("Tags")
  defp section_label(:status), do: gettext("Statuses")
  defp section_label(:vendor), do: gettext("Vendors")

  # Singular wording for row/confirm text — kept in lockstep with
  # `section_label/1`'s plural headers above (drop the trailing "s").
  # `:body_html` used to read "Description (HTML)" here while its own
  # section header read "HTML texts" a few lines up — two different
  # names for the same field on the same page, right next to the
  # actually-different `:description` field's "Description"/"Descriptions".
  # "HTML text(s)" now matches its section exactly.
  #
  # ⚠️ These are interpolated into whole sentences as `%{field}`
  # ("Apply %{count} %{field} changes from Shopify?"), so a translator
  # only ever sees the noun in isolation and the sentence in isolation.
  # That is the limitation `PhoenixKitEcommerce.Vocabulary` exists to
  # avoid on the storefront, where the same shape would need a separate
  # complete literal per noun. It is accepted here because this is the
  # admin surface and the alternative is seven full sentence variants for
  # each of the eight `%{field}` strings on this page; a locale that
  # inflects will read the nominative noun in a slot the sentence may
  # want in another case. Do not copy this shape to a customer-facing
  # page.
  defp field_label(:title), do: gettext("Title")
  defp field_label(:body_html), do: gettext("HTML text")
  defp field_label(:description), do: gettext("Description")
  defp field_label(:vendor), do: gettext("Vendor")
  defp field_label(:tags), do: gettext("Tags")
  defp field_label(:status), do: gettext("Status")
  defp field_label(:price), do: gettext("Price")
  defp field_label(field), do: Atom.to_string(field)

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

  defp confirm_section_prompt(field, eligible_count) do
    ngettext(
      "Apply %{count} %{field} change from Shopify?",
      "Apply %{count} %{field} changes from Shopify?",
      eligible_count,
      count: eligible_count,
      field: field_label(field)
    )
  end

  defp confirm_selection_prompt(field, eligible_count) do
    ngettext(
      "Apply the selected %{field} change from Shopify?",
      "Apply %{count} selected %{field} changes from Shopify?",
      eligible_count,
      count: eligible_count,
      field: field_label(field)
    )
  end

  defp confirm_everything_prompt(eligible_count) do
    ngettext(
      "Apply pending changes for %{count} product across all sections?",
      "Apply pending changes for %{count} products across all sections?",
      eligible_count,
      count: eligible_count
    )
  end

  # A bare `confirm()` (the page's old `data-confirm`) can only ever show
  # one flat string — there is no way to make one sentence read as a
  # distinct warning. `<.confirm_modal>`'s `messages` list can, so the
  # extreme-price exclusion moves out of the prompt string (see the old
  # `append_excluded_notice/2`) and into its own `{:warning, _}` message.
  defp exclusion_messages(0), do: []

  defp exclusion_messages(excluded_count) do
    [
      {:warning,
       ngettext(
         "%{count} extreme price change is excluded and must be applied individually.",
         "%{count} extreme price changes are excluded and must be applied individually.",
         excluded_count,
         count: excluded_count
       )}
    ]
  end

  # Builds the `<.confirm_modal>` attrs for the current `@pending` action.
  # Always re-derives eligible/excluded counts from LIVE `@changes` (not
  # from whatever was true when the request_* handler opened the modal —
  # see the moduledoc), except for `:selection`, whose `@pending` already
  # carries its own eligible uuid set and excluded count fixed at request
  # time: a selection is an explicit, closed list of uuids the operator
  # picked, not a re-derivable "everything currently matching field X".
  defp pending_modal(%{pending: nil}), do: nil

  defp pending_modal(%{pending: %{scope: :row, field: field, uuid: uuid}, changes: changes}) do
    case Enum.find(changes || [], &(&1.product_uuid == uuid)) do
      nil ->
        nil

      change ->
        %{incoming: incoming} = Map.fetch!(change.changes, field)

        %{
          title: gettext("Apply change?"),
          prompt: confirm_row(field, %{title: change.title, incoming: incoming}),
          messages: [],
          danger: false
        }
    end
  end

  defp pending_modal(%{
         pending: %{scope: :section, field: field},
         changes: changes,
         source: source
       }) do
    section_changes = visible_field_changes(changes || [], source, field)
    {eligible, excluded} = split_bulk_eligible(section_changes, field)

    %{
      title: gettext("Apply section?"),
      prompt: confirm_section_prompt(field, length(eligible)),
      messages: exclusion_messages(length(excluded)),
      danger: true
    }
  end

  defp pending_modal(%{
         pending: %{scope: :selection, field: field, uuids: uuids, excluded_count: excluded_count}
       }) do
    %{
      title: gettext("Apply selection?"),
      prompt: confirm_selection_prompt(field, MapSet.size(uuids)),
      messages: exclusion_messages(excluded_count),
      danger: true
    }
  end

  defp pending_modal(%{pending: %{scope: :everything}, changes: changes, source: source}) do
    {eligible, excluded} = applicable_for_everything(changes || [], source)

    %{
      title: gettext("Apply everything?"),
      prompt: confirm_everything_prompt(length(eligible)),
      messages: exclusion_messages(length(excluded)),
      danger: true
    }
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

  defp format_error(:unauthorized) do
    gettext("Shopify rejected the access token — check the connection's credentials.")
  end

  defp format_error(:shop_not_found) do
    gettext("Shop domain not found — check the connection's shop domain.")
  end

  # `AdminClient` maps a 403 here. Without this clause `:forbidden` — the
  # one error atom the unified-sync work introduced — fell through to the
  # generic `inspect/1` clause below and printed "Could not reach Shopify:
  # :forbidden", including as the leading half of `{:fallback_failed, ...}`
  # which exists precisely to put the actionable credential failure first.
  # `format_fallback_reason/1` has carried the right wording for this atom
  # all along; the two lists just drifted.
  defp format_error(:forbidden) do
    gettext("Shopify rejected the access token's scope — the app needs read_products.")
  end

  defp format_error(:rate_limited) do
    gettext("Shopify rate-limited this request — try again shortly.")
  end

  defp format_error(:missing_credentials) do
    gettext("The Shopify connection is missing its shop domain or access token.")
  end

  # `Source.fetch/2` reaches this when the Admin API failed on a
  # credential error AND the storefront fallback it tried in response
  # also failed (`Source`'s own moduledoc: token expired, shop not
  # published — an ordinary pairing). Leads with the credential
  # failure — the actionable half an operator needs to fix — rather than
  # letting `storefront_reason` alone reach `format_error/1`'s generic
  # clause below and read as "we could not reach Shopify" with no hint
  # the real problem is the connection's own access token.
  defp format_error({:fallback_failed, reason, storefront_reason}) do
    gettext("%{credential_error} The storefront fallback also failed: %{storefront_error}",
      credential_error: format_error(reason),
      storefront_error: inspect(storefront_reason)
    )
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

  defp storefront_empty_title(true), do: gettext("All price changes have been applied.")

  defp storefront_empty_title(false) do
    gettext("No price differences found. Other fields were not compared — see the notice above.")
  end

  # Header stat row, first two cards: total pending changes, and how many
  # of those are price changes. Both are just counts over `@changes`, so
  # they're meaningful on either source (`:admin` or `:storefront`) — a
  # storefront fallback just naturally has few/no non-price changes.
  # `nil` before the first successful check (mirrors `build_sections/1`'s
  # and `build_everything/1`'s own `%{changes: nil}` clauses) so the
  # template can gate on `@stats != nil` without a separate flag.
  defp build_change_stats(%{changes: nil}), do: nil

  defp build_change_stats(assigns) do
    %{
      total_changes: length(assigns.changes),
      price_changes: Enum.count(assigns.changes, &Map.has_key?(&1.changes, :price))
    }
  end

  # Header stat row, third card: how much of the Shopify catalog this
  # check can even see. `matched_local_products` (from
  # `Sync.check/2` / `ProductDiff.matched_count/3`) is the numerator —
  # NOT `length(@changes)` (undercounts: a matched-but-identical product
  # is matched with no change to show) and NOT the local catalog's total
  # size (overcounts: a local product with no Shopify handle match was
  # never in this check's reach at all).
  #
  # `nil` — no card at all — whenever the source isn't `:admin`. The
  # storefront fallback's `total_shopify_products` only counts products
  # published to the Online Store (see `Sync.check/2`'s moduledoc): a
  # narrower population than the Admin API's full catalog, so a
  # percentage computed from it would silently mean something different
  # from the admin-path number right next to it on a later check.
  defp build_coverage(%{changes: nil}), do: nil
  defp build_coverage(%{source: source}) when source != :admin, do: nil

  defp build_coverage(assigns) do
    %{
      matched: assigns.matched_local_products,
      shopify: assigns.total_shopify_products,
      percent: coverage_percent(assigns.matched_local_products, assigns.total_shopify_products)
    }
  end

  # A Shopify catalog of 0 products is a 0% (not undefined) coverage —
  # there's nothing to be missing from. Otherwise clamped to 100 — matched
  # can't exceed the Shopify total under normal operation, but nothing
  # forces that invariant across two independently-counted values, and a
  # coverage stat printing above 100% is a worse failure mode than one
  # quietly capped at it.
  #
  # Public for the same reason as `visible_sections/2` and
  # `visible_field_changes/3` above: `matched` structurally can't exceed
  # `shopify` through a real `Sync.check/2` result (it's a subset count
  # of it), so no end-to-end scenario can ever reach — or prove the
  # necessity of — the clamp. Only a direct call with synthetic numbers
  # can pin it.
  @doc false
  @spec coverage_percent(non_neg_integer(), non_neg_integer()) :: 0..100
  def coverage_percent(_matched, 0), do: 0
  def coverage_percent(matched, shopify), do: min(100, round(matched / shopify * 100))

  defp coverage_subtitle(percent) do
    gettext("%{percent}% of the Shopify catalogue", percent: percent)
  end

  # The `data-bulk-text-template` attribute value: kept `%{count}` intact
  # for the BulkSelectScope hook's own client-side substitution (same
  # technique `bulk_actions_toolbar`'s `reorder_selected_label` uses —
  # see that component for why `gettext_noop/1` would be wrong here).
  defp bulk_selected_template, do: gettext("%{count} selected", count: "%{count}")

  attr :words, :list, required: true

  # Shared between the table row's expanded detail and the mobile card's
  # (see `<.table_default>`'s dual table/card rendering — both views
  # exist in the DOM at once, CSS-toggled by breakpoint, so this markup
  # is genuinely rendered twice per expanded row either way; factoring it
  # out at least keeps the word-level diff markup itself in one place).
  defp diff_panel(assigns) do
    ~H"""
    <div class="mt-3 grid grid-cols-1 md:grid-cols-2 gap-3">
      <div>
        <div class="text-xs font-semibold uppercase text-base-content/50 mb-1">
          {gettext("Current")}
        </div>
        <pre class="whitespace-pre-wrap text-sm bg-base-200 rounded p-2 max-h-64 overflow-y-auto"><span
            :for={{op, text} <- @words}
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
            :for={{op, text} <- @words}
            :if={op != :del}
            class={fragment_class(op)}
            phx-no-curly-interpolation
          ><%= text %></span></pre>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :field, :atom, required: true

  # Also shared (safe to — nothing inside carries an `id`, so rendering it
  # once in the table cell and once in the card body never collides).
  defp row_change_summary(assigns) do
    ~H"""
    <div :if={@row.text?} class="text-sm text-base-content/70">
      {row_summary_text(@row.summary)}
    </div>
    <div :if={not @row.text?} class="text-sm text-base-content/70 flex items-center gap-1 flex-wrap">
      <span>{format_value(@field, @row.current)}</span>
      <span>→</span>
      <span>{format_value(@field, @row.incoming)}</span>
      <span
        :if={@field == :price && @row.change.price_extreme?}
        class="badge badge-warning badge-sm ml-1"
      >
        {gettext("large change")}
      </span>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :field, :atom, required: true

  attr :id_suffix, :string,
    default: "",
    doc:
      "`<.table_default>` renders the table AND card views into the DOM at once (CSS picks which shows per breakpoint — see its moduledoc), so this component rendered a second time for the card body would collide on id with the table row's buttons unless one instance gets a distinct suffix. The table-view call site keeps the bare (pre-existing, test-pinned) id; only the card-view call site passes a suffix."

  defp row_actions(assigns) do
    ~H"""
    <button
      :if={@row.text?}
      type="button"
      id={"toggle-diff-#{@field}-#{@row.product_uuid}#{@id_suffix}"}
      phx-click="toggle_row"
      phx-value-field={@field}
      phx-value-uuid={@row.product_uuid}
      class="btn btn-xs btn-ghost"
    >
      {if @row.expanded?, do: gettext("Hide diff"), else: gettext("Show diff")}
    </button>

    <button
      type="button"
      id={"apply-row-#{@field}-#{@row.product_uuid}#{@id_suffix}"}
      class="btn btn-xs btn-primary"
      phx-click="request_apply_row"
      phx-value-field={@field}
      phx-value-uuid={@row.product_uuid}
    >
      {gettext("Apply")}
    </button>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:sections, build_sections(assigns))
      |> assign(:everything, build_everything(assigns))
      |> assign(:modal, pending_modal(assigns))
      |> assign(:stats, build_change_stats(assigns))
      |> assign(:coverage, build_coverage(assigns))

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

        <div :if={@stats} class="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <div id="stat-total-changes">
            <.stat_card
              value={@stats.total_changes}
              title={gettext("Pending changes")}
              subtitle={gettext("Products with at least one field to review")}
              color="primary"
              compact
            >
              <:icon><.icon name="hero-arrow-path-rounded-square" class="w-5 h-5" /></:icon>
            </.stat_card>
          </div>
          <div id="stat-price-changes">
            <.stat_card
              value={@stats.price_changes}
              title={gettext("Price changes")}
              subtitle={gettext("Products whose price differs from Shopify")}
              color="warning"
              compact
            >
              <:icon><.icon name="hero-currency-dollar" class="w-5 h-5" /></:icon>
            </.stat_card>
          </div>
          <%!-- Admin-source only — see `build_coverage/1`'s moduledoc note:
               the storefront fallback's product total is a narrower,
               not-comparable population, so no percentage is shown for it. --%>
          <div :if={@coverage} id="stat-coverage">
            <.stat_card
              value={"#{@coverage.matched}/#{@coverage.shopify}"}
              title={gettext("Catalogue coverage")}
              subtitle={coverage_subtitle(@coverage.percent)}
              color="info"
              compact
            >
              <:icon><.icon name="hero-chart-pie" class="w-5 h-5" /></:icon>
            </.stat_card>
          </div>
        </div>

        <div :if={@changes == [] && @source == :admin}>
          <.empty_state
            icon="hero-check-circle"
            title={gettext("No changes — the shop matches Shopify.")}
          />
        </div>

        <div :if={@changes == [] && @source == :storefront} id="storefront-no-price-changes">
          <.empty_state
            icon="hero-information-circle"
            title={storefront_empty_title(@applied_any?)}
          />
        </div>

        <div :if={@changes not in [nil, []]} class="space-y-4">
          <div class="flex items-center justify-end">
            <button
              type="button"
              id="apply-everything"
              class="btn btn-sm btn-primary"
              phx-click="request_apply_everything"
              disabled={@everything.eligible_count == 0}
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
                phx-click="request_apply_section"
                phx-value-field={section.field}
                disabled={section.bulk_eligible_count == 0}
              >
                {gettext("Apply section")}
              </button>
            </div>

            <%!-- NOT <.accordion>: it's a native <details>, whose open state
                 lives in the browser — the server never learns a section
                 opened. That's fine for markup that's always fully
                 rendered, but this section's rows are NOT: `build_section/2`
                 only computes `TextDiff.summary/2` for an EXPANDED section's
                 CURRENT PAGE (25 rows), specifically so a ~500-product catalog
                 doesn't compute summaries for every pending row on every
                 render (see `@per_page`'s moduledoc — that used to be a ~6.3s
                 freeze). An <.accordion> section would have to render fully
                 up front for the browser-only toggle to reveal it instantly,
                 which reinstates exactly that freeze. Keep the server-driven
                 `expanded?`/`toggle_section` pair above instead. --%>
            <div :if={section.expanded?} class="border-t border-base-300">
              <%!-- Everything inside one `<.bulk_select_scope>` shares one
                   client-side selection set (see this module's moduledoc);
                   the bar below reads that set only when the operator
                   clicks "Apply selection" — see `request_apply_selection:`. --%>
              <.bulk_select_scope
                id={"bulk-select-#{section.field}"}
                total_count={length(section.rows)}
                class="p-3 space-y-3"
              >
                <div
                  class="hidden md:flex flex-wrap items-center gap-3 bg-base-200 rounded-lg px-3 py-2 text-sm"
                  data-bulk-show="has-selection"
                  style="display: none;"
                >
                  <span data-bulk-text-template={bulk_selected_template()}>
                    {gettext("%{count} selected", count: 0)}
                  </span>
                  <button
                    type="button"
                    id={"apply-selection-#{section.field}"}
                    class="btn btn-xs btn-primary ml-auto"
                    data-bulk-action={"request_apply_selection:" <> to_string(section.field)}
                  >
                    {gettext("Apply selection")}
                  </button>
                  <button type="button" class="btn btn-xs btn-ghost" data-bulk-clear>
                    <.icon name="hero-x-mark" class="w-4 h-4" /> {gettext("Clear")}
                  </button>
                </div>

                <.table_default
                  id={"section-table-#{section.field}"}
                  items={section.rows}
                  size="sm"
                >
                  <.table_default_header>
                    <.table_default_row>
                      <.bulk_select_header_cell
                        id={"bulk-select-all-#{section.field}"}
                        aria_label={gettext("Select all on this page")}
                      />
                      <.table_default_header_cell>{gettext("Product")}</.table_default_header_cell>
                      <.table_default_header_cell>{gettext("Change")}</.table_default_header_cell>
                      <.table_default_header_cell class="w-24" />
                    </.table_default_row>
                  </.table_default_header>
                  <.table_default_body>
                    <%= for row <- section.rows do %>
                      <.table_default_row id={"change-row-#{section.field}-#{row.product_uuid}"}>
                        <.bulk_select_cell value={row.product_uuid} />
                        <.table_default_cell class="font-medium max-w-xs truncate">
                          {row.title}
                        </.table_default_cell>
                        <.table_default_cell>
                          <.row_change_summary row={row} field={section.field} />
                        </.table_default_cell>
                        <.table_default_cell>
                          <div class="flex items-center gap-2 justify-end flex-wrap">
                            <.row_actions row={row} field={section.field} />
                          </div>
                        </.table_default_cell>
                      </.table_default_row>
                      <.table_default_row :if={row.expanded? && row.text?} hover={false}>
                        <.table_default_cell colspan={4}>
                          <.diff_panel words={row.words} />
                        </.table_default_cell>
                      </.table_default_row>
                    <% end %>
                  </.table_default_body>

                  <:card_body :let={row}>
                    <div class="font-medium">{row.title}</div>
                    <.row_change_summary row={row} field={section.field} />
                    <.diff_panel :if={row.expanded? && row.text?} words={row.words} />
                  </:card_body>
                  <:card_actions :let={row}>
                    <.row_actions row={row} field={section.field} id_suffix="-card" />
                  </:card_actions>
                </.table_default>
              </.bulk_select_scope>

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
                <div id={"page-info-#{section.field}"}>
                  <.pagination_info
                    page={section.page}
                    per_page={section.per_page}
                    total_count={section.count}
                  />
                </div>
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

      <%!-- `@modal`, not `@pending`: `pending_modal/1`'s `:row` clause
           returns nil when the pending change is no longer in `@changes`.
           Every path that mutates `@changes` clears `@pending` today, so
           that is an invariant rather than a live bug — but reading
           `@modal.title` off nil crashes the LiveView, and gating on the
           value actually dereferenced costs nothing. --%>
      <.confirm_modal
        :if={@modal}
        show={true}
        on_confirm="confirm_apply"
        on_cancel="cancel_apply"
        title={@modal.title}
        prompt={@modal.prompt}
        messages={@modal.messages}
        danger={@modal.danger}
      />
    </div>
    """
  end
end
