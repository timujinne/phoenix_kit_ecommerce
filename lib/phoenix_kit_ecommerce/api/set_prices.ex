defmodule PhoenixKitEcommerce.API.SetPrices do
  @moduledoc """
  `ecommerce.set_prices`: price, compare-at price and option prices of
  products by reference.

  Writes only the catalogue source (the gate answers `unsupported_source`
  otherwise), through the catalogue's batch update limited to the `data`
  sub-paths a row changes, so a concurrent writer of other fields is never
  overwritten. Option prices are `price_modifiers`; `price_fit_rule` is
  neither read nor written.

  The tool is dangerous when any price above zero moves by more
  than `api_confirm_price_change_pct` percent, or when an option price is
  added, changed or removed by more than that percent of the product's
  current price. A batch with more rows than
  `api_confirm_batch_over` is held by core's executor for every admin write
  tool, so it is not asked here. With `ctx.dry_run?` the handler returns
  `{:preview, preview, fingerprint}` and writes nothing; the preview says
  whether the real call would be held (`Batch.with_confirmation/3`).
  """

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}

  import PhoenixKitEcommerce.API.PlanSupport, only: [ecommerce: 1]

  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.API.{Batch, Gate, PricePlan, Rows}
  alias PhoenixKitEcommerce.API.Settings, as: ApiSettings

  @tool "ecommerce.set_prices"
  @changed_message "A price changed while the call was being checked. Read the prices again and repeat the call."

  @doc "Handler of the tool."
  @spec run(map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | Gate.refusal()
  def run(input, ctx) do
    with {:ok, rows, planner} <- plan_rows(input) do
      if Map.get(ctx, :dry_run?, false), do: preview(rows), else: write(rows, ctx, planner)
    end
  end

  defp preview(rows) do
    preview =
      rows
      |> Batch.preview(%{"largest_price_change_pct" => largest_pct(rows)})
      |> Batch.with_confirmation(rows, %{"max_price_change_pct" => ApiSettings.price_change_pct()})

    {:preview, preview, Batch.fingerprint(rows)}
  end

  defp write(rows, ctx, planner) do
    with :ok <- Batch.ensure_not_newly_dangerous(rows, ctx, @changed_message) do
      {:ok, rows |> Batch.write_if_unchanged(ctx, @tool, planner) |> Batch.render()}
    end
  end

  @doc "The `danger` check of the tool: `true` when the call needs a confirmation."
  @spec dangerous?(map(), map()) :: boolean()
  def dangerous?(input, _ctx) do
    case plan_rows(input) do
      {:ok, rows, _planner} -> Batch.dangerous?(rows)
      {:error, _code, _detail, _context} -> false
    end
  end

  defp plan_rows(input) do
    with {:ok, catalogue_uuid} <- Gate.check(input) do
      pct = ApiSettings.price_change_pct()
      shopify? = PhoenixKitEcommerce.shopify_enabled?()
      loaded = Batch.load(input["items"], catalogue_uuid)
      sets_by_item = sets_by_item(loaded)

      planner = &plan_row(&1, pct, shopify?, sets_by_item)

      {:ok, Batch.plan(loaded, planner), planner}
    end
  end

  defp plan_row(%{item: item, input: input}, pct, shopify?, sets_by_item) do
    case PricePlan.plan(input, item,
           pct: pct,
           sets: sets(item, input, sets_by_item),
           shopify_enabled?: shopify?
         ) do
      {:ok, %{changed?: true} = plan} -> require_currency(plan, item)
      {:ok, plan} -> {:ok, plan}
      {:error, errors} -> {:error, Rows.invalid(errors)}
    end
  end

  # An amount stored with no currency is read as whatever the base currency
  # later becomes (the rule the Shopify sync keeps): a row that writes a price
  # is refused while neither the item nor the shop names one.
  defp require_currency(plan, item) do
    if is_binary(ecommerce(item)["currency"]) or base_currency?() do
      {:ok, plan}
    else
      {:error,
       Rows.invalid([
         %{
           path: "",
           message:
             "the shop has no base currency and the product has none: set one before pricing"
         }
       ])}
    end
  end

  defp base_currency? do
    match?(%{code: code} when is_binary(code), PhoenixKitEcommerce.get_base_currency())
  end

  # The attribute sets of every product that has option prices in this call,
  # read in one batched pass (`%{item_uuid => %{sets: [...]}}`; a product with
  # no sets is simply absent). One lookup per row would cost several queries
  # for each of up to 500 rows, three times for a confirmed call.
  defp sets_by_item(rows) do
    uuids =
      for %{item: %{uuid: uuid}, input: %{"price_modifiers" => modifiers}} <- rows,
          is_map(modifiers),
          uniq: true,
          do: uuid

    case uuids do
      [] -> %{}
      uuids -> AttributeSets.resolve_for_items(uuids)
    end
  end

  # The item's attribute sets, to refuse an option or a value that does not
  # exist: a modifier for an unknown name is ignored by the storefront, so
  # the price would silently stay at the base price.
  defp sets(item, %{"price_modifiers" => modifiers}, sets_by_item) when is_map(modifiers) do
    case Map.get(sets_by_item, item.uuid) do
      %{sets: sets} when is_list(sets) -> sets
      _none -> []
    end
  end

  defp sets(_item, _input, _sets_by_item), do: nil

  defp largest_pct(rows) do
    rows
    |> Enum.flat_map(fn
      %{plan: %{from: from, to: to}} -> [PricePlan.change_pct(from.price, to.price)]
      _ -> []
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.max_by(&abs(elem(Float.parse(&1), 0)), &>=/2, fn -> nil end)
  end
end
