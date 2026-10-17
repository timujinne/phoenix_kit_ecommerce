defmodule PhoenixKitEcommerce.API.PricePlan do
  @moduledoc """
  Plans one row of `ecommerce.set_prices`: what the row would change, whether
  that change is dangerous, and the catalogue write that carries it out.
  Pure: it reads the item it is given and touches nothing.

  A row is the decoded JSON of one entry of `items` (string keys):

    * `"price"` - a decimal string, the item's `base_price`;
    * `"compare_at"` - a decimal string, or `null` to clear it;
    * `"price_modifiers"` - `option => value => amount`, where an amount is a
      decimal string (it may be negative) or `null` to remove that value's
      modifier. Options and values are merged into what the item already has.

  Leaves the row does not mention are never touched, and a stored leaf this
  module does not write is carried over as it is (a host migration may have
  stored numbers, and a rewrite would lose them).
  """

  import PhoenixKitEcommerce.API.PlanSupport,
    only: [ecommerce: 1, error: 2, error: 3, put_if: 4, shopify_sync_may_overwrite?: 2]

  alias PhoenixKitEcommerce.API.Money
  alias PhoenixKitEcommerce.Catalogue.ItemCommerce
  alias PhoenixKitEcommerce.Options.MetadataValidator

  @modifiers_path ["ecommerce", "price_modifiers"]
  @compare_at_path ["ecommerce", "compare_at_price"]

  @type values :: %{
          price: Decimal.t() | nil,
          compare_at: Decimal.t() | nil,
          price_modifiers: map()
        }

  @type error :: %{path: String.t(), message: String.t(), allowed: [String.t()] | nil}

  @type t :: %{
          from: values(),
          to: values(),
          changes: %{String.t() => %{String.t() => String.t() | nil}},
          changed?: boolean(),
          dangerous?: boolean(),
          warnings: [String.t()],
          attrs: map(),
          owned_paths: [[String.t()]],
          leaves: [{String.t(), String.t()}],
          guard: map()
        }

  @doc "The values of an item that `ecommerce.set_prices` can change."
  @spec current(map()) :: values()
  def current(item) do
    ecommerce = ecommerce(item)

    %{
      price: Money.to_decimal(item.base_price),
      compare_at: Money.to_decimal(ecommerce["compare_at_price"]),
      price_modifiers: modifiers(ecommerce["price_modifiers"])
    }
  end

  @doc """
  Plans `row` against `item`.

  Options: `:pct` (required, the confirmation threshold, a whole number),
  `:sets` (the item's resolved attribute sets, to check option and value
  names; `nil` skips that check) and `:shopify_enabled?` (adds the sync
  warning for an item linked to Shopify).
  """
  @spec plan(map(), map(), keyword()) :: {:ok, t()} | {:error, [error()]}
  def plan(row, item, opts) when is_map(row) do
    cur = current(item)

    parsed = [
      price: parse_price(row),
      compare_at: parse_compare_at(row),
      price_modifiers: parse_modifiers(row, cur.price_modifiers, Keyword.get(opts, :sets))
    ]

    errors = Enum.flat_map(parsed, fn {_field, result} -> errors_of(result) end)

    cond do
      errors != [] ->
        {:error, errors}

      not Enum.any?(["price", "compare_at", "price_modifiers"], &Map.has_key?(row, &1)) ->
        {:error, [error("", "nothing to change: give price, compare_at or price_modifiers")]}

      true ->
        values = Map.new(parsed, fn {field, {:ok, value}} -> {field, value} end)
        finish(cur, values, {row, item}, opts)
    end
  end

  defp errors_of({:error, errors}), do: errors
  defp errors_of({:ok, _value}), do: []

  defp finish(cur, values, {row, item}, opts) do
    to = %{
      price: pick(values.price, cur.price),
      compare_at: pick(values.compare_at, cur.compare_at),
      price_modifiers: pick(values.price_modifiers, cur.price_modifiers)
    }

    leaves = changed_leaves(cur.price_modifiers, to.price_modifiers)

    case cheapest_error(to, values, leaves) do
      nil ->
        changes = changes(cur, to, leaves)

        plan =
          Map.merge(write(to, changes, leaves), %{
            from: cur,
            to: to,
            changes: changes,
            changed?: changes != %{},
            dangerous?: dangerous?(cur, to, leaves, Keyword.fetch!(opts, :pct)),
            warnings: warnings(item, to, opts),
            leaves: leaves,
            guard: guard(cur, row)
          })

        validate_write(plan)

      message ->
        {:error, [error("price_modifiers", message)]}
    end
  end

  # What the plan reads of the item, to tell whether the item is still the one
  # it was made from (`Batch.write_if_unchanged/4`): the prices and the option
  # prices the row names. `from` carries the whole option map, which the
  # confirmation fingerprint wants; an option price the row does not name is
  # none of this row's business, and a sync rewriting it meanwhile must not
  # fail the row.
  defp guard(cur, row) do
    leaves =
      Enum.reduce(named_leaves(row), %{}, fn {option, value} = key, acc ->
        Map.update(acc, option, %{value => leaf(cur.price_modifiers, key)}, fn values ->
          Map.put(values, value, leaf(cur.price_modifiers, key))
        end)
      end)

    %{price: cur.price, compare_at: cur.compare_at, price_modifiers: leaves}
  end

  defp named_leaves(%{"price_modifiers" => given}) when is_map(given) do
    for {option, values} <- given, is_map(values), value <- Map.keys(values), do: {option, value}
  end

  defp named_leaves(_row), do: []

  defp pick(:unset, current), do: current
  defp pick(value, _current), do: value

  # -- parsing ---------------------------------------------------------------

  defp parse_price(%{"price" => value}) do
    case Money.parse(value) do
      {:ok, decimal} -> {:ok, decimal}
      {:error, message} -> {:error, [error("price", message)]}
    end
  end

  defp parse_price(_row), do: {:ok, :unset}

  defp parse_compare_at(%{"compare_at" => nil}), do: {:ok, nil}

  defp parse_compare_at(%{"compare_at" => value}) do
    case Money.parse(value) do
      {:ok, decimal} -> {:ok, decimal}
      {:error, message} -> {:error, [error("compare_at", message)]}
    end
  end

  defp parse_compare_at(_row), do: {:ok, :unset}

  defp parse_modifiers(%{"price_modifiers" => given}, stored, sets) when is_map(given) do
    {merged, errors} =
      Enum.reduce(given, {stored, []}, fn {option, values}, acc ->
        merge_option(acc, option, values, stored, sets)
      end)

    if errors == [], do: {:ok, merged}, else: {:error, Enum.reverse(errors)}
  end

  defp parse_modifiers(%{"price_modifiers" => _other}, _stored, _sets),
    do: {:error, [error("price_modifiers", "must be an object of option => value => amount")]}

  defp parse_modifiers(_row, _stored, _sets), do: {:ok, :unset}

  defp merge_option({merged, errors}, option, values, stored, sets) when is_map(values) do
    allowed = allowed_values(sets, option)

    Enum.reduce(values, {merged, errors}, fn {value, amount}, {acc, errs} ->
      merge_leaf(acc, errs, {option, value, amount}, {stored, sets, allowed})
    end)
  end

  defp merge_option({merged, errors}, option, _other, _stored, _sets) do
    {merged,
     [error("price_modifiers.#{option}", "must be an object of value => amount") | errors]}
  end

  defp merge_leaf(acc, errs, {option, value, nil}, _context) do
    {delete_leaf(acc, option, value), errs}
  end

  defp merge_leaf(acc, errs, {option, value, amount}, {stored, sets, allowed}) do
    path = "price_modifiers.#{option}.#{value}"

    cond do
      stored_leaf?(stored, option, value) ->
        put_valid_leaf(acc, errs, {option, value, amount}, path)

      is_nil(sets) ->
        put_valid_leaf(acc, errs, {option, value, amount}, path)

      is_nil(allowed) ->
        {acc,
         [
           error("price_modifiers.#{option}", unknown_option_text(sets), allowed_options(sets))
           | errs
         ]}

      value not in allowed ->
        {acc, [error(path, "unknown value of option #{option}", allowed) | errs]}

      true ->
        put_valid_leaf(acc, errs, {option, value, amount}, path)
    end
  end

  defp put_valid_leaf(acc, errs, {option, value, amount}, path) do
    case Money.parse_delta(amount) do
      {:ok, _decimal} -> {put_leaf(acc, option, value, amount), errs}
      {:error, message} -> {acc, [error(path, message) | errs]}
    end
  end

  defp stored_leaf?(stored, option, value) do
    case Map.get(stored, option) do
      %{} = values -> Map.has_key?(values, value)
      _ -> false
    end
  end

  defp put_leaf(modifiers, option, value, amount) do
    Map.update(modifiers, option, %{value => amount}, fn existing ->
      Map.put(if(is_map(existing), do: existing, else: %{}), value, amount)
    end)
  end

  defp delete_leaf(modifiers, option, value) do
    case Map.get(modifiers, option) do
      %{} = existing ->
        remaining = Map.delete(existing, value)

        if remaining == %{},
          do: Map.delete(modifiers, option),
          else: Map.put(modifiers, option, remaining)

      _ ->
        modifiers
    end
  end

  # The value names of option `option` among the item's resolved attribute
  # sets. `nil` when the sets are not given or the option is not one of them.
  defp allowed_values(nil, _option), do: nil

  defp allowed_values(sets, option) do
    case Enum.find(sets, &(bare_key(&1) == option)) do
      nil -> nil
      set -> set |> Map.get(:values, []) |> Enum.map(&Map.get(&1, :key))
    end
  end

  # Option sets come from the entities module; without it (or without a set on
  # the product) there is nothing to price, and the caller should be told why.
  defp unknown_option_text([]),
    do:
      "unknown option: the product has no option sets (option prices need the entities module enabled)"

  defp unknown_option_text(_sets), do: "unknown option"

  defp allowed_options(sets), do: Enum.map(sets, &bare_key/1)

  defp bare_key(set) do
    case Map.get(set, :key) do
      "catalogue_set_" <> slug -> slug
      key -> key
    end
  end

  # Only a row that gives the price or changes a modifier answers for the
  # total: what the row does not touch is none of its business.
  defp cheapest_error(to, values, leaves) do
    if values.price == :unset and leaves == [], do: nil, else: lowest_total_error(to)
  end

  # With every option at its cheapest modifier the item must still cost
  # something: a negative total is a price the checkout cannot charge.
  defp lowest_total_error(%{price: nil}), do: nil

  defp lowest_total_error(%{price: price, price_modifiers: modifiers}) do
    cheapest =
      modifiers
      |> Map.values()
      |> Enum.map(&cheapest_value/1)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    if Decimal.lt?(Decimal.add(price, cheapest), 0),
      do: "the cheapest combination of options would cost less than zero",
      else: nil
  end

  defp cheapest_value(%{} = values) do
    values
    |> Map.values()
    |> Enum.map(&Money.to_decimal/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.min/2)
  end

  defp cheapest_value(_other), do: Decimal.new(0)

  # -- diff ------------------------------------------------------------------

  defp changes(cur, to, leaves) do
    %{}
    |> put_change("price", cur.price, to.price)
    |> put_change("compare_at", cur.compare_at, to.compare_at)
    |> Map.merge(modifier_changes(cur.price_modifiers, to.price_modifiers, leaves))
  end

  defp put_change(changes, name, from, to) do
    if same?(from, to),
      do: changes,
      else: Map.put(changes, name, %{"from" => Money.format(from), "to" => Money.format(to)})
  end

  defp same?(nil, nil), do: true
  defp same?(nil, _to), do: false
  defp same?(_from, nil), do: false
  defp same?(from, to), do: Decimal.eq?(from, to)

  # The `{option, value}` leaves whose amount differs, sorted. The plan carries
  # them as pairs: the dotted key of `changes` is for display, and a name that
  # contains a dot could not be told apart from the separator.
  defp changed_leaves(from, to) do
    (leaf_keys(from) ++ leaf_keys(to))
    |> Enum.uniq()
    |> Enum.reject(&leaf_same?(leaf(from, &1), leaf(to, &1)))
    |> Enum.sort()
  end

  defp modifier_changes(from, to, leaves) do
    Map.new(leaves, fn {option, value} = key ->
      {"price_modifiers.#{option}.#{value}",
       %{"from" => show(leaf(from, key)), "to" => show(leaf(to, key))}}
    end)
  end

  defp leaf_keys(modifiers) do
    for {option, values} <- modifiers,
        is_map(values),
        {value, _amount} <- values,
        do: {option, value}
  end

  defp leaf(modifiers, {option, value}) do
    case Map.get(modifiers, option) do
      %{} = values -> Map.get(values, value)
      _ -> nil
    end
  end

  defp leaf_same?(a, b) when a == b, do: true

  defp leaf_same?(a, b) do
    case {Money.to_decimal(a), Money.to_decimal(b)} do
      {%Decimal{} = x, %Decimal{} = y} -> Decimal.eq?(x, y)
      _ -> false
    end
  end

  defp show(nil), do: nil

  defp show(leaf) do
    case Money.to_decimal(leaf) do
      %Decimal{} = decimal -> Money.format(decimal)
      nil -> inspect(leaf)
    end
  end

  # -- danger ----------------------------------------------------------------

  @doc """
  Whether moving `from` to `to` is more than `pct` percent of `from`. A first
  price (`from` is `nil` or zero) is never held back here (`dangerous?/4` holds
  a first price of zero), and exactly `pct` percent is not "more than". A `to`
  of `nil` counts as zero.
  """
  @spec moved_over?(Decimal.t() | nil, Decimal.t() | nil, non_neg_integer()) :: boolean()
  def moved_over?(%Decimal{} = from, to, pct) do
    if Decimal.eq?(from, 0) do
      false
    else
      delta = (to || Decimal.new(0)) |> Decimal.sub(from) |> Decimal.abs()
      Decimal.gt?(Decimal.mult(delta, 100), Decimal.mult(Decimal.abs(from), pct))
    end
  end

  def moved_over?(_from, _to, _pct), do: false

  # The base price is held when it moves past `pct` percent of itself. An
  # option price is held when the leaf itself moves past `pct` percent of its
  # own previous value, or - the case a new or zero leaf would otherwise slip
  # through - when it adds or takes away more than `pct` percent of the
  # product's current base price: that is the amount the customer's price of
  # the option moves by, whatever the leaf was before. An unpriced product
  # has no base to measure against, so only its first price is exempt - except
  # a price of zero, which a percentage of nothing would never catch: a price
  # set to zero is held whatever it replaces.
  defp dangerous?(cur, to, leaves, pct) do
    moved_over?(cur.price, to.price, pct) or zeroed?(cur.price, to.price) or
      Enum.any?(leaves, &modifier_dangerous?(cur, to, &1, pct))
  end

  defp zeroed?(from, %Decimal{} = to), do: Decimal.eq?(to, 0) and not zero?(from)
  defp zeroed?(_from, _to), do: false

  defp zero?(%Decimal{} = price), do: Decimal.eq?(price, 0)
  defp zero?(_price), do: false

  defp modifier_dangerous?(cur, to, key, pct) do
    from = cur.price_modifiers |> leaf(key) |> Money.to_decimal()
    new = to.price_modifiers |> leaf(key) |> Money.to_decimal()

    moved_over?(from, new, pct) or moved_over?(cur.price, shifted(cur.price, from, new), pct)
  end

  defp shifted(%Decimal{} = base, from, new),
    do: base |> Decimal.add(new || Decimal.new(0)) |> Decimal.sub(from || Decimal.new(0))

  defp shifted(_base, _from, _new), do: nil

  @doc "The change of `from` to `to` as a percentage of `from`, one decimal, or `nil`."
  @spec change_pct(Decimal.t() | nil, Decimal.t() | nil) :: String.t() | nil
  def change_pct(%Decimal{} = from, %Decimal{} = to) do
    if Decimal.eq?(from, 0) do
      nil
    else
      to
      |> Decimal.sub(from)
      |> Decimal.mult(100)
      |> Decimal.div(Decimal.abs(from))
      |> Decimal.round(1)
      |> Decimal.to_string(:normal)
    end
  end

  def change_pct(_from, _to), do: nil

  # -- the catalogue write ---------------------------------------------------

  # `attrs` goes to the catalogue's batch update; `owned_paths` are the `data`
  # sub-paths this row writes, so a concurrent writer of any other path (the
  # Shopify sync) is never overwritten. An option price is owned **per leaf**
  # (`["ecommerce", "price_modifiers", option, value]`, an explicit `nil` for a
  # removal): owning the whole `price_modifiers` subtree would let a call that
  # read the item before another writer stored a different option drop that
  # option.
  defp write(_to, changes, _leaves) when changes == %{}, do: %{attrs: %{}, owned_paths: []}

  defp write(to, changes, leaves) do
    compare? = Map.has_key?(changes, "compare_at")

    ecommerce =
      %{}
      |> put_if(compare?, "compare_at_price", Money.format(to.compare_at))
      |> put_if(leaves != [], "price_modifiers", written_modifiers(to.price_modifiers, leaves))

    attrs =
      %{}
      |> put_if(Map.has_key?(changes, "price"), :base_price, to.price)
      |> put_if(ecommerce != %{}, :data, %{"ecommerce" => ecommerce})

    owned_paths =
      if(compare?, do: [@compare_at_path], else: []) ++
        Enum.map(leaves, fn {option, value} -> @modifiers_path ++ [option, value] end)

    %{attrs: attrs, owned_paths: owned_paths}
  end

  # `option => value => amount` for exactly those leaves; a removed leaf is `nil`.
  defp written_modifiers(modifiers, leaves) do
    Enum.reduce(leaves, %{}, fn {option, value}, acc ->
      put_leaf(acc, option, value, leaf(modifiers, {option, value}))
    end)
  end

  # The row is checked through `ItemCommerce` and its metadata normalizer
  # before anything is stored. Only the leaves the row writes are checked: a
  # stored leaf this module does not touch is none of the row's business, and
  # refusing the row because of it would block an unrelated edit.
  @doc false
  @spec validate_write(map()) :: {:ok, map()} | {:error, [map()]}
  def validate_write(%{changed?: false} = plan), do: {:ok, plan}

  def validate_write(plan) do
    params =
      %{}
      |> put_param(
        Map.has_key?(plan.changes, "compare_at"),
        "compare_at_price",
        Money.format(plan.to.compare_at)
      )
      |> put_modifier_param(written_leaves(plan))

    case ItemCommerce.cast(params, nil) do
      {:ok, _namespace} ->
        {:ok, plan}

      {:error, errors} ->
        {:error, Enum.map(errors, fn {field, message} -> error(to_string(field), message) end)}
    end
  end

  defp put_param(params, true, key, value), do: Map.put(params, key, value)
  defp put_param(params, false, _key, _value), do: params

  defp put_modifier_param(params, written) when written == %{}, do: params

  defp put_modifier_param(params, written) do
    normalized =
      %{"_price_modifiers" => written}
      |> MetadataValidator.normalize_price_modifiers()
      |> Map.get("_price_modifiers", %{})

    Map.put(params, "price_modifiers", normalized)
  end

  # `option => value => amount` for the leaves the plan writes; a removed leaf
  # is not validated (there is nothing to check).
  defp written_leaves(plan) do
    Enum.reduce(plan.leaves, %{}, fn {option, value}, acc ->
      case leaf(plan.to.price_modifiers, {option, value}) do
        nil -> acc
        amount -> put_leaf(acc, option, value, amount)
      end
    end)
  end

  # -- warnings --------------------------------------------------------------

  defp warnings(item, to, opts) do
    []
    |> maybe_warn(compare_not_above?(to), "compare_at_not_above_price")
    |> maybe_warn(
      shopify_sync_may_overwrite?(item, Keyword.get(opts, :shopify_enabled?, false)),
      "shopify_sync_may_overwrite"
    )
  end

  defp compare_not_above?(%{price: %Decimal{} = price, compare_at: %Decimal{} = compare_at}),
    do: not Decimal.gt?(compare_at, price)

  defp compare_not_above?(_to), do: false

  defp maybe_warn(list, true, code), do: list ++ [code]
  defp maybe_warn(list, false, _code), do: list

  # -- helpers ---------------------------------------------------------------

  defp modifiers(%{} = modifiers), do: modifiers
  defp modifiers(_other), do: %{}
end
