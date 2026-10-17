defmodule PhoenixKitEcommerce.WarehouseSourceKind do
  @moduledoc """
  The warehouse source kind `"shop_order"`: a shop order (a billing order
  placed through the storefront checkout) as the basis of a warehouse
  document.

  `PhoenixKitEcommerce.warehouse_source_kinds/0` returns `kinds/0`, and the
  Warehouse module merges it with the kinds a host configured itself
  (`PhoenixKitWarehouse.SourceKinds.list_kinds/0`), so no host configuration
  changes. The three callbacks have the shapes `SourceKinds` documents:

    * `search/1` - candidates for a picker: `[%{uuid, label, extra}]`;
    * `resolve/1` - `%{label, path}` for an existing reference, or `:error`;
    * `build_lines/2` - the order's product lines for an internal order.

  An order counts as a shop order when it was placed by the storefront
  checkout (`metadata["source"] == "shop_checkout"`); an order a person typed
  into billing by hand is not offered. Labels show the order number and the
  status, never the customer: the warehouse screens are not the place for
  personal data, and nothing here reads the billing profile.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import Ecto.Query, only: [from: 2]

  alias PhoenixKit.RepoHelper
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling.Order
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.Web.StatusLabels

  @kind "shop_order"
  @source "shop_checkout"
  @search_limit 20

  @doc "The kind name stored in a document's `source_refs` (`\"type\"`)."
  @spec kind() :: String.t()
  def kind, do: @kind

  @doc """
  The kind declaration `SourceKinds` merges. A literal list built from this
  module's own functions: it runs for every rendered reference, so it must
  not query.
  """
  @spec kinds() :: [map()]
  def kinds do
    [
      %{
        kind: @kind,
        label: gettext("Shop order"),
        search: {__MODULE__, :search, []},
        resolve: {__MODULE__, :resolve, []},
        build_lines: {__MODULE__, :build_lines, []}
      }
    ]
  end

  @doc """
  Shop orders whose number contains `query`, newest first. Empty while the
  shop is off. Orders of every status are offered (the label shows the status);
  which ones make a sensible document is left to the person choosing.
  """
  @spec search(String.t()) :: [%{uuid: String.t(), label: String.t(), extra: map()}]
  def search(query) when is_binary(query) do
    if PhoenixKitEcommerce.enabled?() do
      pattern = ProductSource.search_like_pattern(query)

      RepoHelper.repo().all(
        from(o in Order,
          where: fragment("?->>'source'", o.metadata) == ^@source,
          where: ilike(o.order_number, ^pattern),
          order_by: [desc: o.inserted_at, desc: o.uuid],
          limit: ^@search_limit,
          select: struct(o, [:uuid, :order_number, :status, :total, :currency])
        )
      )
      |> Enum.map(&%{uuid: &1.uuid, label: label(&1), extra: %{status: &1.status}})
    else
      []
    end
  end

  @doc "`%{label, path}` of an existing shop order, or `:error`."
  @spec resolve(String.t()) :: %{label: String.t(), path: String.t()} | :error
  def resolve(uuid) when is_binary(uuid) do
    with %Ecto.Query{} = query <- shop_order_query(uuid),
         %Order{} = order <-
           RepoHelper.repo().one(
             from(o in query, select: struct(o, [:uuid, :order_number, :status]))
           ) do
      %{label: label(order), path: Routes.path("/admin/billing/orders/#{order.uuid}")}
    else
      _ -> :error
    end
  end

  @doc """
  The product lines of a shop order, as an internal order imports them:
  `item_uuid`, `name`, `sku`, `unit`, `catalogue_uuid`, `category_uuid` and
  `required_quantity`. A line without a catalogue item (a shipping line, a
  legacy product) is left out. One line per catalogue item: the lines of an
  item that differ only in their selected options are summed, because a
  document keeps one quantity per item. `:error` when the order does not exist.
  """
  @spec build_lines(String.t(), String.t()) :: {:ok, [map()]} | :error
  def build_lines(uuid, _actor_uuid) when is_binary(uuid) do
    with %Ecto.Query{} = query <- shop_order_query(uuid),
         %{line_items: line_items} <-
           RepoHelper.repo().one(from(o in query, select: %{line_items: o.line_items})) do
      pairs = line_items |> List.wrap() |> Enum.flat_map(&product_line/1)
      grouped = Enum.group_by(pairs, &elem(&1, 0), &elem(&1, 1))
      facts = grouped |> Map.keys() |> catalogue_facts()

      lines =
        pairs
        |> Enum.uniq_by(&elem(&1, 0))
        |> Enum.map(fn {item_uuid, first} ->
          line(item_uuid, first, grouped[item_uuid], facts)
        end)

      {:ok, lines}
    else
      _ -> :error
    end
  end

  # A table named by string carries no `@schema_prefix`: it is taken from the
  # same setting core's schemas take it from.
  @schema_prefix Application.compile_env(:phoenix_kit, :prefix)

  # `unit` and the catalogue of each item, in one query. Read by table name:
  # the catalogue is an optional dependency, so its schema module is not
  # referenced here, and nothing is queried when it is not loaded.
  defp catalogue_facts([]), do: %{}

  defp catalogue_facts(item_uuids) do
    if Code.ensure_loaded?(PhoenixKitCatalogue.Schemas.Item) do
      RepoHelper.repo().all(
        from(i in "phoenix_kit_cat_items",
          prefix: ^@schema_prefix,
          where: i.uuid in type(^item_uuids, {:array, Ecto.UUID}),
          select: {
            type(i.uuid, Ecto.UUID),
            i.unit,
            type(i.catalogue_uuid, Ecto.UUID),
            type(i.category_uuid, Ecto.UUID)
          }
        )
      )
      |> Map.new(fn {uuid, unit, catalogue_uuid, category_uuid} ->
        {uuid, %{unit: unit, catalogue_uuid: catalogue_uuid, category_uuid: category_uuid}}
      end)
    else
      %{}
    end
  end

  # The shop orders (placed by the storefront checkout) with the given id, as a
  # query to select from, or `nil` for something that is not a uuid. Callers
  # select only the columns they print.
  defp shop_order_query(uuid) do
    case Ecto.UUID.cast(uuid) do
      {:ok, uuid} ->
        from(o in Order,
          where: o.uuid == ^uuid,
          where: fragment("?->>'source'", o.metadata) == ^@source
        )

      :error ->
        nil
    end
  end

  # `[{item_uuid, line}]` for a product line that names a catalogue item (the
  # id in its canonical form, so it matches the catalogue lookup), else `[]`.
  defp product_line(%{"type" => "product", "catalogue_item_uuid" => item_uuid} = line)
       when is_binary(item_uuid) do
    case Ecto.UUID.cast(item_uuid) do
      {:ok, item_uuid} -> [{item_uuid, line}]
      :error -> []
    end
  end

  defp product_line(_line), do: []

  # One line per item: name and sku of its first line, quantities summed.
  defp line(item_uuid, first, rows, facts) do
    fact = Map.get(facts, item_uuid, %{})

    %{
      "item_uuid" => item_uuid,
      "name" => first["name"],
      "sku" => first["sku"],
      "unit" => fact[:unit],
      "catalogue_uuid" => fact[:catalogue_uuid],
      "category_uuid" => fact[:category_uuid],
      "required_quantity" => rows |> total_quantity() |> Decimal.to_string(:normal)
    }
  end

  defp total_quantity(rows) do
    rows
    |> Enum.map(&to_decimal(&1["quantity"]))
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp to_decimal(%Decimal{} = value), do: value
  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp to_decimal(value) when is_binary(value) do
    case Decimal.parse(value) do
      {decimal, ""} -> decimal
      _ -> Decimal.new(0)
    end
  end

  defp to_decimal(_value), do: Decimal.new(0)

  defp label(%Order{order_number: number, uuid: uuid, status: status}) do
    "#{number || String.slice(uuid, 0, 8)} (#{StatusLabels.order(status)})"
  end
end
