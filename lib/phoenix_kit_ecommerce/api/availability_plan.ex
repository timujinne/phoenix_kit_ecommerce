defmodule PhoenixKitEcommerce.API.AvailabilityPlan do
  @moduledoc """
  Plans one row of `ecommerce.set_availability`: the two independent fields
  the tool takes, mapped onto the catalogue item's `data["ecommerce"]`:

    * `"visibility"` (`draft`, `active`, `archived`) is `shop_status`;
    * `"made_to_order"` (boolean) is `made_to_order`.

  The visibility an item currently has is read with the storefront's own rule
  (`View.merchant_status/1`: an item with no `shop_status` counts as
  `active`), never with a second copy of it. Publishing (`active`) an item
  that has no price is refused: the controlled step is the one that makes a
  product buyable, and a product with no price and no "price on request" mark
  is not ready to be.
  """

  import PhoenixKitEcommerce.API.PlanSupport,
    only: [ecommerce: 1, error: 3, put_if: 4, shopify_sync_may_overwrite?: 2]

  alias PhoenixKitEcommerce.API.PricePlan
  alias PhoenixKitEcommerce.Catalogue.ItemCommerce
  alias PhoenixKitEcommerce.ProductSource.Catalogue.View

  @visibilities ~w(draft active archived)
  @status_path ["ecommerce", "shop_status"]
  @made_to_order_path ["ecommerce", "made_to_order"]

  @type values :: %{
          visibility: String.t(),
          made_to_order: boolean(),
          item_status: String.t() | nil
        }

  @doc "The visibility values the API accepts."
  @spec visibilities() :: [String.t()]
  def visibilities, do: @visibilities

  @doc "What `ecommerce.get_prices` and this tool read from an item."
  @spec current(map()) :: values()
  def current(item) do
    ecommerce = ecommerce(item)

    %{
      visibility: View.merchant_status(ecommerce),
      made_to_order: Map.get(ecommerce, "made_to_order", false) == true,
      item_status: item.status
    }
  end

  @doc """
  Plans `row` (string keys) against `item`. With `shopify_enabled?: true` a
  visibility change to a product linked to Shopify carries the
  `shopify_sync_may_overwrite` warning: the sync writes the shop status too.
  """
  @spec plan(map(), map(), keyword()) :: {:ok, map()} | {:error, [map()]}
  def plan(row, item, opts \\ []) when is_map(row) do
    cur = current(item)

    case validate(row, item, cur) do
      [] -> row |> build(item, cur, opts) |> validate_write()
      errors -> {:error, errors}
    end
  end

  defp validate(row, item, cur) do
    visibility = Map.get(row, "visibility")
    made_to_order = Map.get(row, "made_to_order")

    List.flatten([
      nothing_to_change(row),
      visibility_error(row, visibility),
      made_to_order_error(row, made_to_order),
      publish_error(visibility, item, cur)
    ])
  end

  defp nothing_to_change(row) do
    if Map.has_key?(row, "visibility") or Map.has_key?(row, "made_to_order"),
      do: [],
      else: [error("", "nothing to change: give visibility or made_to_order", nil)]
  end

  defp visibility_error(row, visibility) do
    if Map.has_key?(row, "visibility") and visibility not in @visibilities,
      do: [error("visibility", "must be one of draft, active, archived", @visibilities)],
      else: []
  end

  defp made_to_order_error(row, value) do
    if Map.has_key?(row, "made_to_order") and not is_boolean(value),
      do: [error("made_to_order", "must be true or false", nil)],
      else: []
  end

  defp publish_error("active", item, cur) do
    if cur.visibility != "active" and unpriced?(item) and not price_on_request?(item),
      do: [
        error(
          "visibility",
          "set a price first (ecommerce.set_prices), or mark the product price on request",
          nil
        )
      ],
      else: []
  end

  defp publish_error(_visibility, _item, _cur), do: []

  defp build(row, item, cur, opts) do
    to = %{
      visibility: Map.get(row, "visibility", cur.visibility),
      made_to_order: Map.get(row, "made_to_order", cur.made_to_order),
      item_status: cur.item_status
    }

    changes =
      %{}
      |> put_change("visibility", cur.visibility, to.visibility)
      |> put_change("made_to_order", cur.made_to_order, to.made_to_order)

    %{
      from: cur,
      to: to,
      changes: changes,
      changed?: changes != %{},
      dangerous?: false,
      warnings: warnings(item, changes, Keyword.get(opts, :shopify_enabled?, false)),
      attrs: attrs(changes, to),
      owned_paths: paths(changes)
    }
  end

  defp put_change(changes, name, from, to) do
    if from == to, do: changes, else: Map.put(changes, name, %{"from" => from, "to" => to})
  end

  defp attrs(changes, _to) when changes == %{}, do: %{}

  defp attrs(changes, to) do
    ecommerce =
      %{}
      |> put_if(Map.has_key?(changes, "visibility"), "shop_status", to.visibility)
      |> put_if(Map.has_key?(changes, "made_to_order"), "made_to_order", to.made_to_order)

    %{data: %{"ecommerce" => ecommerce}}
  end

  defp paths(changes) do
    [{"visibility", @status_path}, {"made_to_order", @made_to_order_path}]
    |> Enum.filter(fn {name, _path} -> Map.has_key?(changes, name) end)
    |> Enum.map(&elem(&1, 1))
  end

  # The catalogue's own status wins on the storefront: an item that is not
  # `active` in the catalogue stays hidden whatever the shop status says.
  defp warnings(item, changes, shopify_enabled?) do
    []
    |> maybe_warn(item.status != "active", "item_not_active")
    |> maybe_warn(
      Map.has_key?(changes, "visibility") and shopify_sync_may_overwrite?(item, shopify_enabled?),
      "shopify_sync_may_overwrite"
    )
  end

  defp maybe_warn(list, true, code), do: list ++ [code]
  defp maybe_warn(list, false, _code), do: list

  # A stored price that is not a finite number (NaN, Infinity) is no price.
  defp unpriced?(item), do: is_nil(PricePlan.current(item).price)

  defp price_on_request?(item), do: Map.get(ecommerce(item), "price_on_request", false) == true

  # The fields a planned row writes go through `ItemCommerce`, so a value the
  # namespace would refuse is a row error before anything is stored.
  @doc false
  @spec validate_write(map()) :: {:ok, map()} | {:error, [map()]}
  def validate_write(%{changed?: false} = plan), do: {:ok, plan}

  def validate_write(plan) do
    ecommerce = get_in(plan.attrs, [:data, "ecommerce"])

    case ItemCommerce.cast(ecommerce, nil) do
      {:ok, _namespace} ->
        {:ok, plan}

      {:error, errors} ->
        {:error,
         Enum.map(errors, fn {field, message} -> error(to_string(field), message, nil) end)}
    end
  end
end
