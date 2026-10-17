defmodule PhoenixKitEcommerce.API.CartWriter do
  @moduledoc """
  `shop.set_cart_items`: set the named lines of a cart to their final
  quantities.

  Lines are planned first (options normalized, duplicates, quantity, product on
  sale, options mapped to labels); a line that fails is an error result and is
  never applied, the others carry on. The planned lines are then applied in
  **one transaction** that holds the cart row lock, checks `expected_revision`
  and the cart's fixed currency, stores the new revision snapshot, and (for a
  dry run) is rolled back so the preview is exactly what a real write answers.
  The one capped notification is sent after commit.

  Writes go through the existing `Shop.add_to_cart/4` (with `via: :assistant`,
  so no per-line signal), `update_cart_item/2` and `remove_from_cart/1`; a
  line therefore keeps the price it was added at and is validated by the same
  code the storefront uses.
  """

  require Logger

  alias PhoenixKit.RepoHelper
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartMoney
  alias PhoenixKitEcommerce.API.CartOptions
  alias PhoenixKitEcommerce.API.CartStore
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.API.Signals
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.Product

  @max_quantity 99
  # At most 50 lines per request (the tool's `maxItems`) and 50 different lines
  # per cart, so an anonymous token cannot grow a cart without bound.
  @max_lines 50

  # Refusals of `add_to_cart` that are decided before it writes anything and that
  # a retry cannot change: the product's currency does not fit the cart, the shop
  # is off, or the cart's frozen currency cannot be rebased onto the current base
  # currency. (A currency mismatch has its own message.) The checkout claim's merge
  # reads the same list through `refused_before_write?/1`.
  @line_refusals [
    :currency_mismatch,
    :shop_disabled,
    :cart_base_unavailable,
    :currency_unavailable
  ]

  @type error :: {:error, atom(), String.t(), map()}

  @doc """
  Applies `input["items"]` to the cart behind `hash`. `hash` is the digest
  `CartToken.verify/1` returned: the writer trusts its caller to have verified
  the token. `input` may carry `"expected_revision"` and `"currency"`; `ctx` is
  the handler context (`language`, `currency`, `dry_run?`, `actor`).
  """
  @spec set_items(String.t(), map(), map()) ::
          {:ok, map()} | {:preview, map(), String.t()} | error()
  def set_items(hash, input, ctx) when is_binary(hash) and is_map(input) do
    dry? = ctx[:dry_run?] == true
    plans = plan(Map.get(input, "items", []), ctx)
    write? = Enum.any?(plans, &(&1.state == :ok and &1.qty > 0))

    hash
    |> transaction(plans, input, ctx, write?, dry?)
    |> finish()
  rescue
    # `add_to_cart` row-locks Legacy product rows while this transaction holds
    # the cart row, the reverse of the module's own order (product first, cart
    # second). Lines are applied in product-uuid order so two
    # API writers cannot deadlock each other; what is left is a writer against
    # a storefront add on the same cart, which Postgres resolves by aborting
    # one side. That is a retryable answer, not a 500.
    error ->
      if deadlock?(error),
        do: finish({:error, {:state_changed, :deadlock}}),
        else: reraise(error, __STACKTRACE__)
  end

  # Matched by shape so the module needs no compile-time dependency on Postgrex.
  @doc false
  @spec deadlock?(term()) :: boolean()
  def deadlock?(%{__struct__: Postgrex.Error, postgres: %{code: :deadlock_detected}}), do: true
  def deadlock?(_other), do: false

  @doc false
  @spec max_quantity() :: pos_integer()
  def max_quantity, do: @max_quantity

  # --- the transaction ----------------------------------------------------------

  defp transaction(hash, plans, input, ctx, write?, dry?) do
    repo().transaction(fn ->
      if write?, do: check_cartless_revision!(hash, input, ctx)

      case fetch_cart(hash, ctx, write?, dry?) do
        {:ok, cart, origin} -> run(hash, cart, origin, plans, input, ctx, dry?)
        :no_cart -> no_cart(plans, input, ctx, dry?)
        {:locked, claim} -> repo().rollback({:locked, claim})
        :not_found -> repo().rollback(:not_found)
        {:error, :rate_limited, retry} -> repo().rollback({:rate_limited, retry})
        {:error, reason} -> repo().rollback({:internal, reason})
      end
    end)
  end

  # A cart row is created only when some line adds or changes something; a
  # request made only of removals and invalid lines never creates one.
  defp fetch_cart(hash, ctx, true, dry?), do: CartStore.for_write(hash, ctx, count_row: not dry?)

  # The no-write path: the cart is found without the session lock, and
  # `lock_active!/2` re-checks under the row lock that it is still this
  # token's active cart (a claim or the sweep may have changed it since the
  # resolve; that rolls back with `{:locked, claim}` / `:not_found`).
  defp fetch_cart(hash, _ctx, false, _dry?) do
    case CartStore.resolve(hash) do
      {:ok, cart} -> {:ok, CartStore.lock_active!(cart.uuid, hash), :existing}
      :empty -> :no_cart
      {:locked, claim} -> {:locked, claim}
      :not_found -> :not_found
    end
  end

  # A request made only of removals and invalid lines, on a token without a
  # cart. A dry run must answer `{:preview, ...}` here as everywhere else:
  # core's executor turns any other answer to a dry run into a 500.
  defp no_cart(plans, input, ctx, dry?) do
    check_empty_cart_revision!(input, ctx)

    if dry?,
      do: repo().rollback({:dry_run, nothing_to_do(plans, ctx)}),
      else: {:nothing, nothing_to_do(plans, ctx)}
  end

  defp run(hash, cart, origin, plans, input, ctx, dry?) do
    before_snapshot = CartView.snapshot(cart)
    before_view = CartView.build(cart)

    check_currency!(cart, origin, input)
    check_revision!(cart, input, before_view)

    {_cart, results, updated} = apply_plans(cart, plans, ctx)
    after_cart = CartStore.lock_active!(cart.uuid, hash)
    after_snapshot = CartView.stamp(CartView.snapshot(after_cart))

    if after_snapshot["revision"] != before_view.revision do
      CartStore.put_snapshot!(after_cart, after_snapshot)
    end

    after_view = CartView.build(after_cart)

    result = %{
      results: results,
      summary: summary(results),
      before: before_view.totals,
      after: after_view.totals,
      effects: effects(after_cart, updated),
      changes: CartView.changes(before_snapshot, after_snapshot),
      revision: after_view.revision,
      cart: after_view
    }

    if dry? do
      repo().rollback({:dry_run, result})
    else
      {:written, result, after_cart, signal_lines(after_cart, plans, results)}
    end
  end

  defp finish({:ok, {:written, result, cart, lines}}) do
    Signals.cart_changed(cart, lines)
    {:ok, result}
  end

  defp finish({:ok, {:nothing, result}}), do: {:ok, result}
  defp finish({:error, {:dry_run, result}}), do: {:preview, result, result.revision}

  defp finish({:error, {:locked, _claim}}) do
    {:error, :cart_locked, "This cart was handed over for checkout and can no longer be changed.",
     %{}}
  end

  defp finish({:error, :not_found}) do
    {:error, :cart_not_found, "Unknown or expired cart token.", %{}}
  end

  defp finish({:error, {:rate_limited, retry}}) do
    {:error, :rate_limited, "Too many new carts from this network. Try again later.",
     %{retry_after: retry}}
  end

  defp finish({:error, {:currency_fixed, currency}}) do
    {:error, :validation_failed, "The cart's currency was fixed at its first write.",
     %{
       reason: "cart_currency_fixed",
       errors: [
         %{
           path: "currency",
           message: "This cart is in #{currency}; the currency cannot change.",
           limit: nil,
           allowed: [currency]
         }
       ]
     }}
  end

  defp finish({:error, {:revision_mismatch, context}}) do
    {:error, :revision_mismatch, "The cart has changed since the revision you sent.", context}
  end

  defp finish({:error, {:state_changed, reason}}) do
    Logger.warning("[Shop] cart write rolled back: #{kind(reason)}")

    {:error, :validation_failed,
     "The cart or a product changed while the request ran. Read the cart and send it again.",
     %{reason: "state_changed", retry: true}}
  end

  defp finish({:error, other}) do
    Logger.error("[Shop] cart write failed: #{kind(other)}")
    {:error, :internal_error, "The cart could not be updated.", %{}}
  end

  # Only the shape of an unexpected answer is logged: its content can hold
  # request data (a changeset keeps the values it was given).
  defp kind(%{__struct__: module}), do: inspect(module)
  defp kind(atom) when is_atom(atom), do: inspect(atom)

  defp kind(tuple) when is_tuple(tuple),
    do: "{" <> (tuple |> Tuple.to_list() |> Enum.take(2) |> Enum.map_join(", ", &kind/1)) <> "}"

  defp kind(_other), do: "term"

  # --- checks -------------------------------------------------------------------

  # The currency is fixed at the cart's first write. Only an explicit
  # override on an existing cart can disagree with it; with none, the cart's
  # own currency is used.
  defp check_currency!(%Cart{currency: currency}, :existing, %{"currency" => code})
       when is_binary(code) and code != "" do
    if String.upcase(code) == currency,
      do: :ok,
      else: repo().rollback({:currency_fixed, currency})
  end

  defp check_currency!(_cart, _origin, _input), do: :ok

  defp check_revision!(cart, input, before_view) do
    case input["expected_revision"] do
      nil ->
        :ok

      revision when revision == before_view.revision ->
        :ok

      revision ->
        repo().rollback({:revision_mismatch, mismatch(cart, revision, before_view)})
    end
  end

  # A token without a cart stands for the empty cart. A wrong revision is
  # refused before the first write takes the session lock and spends one of the
  # network's row slots (which a rollback does not give back).
  defp check_cartless_revision!(hash, input, ctx) do
    if input["expected_revision"] != nil and CartStore.empty?(hash),
      do: check_empty_cart_revision!(input, ctx)
  end

  defp check_empty_cart_revision!(input, ctx) do
    expected = input["expected_revision"]
    empty = CartView.empty(CartStore.display_currency(ctx))

    if expected != nil and expected != empty.revision do
      context = %{current_revision: empty.revision, expected_revision: expected, cart: empty}
      repo().rollback({:revision_mismatch, context})
    end
  end

  defp mismatch(cart, expected, before_view) do
    base = %{current_revision: before_view.revision, expected_revision: expected}

    case remembered(cart, expected) do
      nil -> Map.put(base, :cart, before_view)
      old -> Map.put(base, :changes_since, CartView.changes(old, CartView.snapshot(cart)))
    end
  end

  defp remembered(cart, expected) do
    if expected == CartView.revision(nil) do
      CartView.snapshot(nil)
    else
      (cart.metadata || %{})
      |> Map.get("api_revisions", [])
      |> Enum.find(&(&1["revision"] == expected))
    end
  end

  # --- planning -------------------------------------------------------------------

  defp plan(items, ctx) when is_list(items) do
    entries = items |> Enum.with_index() |> Enum.map(&entry/1)
    duplicated = duplicated_keys(entries)
    records = load_records(entries, duplicated, ctx)

    Enum.map(entries, &plan_entry(&1, duplicated, records))
  end

  defp plan(_other, _ctx), do: []

  # One loader call for every product the request may add or change, instead
  # of a product read (and its option reads) per line: up to 50 lines is one
  # read here. The loader answers by id, drops malformed and unknown ids, and
  # carries the visibility state of the public API.
  defp load_records(entries, duplicated, ctx) do
    ids =
      entries
      |> Enum.filter(&loadable?(&1, duplicated))
      |> Enum.map(& &1.product_id)
      |> Enum.uniq()

    if ids == [], do: %{}, else: Loader.load(ids, language: ctx[:language])
  end

  # Only the lines that reach `plan_product/2` need their product.
  defp loadable?(entry, duplicated) do
    entry.options_ok? and entry.id_ok? and not MapSet.member?(duplicated, key(entry)) and
      valid_quantity?(entry.quantity) and entry.quantity > 0
  end

  # Anything but an object cannot name a product: it is a `not_found` line.
  defp entry({item, index}) when not is_map(item) do
    %{
      index: index,
      ref: %{product_id: nil, options: []},
      product_id: nil,
      quantity: nil,
      options: [],
      options_ok?: true,
      id_ok?: false
    }
  end

  defp entry({item, index}) do
    raw_options = item["options"] || []

    {options, options_ok?} =
      case CartOptions.normalize(raw_options) do
        {:ok, options} -> {options, true}
        :error -> {[], false}
      end

    %{
      index: index,
      ref: %{product_id: item["product_id"], options: raw_options},
      product_id: canonical_id(item["product_id"]),
      quantity: item["quantity"],
      options: options,
      options_ok?: options_ok?,
      id_ok?: is_binary(item["product_id"]) and Loader.canonical_uuid(item["product_id"]) != nil
    }
  end

  # A valid UUID is identified by its lower-case form, which is what the cart
  # line stores: 'A1B2...' and 'a1b2...' are the same product (one duplicate
  # key, one line found again, one quantity set instead of two added). The
  # echoed `ref` keeps what the agent sent. Anything else stays as it is and
  # fails the loader as `not_found`.
  defp canonical_id(id) when is_binary(id), do: Loader.canonical_uuid(id) || id

  defp canonical_id(other), do: other

  defp key(entry), do: {entry.product_id, CartOptions.canonical(entry.options)}

  defp duplicated_keys(entries) do
    entries
    |> Enum.filter(&(&1.options_ok? and &1.id_ok?))
    |> Enum.map(&key/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> MapSet.new(fn {key, _count} -> key end)
  end

  defp plan_entry(entry, duplicated, records) do
    cond do
      not entry.options_ok? ->
        error_plan(
          entry,
          :option_invalid,
          "Each option needs a non-empty attribute_key and value_key.",
          %{}
        )

      MapSet.member?(duplicated, key(entry)) ->
        error_plan(
          entry,
          :duplicate_line,
          "This product and option combination appears more than once; send it once with the final quantity.",
          %{}
        )

      not entry.id_ok? ->
        error_plan(entry, :not_found, "No such product.", %{})

      not valid_quantity?(entry.quantity) ->
        error_plan(
          entry,
          :quantity_invalid,
          "Quantity must be a whole number from 0 to #{@max_quantity}.",
          %{allowed: %{min: 0, max: @max_quantity}}
        )

      entry.quantity == 0 ->
        ok_plan(entry, nil, nil)

      true ->
        plan_product(entry, records)
    end
  end

  defp valid_quantity?(quantity),
    do: is_integer(quantity) and quantity >= 0 and quantity <= @max_quantity

  defp plan_product(entry, records) do
    with {:ok, product} <- addable_product(Map.get(records, entry.product_id)),
         {:ok, specs} <- CartOptions.to_specs(product, entry.options) do
      ok_plan(entry, product, specs)
    else
      {:error, :not_found} ->
        error_plan(entry, :not_found, "No such product.", %{})

      {:error, :not_on_sale} ->
        error_plan(entry, :not_on_sale, "This product is not on sale.", %{})

      {:error, :option_required, context} ->
        error_plan(entry, :option_required, "A required option is missing.", context)

      {:error, :option_invalid, context} ->
        error_plan(entry, :option_invalid, "That option is not valid for this product.", context)
    end
  end

  # The public API's visibility rule decides, not a status check of our own.
  # `:listed` is addable, `:discontinued` is `not_on_sale`, and `:hidden` (or an
  # id the loader does not know) is `not_found`: the same answer
  # `shop.get_products` gives, so a hidden product cannot be put into a cart.
  # Public for the checkout claim's merge, which applies the same rule.
  @doc false
  @spec addable_product(Record.t() | nil) ::
          {:ok, Product.t()} | {:error, :not_on_sale | :not_found}
  def addable_product(%Record{
        state: :listed,
        product: %Product{} = product,
        category: category
      }),
      do: {:ok, with_category(product, category)}

  def addable_product(%Record{state: :discontinued}), do: {:error, :not_on_sale}
  def addable_product(_hidden_or_absent), do: {:error, :not_found}

  # The option schema of a product may come from its category. The loader's
  # view-struct has none attached on the catalogue source (the record carries
  # it), and a category the struct does not hold would be looked up in the
  # legacy table, so the planner would not see the options `add_to_cart` does.
  defp with_category(%Product{category: %Category{}} = product, _category), do: product

  defp with_category(%Product{} = product, %Category{} = category),
    do: %{product | category: category}

  defp with_category(product, _category), do: product

  defp ok_plan(entry, product, specs) do
    %{
      state: :ok,
      index: entry.index,
      ref: entry.ref,
      product_id: entry.product_id,
      qty: entry.quantity,
      product: product,
      specs: specs,
      options: entry.options
    }
  end

  defp error_plan(entry, code, message, extra) do
    %{
      state: :error,
      index: entry.index,
      ref: entry.ref,
      code: code,
      message: message,
      extra: extra
    }
  end

  # --- applying -------------------------------------------------------------------

  # The lines are independent (a product and options appear once), so they are
  # applied in product-uuid order, whatever order the request listed them in:
  # two writers that name the same Legacy products in opposite orders would
  # otherwise lock the product rows crosswise. The results go back in request
  # order.
  defp apply_plans(cart, plans, ctx) do
    {cart, results, updated} =
      plans
      |> Enum.sort_by(&apply_order/1)
      |> Enum.reduce({cart, [], []}, fn plan, {cart, results, updated} ->
        case apply_plan(cart, plan, ctx) do
          {:ok, cart, result, touched} -> {cart, [result | results], touched ++ updated}
          {:abort, reason} -> repo().rollback({:state_changed, reason})
        end
      end)

    {cart, Enum.sort_by(results, & &1.index), updated}
  end

  # Removals first, so a request that removes one line and adds another fits on a
  # full cart; then by product uuid.
  defp apply_order(plan) do
    {if(Map.get(plan, :qty) == 0, do: 0, else: 1), Map.get(plan, :product_id) || "", plan.index}
  end

  defp apply_plan(cart, %{state: :error} = plan, _ctx), do: {:ok, cart, error_result(plan), []}

  defp apply_plan(cart, %{qty: 0} = plan, _ctx) do
    case find_item(cart.items, plan) do
      nil ->
        {:ok, cart, result(plan, "unchanged", 0), []}

      %CartItem{} = item ->
        case Shop.remove_from_cart(item) do
          {:ok, updated} -> {:ok, updated, result(plan, "removed", 0), []}
          other -> {:abort, other}
        end
    end
  end

  defp apply_plan(cart, plan, ctx) do
    case find_item(cart.items, plan) do
      nil ->
        add_line(cart, plan, ctx)

      %CartItem{} = item ->
        if item.quantity == plan.qty,
          do: {:ok, cart, result(plan, "unchanged", plan.qty), []},
          else: update_line(cart, item, plan)
    end
  end

  defp add_line(%Cart{items: items} = cart, plan, _ctx) when length(items) >= @max_lines do
    refused(
      cart,
      plan,
      :validation_failed,
      "A cart holds at most #{@max_lines} different lines.",
      %{
        reason: "cart_lines_limit",
        allowed: %{max: @max_lines}
      }
    )
  end

  defp add_line(cart, plan, ctx) do
    opts = [selected_specs: plan.specs, language: ctx[:language], via: :assistant]

    case Shop.add_to_cart(cart, plan.product, plan.qty, opts) do
      {:ok, updated} ->
        tag_options!(updated, plan)
        {:ok, updated, result(plan, "created", plan.qty), []}

      other ->
        refusal(cart, plan, other)
    end
  end

  @doc false
  # True for the refusals of `add_to_cart` that it makes before it opens its own
  # transaction and that a retry cannot change; the checkout claim's merge skips
  # such a line, and anything else it treats as a failure.
  @spec refused_before_write?(atom()) :: boolean()
  def refused_before_write?(reason), do: reason in @line_refusals

  # What `add_to_cart` answered when it did not add the line. Only the refusals
  # it makes before it opens its own transaction (nothing was written, nothing
  # is poisoned) and that no retry can change are this line's error, and the
  # good lines go on: retrying them would fail forever, so they must never
  # become the retryable `state_changed` of the batch.
  defp refusal(cart, plan, {:error, :currency_mismatch}) do
    refused(cart, plan, :not_on_sale, "This product cannot be sold in this cart.", %{
      reason: "currency_mismatch"
    })
  end

  defp refusal(cart, plan, {:error, reason}) when reason in @line_refusals do
    refused(cart, plan, :not_on_sale, "This product cannot be added to this cart.", %{
      reason: Atom.to_string(reason)
    })
  end

  # Everything else fails closed. Some refusals are made inside `add_to_cart`'s
  # own transaction (a rollback in a nested transaction) and doom this one: no
  # further statement may run. That covers the option refusals, which mean the
  # product changed since the planner read it (a retry plans again and gets the
  # line's proper error), the cart rebase's rolled-back answer, and a cart that
  # changed under the writer.
  defp refusal(_cart, _plan, {:error, reason}) when is_atom(reason), do: {:abort, reason}
  defp refusal(_cart, _plan, {:error, reason, _detail}) when is_atom(reason), do: {:abort, reason}

  # Anything else (a changeset, a rollback inside its transaction, a lost race)
  # is unexpected: the batch is rolled back.
  defp refusal(_cart, _plan, other), do: {:abort, other}

  defp refused(cart, plan, code, message, extra) do
    error = %{index: plan.index, ref: plan.ref, code: code, message: message, extra: extra}
    {:ok, cart, error_result(error), []}
  end

  defp update_line(_cart, item, plan) do
    case Shop.update_cart_item(item, plan.qty) do
      {:ok, updated} -> {:ok, updated, result(plan, "updated", plan.qty), [{item, plan.product}]}
      other -> {:abort, other}
    end
  end

  # The new line carries the neutral options it was written with, so the cart
  # reads the same in any language and the line is found again by them. It is
  # located by the labels it was stored with (it has no neutral options yet).
  defp tag_options!(cart, plan) do
    case Enum.find(cart.items, &same_specs?(&1, plan)) do
      %CartItem{} = item ->
        metadata =
          Map.put(item.metadata || %{}, "api_options", CartOptions.stored_form(plan.options))

        item |> CartItem.changeset(%{metadata: metadata}) |> repo().update!()

      nil ->
        :ok
    end
  end

  defp same_specs?(item, plan),
    do:
      CartView.line_product_id(item) == plan.product_id and
        (item.selected_specs || %{}) == plan.specs

  # A line is found by its product and its neutral options.
  defp find_item(items, plan) do
    wanted = CartOptions.canonical(plan.options)

    Enum.find(items, fn item ->
      CartView.line_product_id(item) == plan.product_id and
        CartOptions.canonical(CartOptions.from_item(item, nil)) == wanted
    end)
  end

  defp result(plan, action, quantity) do
    %{index: plan.index, ref: plan.ref, action: action, id: plan.product_id, quantity: quantity}
  end

  defp error_result(plan) do
    %{
      index: plan.index,
      ref: plan.ref,
      action: "error",
      error: Map.merge(%{code: Atom.to_string(plan.code), message: plan.message}, plan.extra)
    }
  end

  defp summary(results), do: Enum.frequencies_by(results, & &1.action)

  defp nothing_to_do(plans, ctx) do
    view = CartView.empty(CartStore.display_currency(ctx))

    results =
      Enum.map(plans, fn
        %{state: :error} = plan -> error_result(plan)
        plan -> result(plan, "unchanged", 0)
      end)

    %{
      results: results,
      summary: summary(results),
      before: view.totals,
      after: view.totals,
      effects: [],
      changes: %{added: [], removed: [], changed: [], shipping: nil},
      revision: view.revision,
      cart: view
    }
  end

  # --- effects and the signal -----------------------------------------------------

  defp effects(cart, updated) do
    shipping_effects(cart) ++ Enum.flat_map(updated, &price_effects(&1, cart))
  end

  defp shipping_effects(%Cart{shipping_method_uuid: nil}), do: []

  defp shipping_effects(%Cart{shipping_method_uuid: uuid} = cart) do
    if Enum.any?(Shop.get_available_shipping_methods(cart), &(&1.uuid == uuid)) do
      []
    else
      [
        %{
          code: "shipping_method_unavailable",
          method: uuid,
          message:
            "The selected shipping method does not cover this cart any more; choose another one."
        }
      ]
    end
  end

  defp price_effects({%CartItem{base_unit_price: nil}, _product}, _cart), do: []

  defp price_effects({%CartItem{} = item, %Product{} = product}, %Cart{} = cart) do
    current = current_base_price(item, product)

    if Decimal.equal?(current, item.base_unit_price) do
      []
    else
      [
        %{
          code: "line_price_changed",
          product_id: CartView.line_product_id(item),
          kept_unit_price: CartMoney.new(item.unit_price, cart.currency),
          current_base_price: CartMoney.new(current, cart.base_currency || cart.currency),
          message:
            "The product's price changed after this line was added; the line keeps the price it was added at."
        }
      ]
    end
  end

  @doc false
  # The product's current base price for the variant a line holds. A line
  # stored before keys were the identity holds LABELS in the language it was
  # added in, while `product` is loaded in this call's language, so on the
  # Catalogue source the modifiers would be looked up under labels that do not
  # match and a price change would be reported (or missed) for every call in
  # another language. The line's neutral options are mapped to this product's
  # values instead; only a line without a usable mapping falls back to its
  # stored specs.
  @spec current_base_price(CartItem.t(), Product.t()) :: Decimal.t()
  def current_base_price(%CartItem{} = item, %Product{} = product) do
    specs =
      case CartOptions.to_specs(product, CartOptions.from_item(item, nil)) do
        {:ok, specs} -> specs
        {:error, _code, _context} -> item.selected_specs || %{}
      end

    Shop.calculate_product_price(product, specs)
  end

  defp signal_lines(cart, plans, results) do
    plans_by_index = Map.new(plans, &{&1.index, &1})

    Enum.flat_map(results, fn
      %{action: action, index: index} when action in ["created", "updated"] ->
        with %{} = plan <- Map.get(plans_by_index, index),
             %CartItem{} = item <- find_item(cart.items, plan) do
          [%{title: item.product_title, quantity: item.quantity}]
        else
          _ -> []
        end

      _other ->
        []
    end)
  end

  defp repo, do: RepoHelper.repo()
end
