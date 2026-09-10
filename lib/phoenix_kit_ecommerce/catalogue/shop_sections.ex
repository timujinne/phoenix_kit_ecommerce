defmodule PhoenixKitEcommerce.Catalogue.ShopSections do
  @moduledoc """
  Function components rendering the "Shop" section that
  `PhoenixKitEcommerce.Catalogue.Extension` adds to the catalogue item and
  category forms. Field names/labels are ported from
  `PhoenixKitEcommerce.Web.ProductForm`'s Pricing card and
  `PhoenixKitEcommerce.Web.CategoryForm`'s basic-fields card, adapted to the
  `item[ecommerce][...]` / `category[ecommerce][...]` namespace the
  extension slot absorbs (see `PhoenixKitCatalogue.Extensions.absorb/3`).

  Fields only the Shopify sync or a data migration ever write
  (`shopify`, `price_modifiers`, `legacy_product_uuid`,
  `translation_fingerprints`, `storefront_filters`) have no form input here.
  """

  use Phoenix.Component
  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import PhoenixKitWeb.Components.Core.Checkbox
  import PhoenixKitWeb.Components.Core.Icon, only: [icon: 1]
  import PhoenixKitWeb.Components.Core.Input
  import PhoenixKitWeb.Components.Core.Select

  alias PhoenixKit.Modules.Storage.URLSigner
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query

  attr :form, :any, default: nil
  attr :item, :any, default: nil
  attr :data, :map, default: %{}
  attr :current_language, :string, default: nil

  @doc """
  Shop section for the item form. `assigns` carries `:form`, `:item`,
  `:data` (the item's `data`, so `data["ecommerce"]` is the current
  commerce map) and `:current_language`.
  """
  def item(assigns) do
    ecommerce = Map.get(assigns[:data] || %{}, "ecommerce", %{})
    current_language = assigns[:current_language] || "en"
    price_unit = Map.get(ecommerce, "price_unit", %{})
    other_price_units = Enum.reject(price_unit, fn {lang, _} -> lang == current_language end)
    form = assigns[:form]

    assigns =
      assigns
      |> assign(:ecommerce, ecommerce)
      |> assign(:current_language, current_language)
      |> assign(:price_unit, price_unit)
      |> assign(:other_price_units, other_price_units)
      |> assign(:shop_status_errors, field_errors(form, :shop_status))
      |> assign(:product_type_errors, field_errors(form, :product_type))
      |> assign(:vendor_errors, field_errors(form, :vendor))
      |> assign(:tags_errors, field_errors(form, :tags))
      |> assign(:compare_at_price_errors, field_errors(form, :compare_at_price))
      |> assign(:cost_per_item_errors, field_errors(form, :cost_per_item))
      |> assign(:currency_errors, field_errors(form, :currency))
      |> assign(:weight_grams_errors, field_errors(form, :weight_grams))
      |> assign(:taxable_errors, field_errors(form, :taxable))
      |> assign(:requires_shipping_errors, field_errors(form, :requires_shipping))
      |> assign(:made_to_order_errors, field_errors(form, :made_to_order))
      |> assign(:price_from_errors, field_errors(form, :price_from))
      |> assign(:price_on_request_errors, field_errors(form, :price_on_request))
      |> assign(:file_uuid_errors, field_errors(form, :file_uuid))
      |> assign(:download_limit_errors, field_errors(form, :download_limit))
      |> assign(:download_expiry_days_errors, field_errors(form, :download_expiry_days))

    ~H"""
    <div id="ext-ecommerce-section" class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-xl mb-4">{gettext("Shop")}</h2>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-x-4 gap-y-4">
          <div class="fieldset w-full">
            <.select
              name="item[ecommerce][shop_status]"
              value={Map.get(@ecommerce, "shop_status", "draft")}
              label={gettext("Shop status")}
              errors={@shop_status_errors}
              options={[
                {gettext("Draft"), "draft"},
                {gettext("Active"), "active"},
                {gettext("Archived"), "archived"}
              ]}
            />
          </div>

          <div class="fieldset w-full">
            <.select
              name="item[ecommerce][product_type]"
              value={Map.get(@ecommerce, "product_type", "physical")}
              label={gettext("Product Type")}
              errors={@product_type_errors}
              options={[{gettext("Physical"), "physical"}, {gettext("Digital"), "digital"}]}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][vendor]"
              value={Map.get(@ecommerce, "vendor")}
              type="text"
              label={gettext("Vendor")}
              placeholder={gettext("Brand or manufacturer")}
              errors={@vendor_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][tags]"
              value={Enum.join(Map.get(@ecommerce, "tags", []), ", ")}
              type="text"
              label={gettext("Tags")}
              placeholder={gettext("comma, separated, tags")}
              errors={@tags_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][compare_at_price]"
              value={Map.get(@ecommerce, "compare_at_price")}
              type="number"
              step="0.01"
              min="0"
              label={gettext("Compare at Price")}
              placeholder={gettext("Original price")}
              errors={@compare_at_price_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][cost_per_item]"
              value={Map.get(@ecommerce, "cost_per_item")}
              type="number"
              step="0.01"
              min="0"
              label={gettext("Cost per Item")}
              errors={@cost_per_item_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][currency]"
              value={currency_input_value(@ecommerce)}
              type="text"
              maxlength="3"
              label={gettext("Currency")}
              errors={@currency_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][weight_grams]"
              value={Map.get(@ecommerce, "weight_grams", 0)}
              type="number"
              min="0"
              label={gettext("Weight (grams)")}
              errors={@weight_grams_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][taxable]"
              checked={Map.get(@ecommerce, "taxable", true)}
              label={gettext("Charge tax on this item")}
              errors={@taxable_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][requires_shipping]"
              checked={Map.get(@ecommerce, "requires_shipping", true)}
              label={gettext("Requires shipping")}
              errors={@requires_shipping_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][made_to_order]"
              checked={Map.get(@ecommerce, "made_to_order", false)}
              label={gettext("Made to order (always available)")}
              errors={@made_to_order_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][price_from]"
              checked={Map.get(@ecommerce, "price_from", false)}
              label={gettext("Show \"From\" before the price")}
              errors={@price_from_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.checkbox
              name="item[ecommerce][price_on_request]"
              checked={Map.get(@ecommerce, "price_on_request", false)}
              label={gettext("Price on request (hide the amount)")}
              errors={@price_on_request_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name={"item[ecommerce][price_unit][#{@current_language}]"}
              value={Map.get(@price_unit, @current_language, "")}
              type="text"
              maxlength="32"
              label={gettext("Price unit")}
              placeholder={gettext("e.g. per hour, per m², per litre")}
            />
            <%!-- Other languages' units must survive a save made while a
                 different tab is active. --%>
            <input
              :for={{lang, text} <- @other_price_units}
              type="hidden"
              name={"item[ecommerce][price_unit][#{lang}]"}
              value={text}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][file_uuid]"
              value={Map.get(@ecommerce, "file_uuid")}
              type="text"
              label={gettext("Digital file (Storage uuid)")}
              errors={@file_uuid_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][download_limit]"
              value={Map.get(@ecommerce, "download_limit")}
              type="number"
              min="1"
              label={gettext("Download limit")}
              errors={@download_limit_errors}
            />
          </div>

          <div class="fieldset w-full">
            <.input
              name="item[ecommerce][download_expiry_days]"
              value={Map.get(@ecommerce, "download_expiry_days")}
              type="number"
              min="1"
              label={gettext("Download expiry (days)")}
              errors={@download_expiry_days_errors}
            />
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :form, :any, default: nil
  attr :category, :any, default: nil
  attr :data, :map, default: %{}
  attr :current_language, :string, default: nil

  @doc """
  Shop section for the category form. `assigns` carries `:form`,
  `:category`, `:data` (the category's `data`) and `:current_language`.
  """
  def category(assigns) do
    ecommerce = Map.get(assigns[:data] || %{}, "ecommerce", %{})
    form = assigns[:form]

    # Cached per category for the life of the LiveView process: this is a
    # function component inside a form whose `phx-change="validate"` fires
    # on every keystroke, so querying here meant a database round trip per
    # character typed into any field on the page. The candidate list only
    # changes when the category's items do, which a form edit never does.
    item_options = cached_item_options(assigns[:category])

    assigns =
      assigns
      |> assign(:ecommerce, ecommerce)
      |> assign(:item_options, item_options)
      |> assign(:selected_option, selected_option(item_options, ecommerce))
      |> assign(:shop_status_errors, field_errors(form, :shop_status))
      |> assign(:featured_item_uuid_errors, field_errors(form, :featured_item_uuid))

    ~H"""
    <div id="ext-ecommerce-section" class="card bg-base-100 shadow-xl">
      <div class="card-body">
        <h2 class="card-title text-xl mb-4">{gettext("Shop")}</h2>

        <div class="grid grid-cols-1 md:grid-cols-2 gap-x-4 gap-y-4">
          <div class="fieldset w-full">
            <.select
              name="category[ecommerce][shop_status]"
              value={Map.get(@ecommerce, "shop_status", "active")}
              label={gettext("Shop status")}
              errors={@shop_status_errors}
              options={[
                {gettext("Active — Category and items visible"), "active"},
                {gettext("Unlisted — Category hidden, items still visible"), "unlisted"},
                {gettext("Hidden — Category and items hidden"), "hidden"}
              ]}
            />
          </div>


          <div class="fieldset w-full md:col-span-2">
            <%= if @item_options != [] do %>
              <label class="label">
                <span class="fieldset-legend font-medium">
                  {gettext("Featured item (image fallback)")}
                </span>
              </label>

              <%!-- A dropdown, not a grid: the list can be long, and it is
                    one field among many on this form. Each row leads with
                    the picture the item would give the category, because
                    that is what the choice is about — a name says nothing
                    about the photo. Native `<option>` cannot hold an
                    image, so this is a details-dropdown over radios: no
                    JavaScript, and the radio carries the value. --%>
              <details class="dropdown w-full">
                <summary class="btn btn-outline w-full justify-start gap-2 font-normal">
                  <%= if @selected_option do %>
                    <img
                      src={URLSigner.signed_url(@selected_option.image_uuid, "small")}
                      alt=""
                      class="h-8 w-8 rounded object-cover"
                    />
                    <span class="truncate">{@selected_option.name}</span>
                  <% else %>
                    <.icon name="hero-sparkles" class="w-4 h-4" />
                    <span class="truncate">
                      {gettext("Auto-detect (first item with an image)")}
                    </span>
                  <% end %>
                  <.icon name="hero-chevron-down" class="w-4 h-4 ml-auto" />
                </summary>

                <ul class="dropdown-content menu z-10 mt-1 max-h-72 w-full flex-nowrap overflow-y-auto rounded-box bg-base-100 p-1 shadow">
                  <li>
                    <label class="flex items-center gap-2">
                      <input
                        type="radio"
                        name="category[ecommerce][featured_item_uuid]"
                        value=""
                        checked={@selected_option == nil}
                        class="radio radio-xs"
                      />
                      <.icon name="hero-sparkles" class="w-4 h-4" />
                      <span class="truncate">
                        {gettext("Auto-detect (first item with an image)")}
                      </span>
                    </label>
                  </li>

                  <li :for={option <- @item_options}>
                    <label class="flex items-center gap-2">
                      <input
                        type="radio"
                        name="category[ecommerce][featured_item_uuid]"
                        value={option.uuid}
                        checked={@selected_option && @selected_option.uuid == option.uuid}
                        class="radio radio-xs"
                      />
                      <img
                        src={URLSigner.signed_url(option.image_uuid, "small")}
                        alt=""
                        class="h-8 w-8 rounded object-cover"
                      />
                      <span class="truncate">{option.name}</span>
                    </label>
                  </li>
                </ul>
              </details>

              <p :if={@featured_item_uuid_errors != []} class="text-error text-xs mt-1">
                {Enum.join(@featured_item_uuid_errors, ", ")}
              </p>
            <% else %>
              <label class="label">
                <span class="fieldset-legend font-medium">{gettext("Featured item (image fallback)")}</span>
              </label>
              <div class="text-sm text-base-content/50 py-2">
                <.icon name="hero-information-circle" class="w-4 h-4 inline mr-1" />
                {gettext(
                  "No items with images in this category. Add item images to enable this option."
                )}
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # A `:new` category (not yet saved) is a bare struct with `uuid: nil` —
  # no items can be attached to it yet, so the picker has nothing to
  # list.
  defp category_uuid(%{uuid: uuid}) when is_binary(uuid), do: uuid
  defp category_uuid(_), do: nil

  defp selected_option(item_options, ecommerce) do
    case Map.get(ecommerce, "featured_item_uuid") do
      uuid when is_binary(uuid) and uuid != "" ->
        Enum.find(item_options, &(&1.uuid == uuid))

      _ ->
        nil
    end
  end

  # Keyed by category uuid in the process dictionary: a function component
  # has no assigns of its own to memoise into, and this runs inside the
  # LiveView process, which is per-connection and dies with the page.
  defp cached_item_options(category) do
    uuid = category_uuid(category)
    key = {__MODULE__, :item_options, uuid}

    case Process.get(key) do
      nil ->
        options = Query.category_item_image_options(uuid)
        Process.put(key, options)
        options

      cached ->
        cached
    end
  end

  # Reads errors `Ecto.Changeset.add_error/4`-tagged with
  # `extension: "ecommerce", field: field` off the `:data` field's errors
  # on a `to_form/2`-built form, so a `cast_item/2`/`cast_category/2`
  # failure is visible on Save instead of a silent no-op (see
  # `PhoenixKitCatalogue.Extensions.absorb/3`).
  defp field_errors(%{errors: errors}, field) when is_list(errors) do
    for {:data, {msg, opts}} <- errors,
        Keyword.get(opts, :extension) == "ecommerce",
        Keyword.get(opts, :field) == field do
      msg
    end
  end

  defp field_errors(_form, _field), do: []

  # Prefill from the stored value, else the shop's base currency, else
  # blank. Never `"USD"`: an unconfigured shop must not silently stamp
  # dollars onto a new item (PR #31).
  defp currency_input_value(ecommerce) do
    case Map.get(ecommerce || %{}, "currency") do
      code when is_binary(code) and code != "" -> code
      _ -> default_currency_code()
    end
  end

  defp default_currency_code do
    case PhoenixKitEcommerce.get_base_currency() do
      %{code: code} when is_binary(code) -> code
      _ -> ""
    end
  rescue
    _ -> ""
  catch
    :exit, _ -> ""
  end
end
