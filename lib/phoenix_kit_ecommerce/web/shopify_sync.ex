defmodule PhoenixKitEcommerce.Web.ShopifySync do
  @moduledoc """
  Admin LiveView for the Shopify → shop one-way sync.

  Fetches products from the Shopify Admin API connection registered in
  `PhoenixKitEcommerce.Shopify.Provider`, diffs them against the local
  catalog (`PhoenixKitEcommerce.Shopify.Sync.check/1`), and lets an
  operator apply changes — nothing is written without an explicit click.
  Price-only, non-extreme changes get a bulk "apply all" button (the
  proven shape from the single-store implementation this generalizes);
  every other change — any non-price field, or an extreme price swing —
  requires its own per-product confirmation.

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
  alias PhoenixKitEcommerce.Shopify.Sync
  alias PhoenixKitEcommerce.Web.Authz

  @field_labels %{
    title: "Title",
    body_html: "Description (HTML)",
    description: "Description",
    vendor: "Vendor",
    tags: "Tags",
    status: "Status",
    price: "Price"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, gettext("Shopify Sync"))
     |> assign(:connection, shopify_connection())
     |> assign(:checking, false)
     |> assign(:diff, nil)
     |> assign(:error, nil)}
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
           |> assign(checking: true, diff: nil, error: nil)
           |> start_async(:check_diff, fn -> Sync.check(uuid) end)}
      end
    end)
  end

  def handle_event("apply_safe_prices", _params, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      {safe, rest} = Enum.split_with(socket.assigns.diff || [], &price_only_safe?/1)
      %{succeeded: succeeded, failed: failed} = Sync.apply_changes(safe, [:price])

      if succeeded != [] do
        Activity.log("shop.shopify_sync_bulk_price_apply",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          metadata: %{"count" => length(succeeded)}
        )
      end

      socket = assign(socket, :diff, failed ++ rest)

      socket =
        if succeeded != [] do
          put_flash(
            socket,
            :info,
            gettext("Updated %{count} product price(s).", count: length(succeeded))
          )
        else
          socket
        end

      socket =
        if failed != [] do
          put_flash(
            socket,
            :error,
            gettext(
              "Could not update %{count} product price(s) — try again or apply individually.",
              count: length(failed)
            )
          )
        else
          socket
        end

      {:noreply, socket}
    end)
  end

  def handle_event("apply_one", %{"uuid" => product_uuid}, socket) do
    Authz.authorize(socket, :run_imports, fn ->
      diff = socket.assigns.diff || []

      case Enum.find(diff, &(&1.product_uuid == product_uuid)) do
        nil -> {:noreply, socket}
        change -> apply_one_change(socket, diff, change)
      end
    end)
  end

  @impl true
  def handle_async(:check_diff, {:ok, {:ok, diff}}, socket) do
    {:noreply, assign(socket, checking: false, diff: diff)}
  end

  def handle_async(:check_diff, {:ok, {:error, reason}}, socket) do
    {:noreply, assign(socket, checking: false, diff: nil, error: format_error(reason))}
  end

  def handle_async(:check_diff, {:exit, reason}, socket) do
    {:noreply, assign(socket, checking: false, diff: nil, error: inspect(reason))}
  end

  defp apply_one_change(socket, diff, change) do
    case Sync.apply_change(change, :all) do
      {:ok, _product} ->
        Activity.log("shop.shopify_sync_apply",
          actor_uuid: Activity.actor_uuid(socket),
          actor_role: Activity.actor_role(socket),
          resource_type: "product",
          resource_uuid: change.product_uuid,
          metadata: %{"fields" => change.changes |> Map.keys() |> Enum.map(&to_string/1)}
        )

        {:noreply,
         socket
         |> assign(:diff, Enum.reject(diff, &(&1.product_uuid == change.product_uuid)))
         |> put_flash(:info, gettext("Updated: %{title}", title: change.title))}

      {:error, _changeset} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not update %{title}.", title: change.title))}
    end
  end

  defp shopify_connection do
    case Integrations.list_connections("shopify", owner: :system) do
      [connection | _rest] -> connection
      [] -> nil
    end
  end

  defp price_only_safe?(%{changes: changes, price_extreme?: extreme}) do
    not extreme and map_size(changes) == 1 and Map.has_key?(changes, :price)
  end

  defp field_label(field), do: Map.get(@field_labels, field, Atom.to_string(field))

  defp format_value(field, value) when field in [:body_html], do: value

  defp format_value(:tags, value) when is_list(value), do: Enum.join(value, ", ")
  defp format_value(:price, %Decimal{} = value), do: Decimal.to_string(value)
  defp format_value(_field, value), do: to_string(value)

  defp confirm_summary(change) do
    change.changes
    |> Enum.map_join("; ", fn {field, %{incoming: incoming}} ->
      "#{field_label(field)} → #{format_value(field, incoming)}"
    end)
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

  @impl true
  def render(assigns) do
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

        <div :if={@diff == []} class="alert alert-success">
          {gettext("No changes — the shop matches Shopify.")}
        </div>

        <div :if={@diff not in [nil, []]} class="space-y-8">
          <div :if={Enum.any?(@diff, &price_only_safe?/1)}>
            <div class="flex items-center justify-between mb-2">
              <h2 class="text-lg font-semibold">{gettext("Price-only updates")}</h2>
              <button class="btn btn-sm btn-primary" phx-click="apply_safe_prices">
                {gettext("Apply all price-only updates")}
              </button>
            </div>
            <div class="overflow-x-auto">
              <table class="table table-zebra" id="safe-price-changes">
                <thead>
                  <tr>
                    <th>{gettext("Product")}</th>
                    <th>{gettext("Current price")}</th>
                    <th>{gettext("Shopify price")}</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={c <- @diff} :if={price_only_safe?(c)} id={"safe-change-#{c.product_uuid}"}>
                    <td>{c.title}</td>
                    <td>{format_value(:price, c.changes.price.current)}</td>
                    <td>{format_value(:price, c.changes.price.incoming)}</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>

          <div :if={Enum.any?(@diff, &(not price_only_safe?(&1)))}>
            <h2 class="text-lg font-semibold mb-2">
              {gettext("Needs review")}
            </h2>
            <div class="space-y-3">
              <div
                :for={c <- @diff}
                :if={not price_only_safe?(c)}
                id={"review-change-#{c.product_uuid}"}
                class={["card bg-base-100 shadow-xl", c.price_extreme? && "border border-warning"]}
              >
                <div class="card-body p-4">
                  <div class="flex items-center justify-between gap-4">
                    <h3 class="font-semibold">{c.title}</h3>
                    <button
                      class="btn btn-xs btn-warning"
                      phx-click="apply_one"
                      phx-value-uuid={c.product_uuid}
                      data-confirm={
                        gettext("Update \"%{title}\": %{summary}?",
                          title: c.title,
                          summary: confirm_summary(c)
                        )
                      }
                    >
                      {gettext("Apply")}
                    </button>
                  </div>
                  <ul class="text-sm mt-2 space-y-1">
                    <li :for={{field, %{current: current, incoming: incoming}} <- c.changes}>
                      <span class="font-medium">{field_label(field)}:</span>
                      {format_value(field, current)} → {format_value(field, incoming)}
                      <span :if={field == :price && c.price_extreme?} class="badge badge-warning badge-sm ml-1">
                        {gettext("large change")}
                      </span>
                    </li>
                  </ul>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
