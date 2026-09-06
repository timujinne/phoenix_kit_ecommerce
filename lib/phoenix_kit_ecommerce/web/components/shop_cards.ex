defmodule PhoenixKitEcommerce.Web.Components.ShopCards do
  @moduledoc """
  Reusable product display components for the shop storefront.

  Provides product card and pagination components shared between
  the main catalog page and category pages.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Vocabulary
  alias PhoenixKitEcommerce.Web.Components.FilterHelpers
  alias PhoenixKitEcommerce.Web.Helpers

  @doc """
  Renders a product card with image, title, price, and optional category badge.
  """
  attr :product, :map, required: true
  attr :currency, :any, required: true
  attr :language, :string, default: "en"
  attr :filter_qs, :string, default: ""
  attr :show_category, :boolean, default: false

  def product_card(assigns) do
    assigns =
      assigns
      |> assign(:product_title, Translations.get(assigns.product, :title, assigns.language))
      |> assign(:product_url, Shop.product_url(assigns.product, assigns.language))
      |> assign(:product_image_url, Helpers.first_image(assigns.product))
      |> assign(
        :category_name,
        if(assigns.show_category && assigns.product.category,
          do: Translations.get(assigns.product.category, :name, assigns.language),
          else: nil
        )
      )

    ~H"""
    <.link
      navigate={@product_url <> @filter_qs}
      class="card bg-base-100 shadow-md hover:shadow-xl transition-all hover:-translate-y-1"
    >
      <figure class="h-48 bg-base-200">
        <%= if @product_image_url do %>
          <img
            src={@product_image_url}
            alt={@product_title}
            class="w-full h-full object-cover"
          />
        <% else %>
          <div class="w-full h-full flex items-center justify-center">
            <.icon name="hero-cube" class="w-16 h-16 opacity-30" />
          </div>
        <% end %>
      </figure>
      <div class="card-body p-4">
        <h3 class="card-title text-base line-clamp-2">{@product_title}</h3>

        <div class="flex items-center gap-2">
          <span class="text-lg font-bold text-primary">
            {PriceDisplay.render(@product, @currency, :catalog, language: @language)}
          </span>
          <%= if cmp = PriceDisplay.compare_at(@product, @currency, :catalog, []) do %>
            <span class="text-sm text-base-content/40 line-through">
              {cmp.price}
            </span>
          <% end %>
        </div>

        <%= if @category_name do %>
          <div class="mt-2">
            <span class="badge badge-ghost badge-sm">{@category_name}</span>
          </div>
        <% end %>
      </div>
    </.link>
    """
  end

  @doc """
  Renders a "load more" button + page links for product grids.
  """
  attr :page, :integer, required: true
  attr :total_pages, :integer, required: true
  attr :total_products, :integer, required: true
  attr :per_page, :integer, required: true
  attr :base_path, :string, required: true
  attr :active_filters, :map, default: %{}
  attr :enabled_filters, :list, default: []

  def shop_pagination(assigns) do
    remaining = assigns.total_products - assigns.page * assigns.per_page

    assigns =
      assigns
      |> assign(:remaining, max(0, remaining))
      |> assign(:has_more, assigns.page < assigns.total_pages)

    ~H"""
    <%= if @total_pages > 1 do %>
      <div class="mt-8 space-y-4">
        <%!-- Load More Button --%>
        <%= if @has_more do %>
          <div class="flex justify-center">
            <button phx-click="load_more" class="btn btn-primary btn-lg gap-2">
              <.icon name="hero-arrow-down" class="w-5 h-5" /> {gettext("Show More")}
              <span class="badge badge-ghost">{@remaining}</span>
            </button>
          </div>
        <% end %>

        <%!-- Page Links for SEO and direct access --%>
        <nav class="flex flex-wrap justify-center gap-2 text-sm">
          <%= for p <- 1..@total_pages do %>
            <.link
              patch={
                FilterHelpers.build_filter_url(@base_path, @active_filters, @enabled_filters, page: p)
              }
              class={[
                "px-3 py-1 rounded transition-colors",
                if(p <= @page,
                  do: "bg-primary text-primary-content",
                  else: "bg-base-200 hover:bg-base-300 text-base-content/70"
                )
              ]}
            >
              {p}
            </.link>
          <% end %>
        </nav>

        <%!-- Status text --%>
        <p class="text-center text-sm text-base-content/50">
          <%!-- Through Vocabulary: a shop selling products should not read
                "items" here while every heading beside it says "Products". --%>
          {Vocabulary.showing_of(min(@page * @per_page, @total_products), @total_products)}
        </p>
      </div>
    <% end %>
    """
  end

  @doc """
  Compact "browse / cart" bar for storefront pages.

  The storefront used to ship its own top-level layout carrying a cart
  link, a language switcher and a home link. Rendering inside the HOST's
  layout is the right call — the shop should look like the site — but a
  host whose header has no cart link would leave a shopper with no way
  back to their cart. This is the replacement: in-content (so it composes
  with any host chrome rather than competing with it), server-rendered,
  and switchable off via `shop_show_cart_bar` by hosts that carry their
  own.
  """
  attr :language, :string, required: true
  attr :cart_count, :integer, default: 0
  attr :class, :string, default: ""

  def storefront_bar(assigns) do
    ~H"""
    <div :if={show_cart_bar?()} class={["flex items-center justify-between gap-4 mb-6", @class]}>
      <.link navigate={Shop.catalog_url(@language)} class="btn btn-ghost btn-sm gap-2">
        <.icon name="hero-building-storefront" class="w-4 h-4" />
        {gettext("Shop")}
      </.link>

      <.link navigate={Shop.cart_url(@language)} class="btn btn-outline btn-sm gap-2">
        <.icon name="hero-shopping-cart" class="w-4 h-4" />
        {gettext("Cart")}
        <span :if={@cart_count > 0} class="badge badge-primary badge-sm">{@cart_count}</span>
      </.link>
    </div>
    """
  end

  defp show_cart_bar? do
    PhoenixKit.Settings.get_setting_cached("shop_show_cart_bar", "true") == "true"
  rescue
    # Fail toward SHOWING it: a shopper with no way to their cart is worse
    # than a duplicate link.
    _ -> true
  end
end
