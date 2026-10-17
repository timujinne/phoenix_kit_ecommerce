defmodule PhoenixKitEcommerce.API do
  @moduledoc """
  The e-commerce tools of the admin API: what
  `PhoenixKitEcommerce.api_tools/0` hands to core, and the handlers core
  calls as `apply(PhoenixKitEcommerce.API, fun, [input, ctx])`.

  | Tool | Scope | Permission |
  |---|---|---|
  | `ecommerce.get_prices` | `ecommerce.prices:read` | `shop` |
  | `ecommerce.set_prices` | `ecommerce.prices:write` | `shop.manage_catalog` |
  | `ecommerce.set_availability` | `ecommerce.availability:write` | `shop.manage_catalog` |
  | `ecommerce.attach_images` | `ecommerce.images:write` | `shop.manage_catalog` |
  | `ecommerce.detach_images` | `ecommerce.images:write` | `shop.manage_catalog` |

  The four write tools are offered only when core can hold a dangerous call
  for confirmation: a core that cannot would run a 90 % price cut on the
  first call.

  Their registered handlers also require the key owner's live `catalogue`
  permission, including for a dry run, matching the admin catalogue editor.
  Core enforces the shop capability listed above.

  The tools write the catalogue source only; on the legacy source they answer
  `unsupported_source`. Shopify is optional: nothing here needs a product to
  be linked to it, and the descriptions mention the sync only while it is on.
  """

  alias PhoenixKit.API.Tool

  alias PhoenixKitEcommerce.API.{
    AttachImages,
    DetachImages,
    Gate,
    GetPrices,
    Schemas,
    SetAvailability,
    SetPrices
  }

  @compile {:no_warn_undefined, [PhoenixKit.API.Tool, PhoenixKit.API.Keys, PhoenixKit.API.Flow]}

  # Core holds a dangerous call for confirmation only when it has both the
  # confirmation codes and the enforcement; the catalogue's tools judge the
  # same two markers.
  @markers [{PhoenixKit.API.Keys, :active?, 1}, {PhoenixKit.API.Flow, :gate, 1}]

  @retry_note " A validation_failed error with context.reason database_error, storage_error or unexpected is not a problem with the request and is worth retrying; any other validation_failed should be fixed first."

  @doc """
  The tools for `PhoenixKitEcommerce.api_tools/0`; `[]` on a core without the
  tool registry. `markers` are the `{module, function, arity}` triples that
  must exist for the write tools to be offered; none at all means they are not.
  """
  @spec tools([{module(), atom(), arity()}]) :: [struct()]
  def tools(markers \\ @markers) do
    if Code.ensure_loaded?(Tool) do
      [get_prices_tool()] ++ if(confirmation_available?(markers), do: write_tools(), else: [])
    else
      []
    end
  end

  # Whether core enforces the confirmation gate the write tools depend on:
  # every `{module, function, arity}` of `markers` is loaded and exported. The
  # default is the pair of functions core has only when it has both the
  # confirmation codes and the enforcement. No markers to judge by is "no":
  # the write tools are offered only on positive evidence.
  @doc false
  @spec confirmation_available?([{module(), atom(), arity()}]) :: boolean()
  def confirmation_available?(markers \\ @markers)
  def confirmation_available?([]), do: false

  def confirmation_available?(markers) do
    Enum.all?(markers, fn {module, function, arity} ->
      Code.ensure_loaded?(module) and function_exported?(module, function, arity)
    end)
  end

  @doc false
  @spec markers() :: [{module(), atom(), arity()}]
  def markers, do: @markers

  defp write_tools,
    do: [set_prices_tool(), set_availability_tool(), attach_images_tool(), detach_images_tool()]

  # -- handlers ---------------------------------------------------------------

  @doc false
  defdelegate get_prices(input, ctx), to: GetPrices, as: :run
  @doc false
  def set_prices(input, ctx), do: authorized_write(input, ctx, &SetPrices.run/2)
  @doc false
  defdelegate set_prices_danger(input, ctx), to: SetPrices, as: :dangerous?
  @doc false
  def set_availability(input, ctx), do: authorized_write(input, ctx, &SetAvailability.run/2)
  @doc false
  def attach_images(input, ctx), do: authorized_write(input, ctx, &AttachImages.run/2)
  @doc false
  def detach_images(input, ctx), do: authorized_write(input, ctx, &DetachImages.run/2)
  @doc false
  defdelegate detach_images_danger(input, ctx), to: DetachImages, as: :dangerous?

  defp authorized_write(input, ctx, handler) do
    with :ok <- Gate.authorize_catalogue(ctx), do: handler.(input, ctx)
  end

  # -- definitions ------------------------------------------------------------

  defp get_prices_tool do
    Tool.new!(
      name: "ecommerce.get_prices",
      audience: :admin,
      scope: "ecommerce.prices:read",
      permission: "shop",
      title: "Get product prices",
      description:
        "Reads the price, the compare-at price, the option prices (price_modifiers), the visibility and the made-to-order flag of products, by id, sku or external_id. " <>
          "shop_status_visible says whether the product's own status and shop_status let the storefront show it; it does not look at the product's category (a product in a hidden category stays hidden). Prices are decimal strings in the product's currency." <>
          @retry_note,
      input_schema: Schemas.get_prices_input(),
      output_schema: Schemas.batch_output(),
      handler: {__MODULE__, :get_prices},
      annotations: %{read_only: true, idempotent: true},
      max_items: Schemas.max_rows()
    )
  end

  defp set_prices_tool do
    Tool.new!(
      name: "ecommerce.set_prices",
      audience: :admin,
      scope: "ecommerce.prices:write",
      permission: "shop.manage_catalog",
      title: "Set product prices",
      description:
        "Sets the price, the compare-at price and the option prices of products. Give only what changes. " <>
          "Option prices are price_modifiers: option => value => amount, merged into the product's own; null removes one. A new option price needs the entities module enabled and the option in a set attached to the product. " <>
          "A price move above the confirmation threshold is held for confirmation first; an option price is measured against the product's current price. A price set to zero is always held; any other first price is not. From a threshold of 100 percent on only increases are held, as a cut cannot exceed 100 percent. " <>
          "A dry run answers requires_confirmation (whether the real call would be held) and confirmation_rules (the thresholds that applied); it never creates a confirmation code." <>
          shopify_note() <> @retry_note,
      input_schema: Schemas.set_prices_input(),
      output_schema: Schemas.batch_output(),
      handler: {__MODULE__, :set_prices},
      annotations: %{destructive: true, idempotent: true},
      danger: {__MODULE__, :set_prices_danger},
      max_items: Schemas.max_rows()
    )
  end

  defp set_availability_tool do
    Tool.new!(
      name: "ecommerce.set_availability",
      audience: :admin,
      scope: "ecommerce.availability:write",
      permission: "shop.manage_catalog",
      title: "Set product availability",
      description:
        "Sets whether products are shown in the shop (visibility: draft, active, archived) and whether they are made to order. " <>
          "A product without a price cannot be made active. A product that is not active in the catalogue stays hidden whatever its visibility. " <>
          "A dry run answers requires_confirmation (whether the real call would be held: a batch over the confirmation threshold is) and confirmation_rules; it never creates a confirmation code." <>
          shopify_note() <> @retry_note,
      input_schema: Schemas.set_availability_input(),
      output_schema: Schemas.batch_output(),
      handler: {__MODULE__, :set_availability},
      annotations: %{idempotent: true},
      max_items: Schemas.max_rows()
    )
  end

  defp attach_images_tool do
    Tool.new!(
      [
        name: "ecommerce.attach_images",
        audience: :admin,
        scope: "ecommerce.images:write",
        permission: "shop.manage_catalog",
        title: "Attach product images",
        description:
          "Downloads pictures from public http(s) URLs (at most 10 MB each) and attaches them to products after the pictures they already have. " <>
            "At most 20 pictures per call. Addresses on private networks are always refused. Mark one picture featured to make it the main one. " <>
            "A dry run answers requires_confirmation (whether the real call would be held: a batch over the confirmation threshold is) and confirmation_rules; it never creates a confirmation code." <>
            shopify_note() <> @retry_note,
        input_schema: Schemas.attach_images_input(),
        output_schema: Schemas.batch_output(),
        handler: {__MODULE__, :attach_images},
        annotations: %{idempotent: true, open_world: true},
        max_items: AttachImages.max_images()
      ] ++ cost_option()
    )
  end

  defp detach_images_tool do
    Tool.new!(
      name: "ecommerce.detach_images",
      audience: :admin,
      scope: "ecommerce.images:write",
      permission: "shop.manage_catalog",
      title: "Detach product images",
      description:
        "Removes pictures from the galleries of products. Name each picture by its file id or by the URL it was attached from; only a picture the product's gallery has can be removed, another product's picture can not be reached this way, and a picture the product does not have is listed in not_attached and changes nothing, so repeating a call is safe. " <>
          "At most 50 pictures per product and 500 per call. A picture shared with another product stays with it; a picture nothing else holds is moved to the media trash, not deleted for good. Removing the main picture leaves the product without one, and the shop shows the first picture left. " <>
          "A call that would leave a product with no picture at all is held for confirmation first. A dry run answers requires_confirmation and confirmation_rules, and never creates a confirmation code." <>
          shopify_note() <> @retry_note,
      input_schema: Schemas.detach_images_input(),
      output_schema: Schemas.batch_output(),
      handler: {__MODULE__, :detach_images},
      annotations: %{destructive: true, idempotent: true},
      danger: {__MODULE__, :detach_images_danger},
      max_items: Schemas.max_rows()
    )
  end

  # A call that downloads is priced by the pictures it downloads, on a core
  # whose `Tool` has the `cost` field (`{Module, :function}` called
  # with the raw input). A core without the field is not told about it:
  # `Tool.new!/1` would refuse an unknown key.
  defp cost_option do
    if :cost in Map.keys(Tool.__struct__()),
      do: [cost: {AttachImages, :cost}],
      else: []
  end

  # A sentence only while the Shopify sync exists: on a shop without it the
  # tool must not talk about a feature the owner cannot see.
  defp shopify_note do
    if PhoenixKitEcommerce.shopify_enabled?(),
      do:
        " What is written to a product linked to Shopify can be overwritten by the next sync (the last write wins); the answer carries the warning shopify_sync_may_overwrite.",
      else: ""
  end
end
