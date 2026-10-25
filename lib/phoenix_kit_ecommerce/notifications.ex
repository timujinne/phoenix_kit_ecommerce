defmodule PhoenixKitEcommerce.Notifications do
  @moduledoc """
  Shop notifications: who hears about an order or an import, and when.

  Sends go through core's notification layer, so each recipient's own
  per-type preferences and delivery channels (in-app inbox, email,
  Telegram, digest cadence) apply. This module only decides the audience
  and the copy.

  ## Recipients

  `admin_recipients/0` unions three sources, because no single one is
  complete:

    * holders of the relevant permission key (`users_with_permission/1`)
    * **Owner-role holders**, whose access is implicit and who therefore
      have no permission rows at all
    * holders of the `"*"` superadmin key, likewise absent from a
      key-specific query

  A resolver that queried only the first would miss the primary operator
  of a default install — the person most likely to want the notification.

  ## Failure is never fatal

  Every send is wrapped: a notification is a message *about* a committed
  fact, and must not be able to undo it. Order placement in particular
  runs this after the conversion transaction commits.
  """

  require Logger

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Notifications
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Paths, as: BillingPaths
  alias PhoenixKitEcommerce.Translations

  @order_action "shop.order_placed"
  @customer_order_action "shop.order_confirmed"
  @import_completed_action "shop.import_completed"
  @import_failed_action "shop.import_failed"
  @cart_first_item_action "shop.cart_first_item_added"
  @cart_item_action "shop.cart_item_added"
  @checkout_started_action "shop.checkout_started"

  @doc """
  Notifies shop operators that an order was placed, and (separately) the
  customer that theirs was confirmed.

  `language:` is the language the buyer is checking out in; the customer's
  link goes to the order page in it, in the primary language without one.

  Best-effort by construction — see the module doc.
  """
  def order_placed(order, opts \\ []) do
    safely(fn ->
      notify_admins_of_order(order)
      notify_customer_of_order(order, opts[:language])
    end)
  end

  @doc """
  Storefront signal: an item landed in a cart.

  Emits `shop.cart_first_item_added` once per cart (atomic claim) when that
  toggle is on; otherwise emits `shop.cart_item_added` per add when the
  every-add toggle is on. A first add never produces both.

  `via: :assistant` in `opts` suppresses the message: the public cart API
  sends one coalesced signal per write instead (`assistant_cart_updated/3`).
  """
  def cart_item_added(cart, item, product, opts \\ []) do
    if Keyword.get(opts, :via) == :assistant do
      # A write made through the public cart API sends ONE coalesced signal of
      # its own (`assistant_cart_updated/3`, called by `API.Signals`), not one
      # per line.
      :ok
    else
      do_cart_item_added(cart, item, product)
    end
  end

  defp do_cart_item_added(cart, item, product) do
    safely(fn ->
      first? =
        PhoenixKitEcommerce.notify_event?(:cart_first_item) and
          cart.items_count == item.quantity and
          PhoenixKitEcommerce.claim_cart_flag(cart, "first_item_notified")

      cond do
        first? ->
          notify_shop(%{
            action: @cart_first_item_action,
            text:
              "New cart started: #{product_name(product)} ×#{item.quantity} — #{cart_totals(cart)}",
            icon: "hero-shopping-cart",
            link: Routes.path("/admin/shop/carts")
          })

        PhoenixKitEcommerce.notify_event?(:cart_item) ->
          notify_shop(%{
            action: @cart_item_action,
            text:
              "Added to cart: #{product_name(product)} ×#{item.quantity} — #{cart_totals(cart)}",
            icon: "hero-shopping-cart",
            link: Routes.path("/admin/shop/carts")
          })

        true ->
          :ok
      end
    end)
  end

  @assistant_lines_shown 3
  @assistant_title_max 40

  @doc """
  Storefront signal for a cart written through the public cart API: ONE
  message per write call, "via assistant", summarising the lines. Whether to
  send, and the caps, are decided by `PhoenixKitEcommerce.API.Signals`; this
  function words and delivers it to the same audience and under the same two
  actions as the storefront signals, so every recipient's notification
  preferences apply.

  Options: `first?` (the first-item action and wording), `more_carts` (how
  many assistant signals the global cap dropped since the last message).
  """
  @spec assistant_cart_updated(
          map(),
          [%{title: String.t(), quantity: pos_integer()}],
          keyword()
        ) :: :ok
  def assistant_cart_updated(cart, lines, opts \\ []) when is_list(lines) do
    safely(fn ->
      first? = Keyword.get(opts, :first?, false)
      more_carts = Keyword.get(opts, :more_carts, 0)

      lead = if first?, do: "New cart started via assistant", else: "Cart updated via assistant"
      action = if first?, do: @cart_first_item_action, else: @cart_item_action

      notify_shop(%{
        action: action,
        text:
          lead <>
            ": " <>
            assistant_lines(lines) <> assistant_total(cart) <> assistant_more(more_carts),
        icon: "hero-shopping-cart",
        link: Routes.path("/admin/shop/carts")
      })
    end)
  end

  defp assistant_lines(lines) do
    shown =
      lines
      |> Enum.take(@assistant_lines_shown)
      |> Enum.map_join(", ", fn %{title: title, quantity: quantity} ->
        "#{truncate(to_string(title), @assistant_title_max)} ×#{quantity}"
      end)

    hidden = length(lines) - @assistant_lines_shown
    if hidden > 0, do: shown <> " (+#{hidden} more lines)", else: shown
  end

  defp assistant_total(cart) do
    case cart_totals(cart) do
      "" -> ""
      totals -> " — " <> totals
    end
  end

  defp assistant_more(count) when is_integer(count) and count > 0,
    do: " (+#{count} more assistant carts)"

  defp assistant_more(_none), do: ""

  @doc """
  Storefront signal: a buyer reached the checkout page with a valid cart.
  Fires once per cart (atomic claim), only when the toggle is on.
  """
  def checkout_started(cart) do
    safely(fn ->
      if PhoenixKitEcommerce.notify_event?(:checkout_started) and
           PhoenixKitEcommerce.claim_cart_flag(cart, "checkout_notified") do
        notify_shop(%{
          action: @checkout_started_action,
          text: "Checkout started: #{cart.items_count} item(s) — #{cart_totals(cart)}",
          icon: "hero-credit-card",
          link: Routes.path("/admin/shop/carts")
        })
      end
    end)
  end

  @doc """
  Recipients for storefront signals: the configured recipient list
  (`shop_notification_recipients`), or every shop admin when unset/empty.

  Stored as `%{"uuids" => [...]}` rather than a bare list — core's
  `value_json` column casts through an Ecto `:map` field, which rejects a
  top-level list at the changeset.

  The stored list is re-checked against `shop.manage_carts` holders on
  every send, not only when the admin saved it: the setting is a snapshot
  of who was an operator that day, and revoking someone's shop access has
  to stop the cart-activity feed too — those messages carry what visitors
  are shopping for and what their carts are worth. Fails closed, since
  `admin_recipients/1` rescues to `[]`.
  """
  def shop_recipients do
    current_admins = admin_recipients("shop.manage_carts")

    case PhoenixKit.Settings.get_json_setting_cached("shop_notification_recipients", %{}) do
      %{"uuids" => uuids} when is_list(uuids) and uuids != [] ->
        Enum.filter(uuids, &(is_binary(&1) and &1 in current_admins))

      _ ->
        current_admins
    end
  end

  # `create_many/2` never persists `:action` on the notification row itself
  # (core's standalone path only carries text/icon/link through to
  # `metadata`) — so without this, a cart-activity notification would be
  # indistinguishable from any other once written. Stashing it under
  # `metadata["action"]` costs nothing (the column is already an open jsonb
  # bag) and makes the signal auditable/filterable after the fact.
  defp notify_shop(attrs) do
    Notifications.create_many(
      shop_recipients(),
      Map.put(attrs, :metadata, %{"action" => attrs.action})
    )
  end

  # Product has no `:name` field - the display title lives in `:title`, an
  # i18n map (`%{"en" => "..."}`). Reads it through the same fallback chain
  # (exact language -> default language -> first available) storefront
  # pages use, so the notification text shows the same name a shopper saw.
  # The product struct is passed through as-is, not rebuilt into a bare
  # `%{title: ...}` map: `Translations.get/3` is specced on `struct()`, so
  # the rebuilt map broke the contract and failed `mix dialyzer`.
  defp product_name(%{title: title} = product) when is_map(title) and title != %{} do
    Translations.get(product, :title, Translations.default_language()) || "product"
  end

  defp product_name(_), do: "product"

  defp cart_totals(%{subtotal: subtotal, currency: currency}) when not is_nil(subtotal) do
    "#{Decimal.round(subtotal, 2)} #{currency}"
  end

  defp cart_totals(_), do: ""

  defp notify_admins_of_order(order) do
    # A buyer who is also a shop operator stays in the list: the order still
    # needs confirming on the Billing page, and their own "Your order ... is
    # confirmed" message (customer-facing copy, a customer link) does not
    # say so. `admin_recipients/1` only ever holds operators, so a buyer
    # without shop access is not in it.
    recipients = admin_recipients("shop.manage_carts")

    # `metadata["shipping_skipped"]` is stamped by
    # `PhoenixKitEcommerce.build_order_attrs/5` when the order converted
    # without a shipping method under the `:always`/`:fallback` skip modes -
    # the operator still owes this buyer a delivery arrangement, and
    # nothing else in the admin fan-out flags that.
    suffix = if order.metadata["shipping_skipped"], do: " — shipping pending", else: ""

    attrs = %{
      action: @order_action,
      text: "New order #{order.order_number} — #{order_total(order)}#{suffix}",
      icon: "hero-shopping-bag"
    }

    billing_recipients =
      if(Billing.enabled?(), do: admin_recipients("billing"), else: [])
      |> MapSet.new()

    recipients
    |> Enum.group_by(&MapSet.member?(billing_recipients, &1))
    |> Enum.each(fn {billing_access?, recipients} ->
      Notifications.create_many(
        recipients,
        Map.put(attrs, :link, order_admin_link(order, billing_access?))
      )
    end)
  end

  # An order is confirmed on its Billing page, so that is where the operator
  # is sent when they can open it. The same recipient resolver includes
  # Owner and wildcard grants, which have no explicit Billing grant.
  defp order_admin_link(order, true), do: BillingPaths.order_detail(order.uuid)
  defp order_admin_link(_order, false), do: Routes.path("/admin/shop/carts")

  # Only a real, confirmed account gets an in-app notification: guest
  # checkout creates an unconfirmed placeholder user whose channel is the
  # transactional confirmation email, and sending both would double-mail
  # someone who has not even confirmed an address yet.
  defp notify_customer_of_order(%{user_uuid: nil}, _language), do: :ok

  defp notify_customer_of_order(order, language) do
    case Auth.get_user(order.user_uuid) do
      %{confirmed_at: confirmed} = _user when not is_nil(confirmed) ->
        Notifications.create(%{
          recipient_uuid: order.user_uuid,
          action: @customer_order_action,
          text: "Your order #{order.order_number} is confirmed",
          icon: "hero-check-circle",
          link:
            Routes.path("/dashboard/orders/#{order.uuid}",
              locale: PhoenixKitEcommerce.url_locale(buyer_language(language))
            )
        })

      _unconfirmed_or_missing ->
        :ok
    end
  end

  # The language the buyer checked out in: the page's, handed down by the
  # checkout, when the site serves it; the primary language otherwise (a
  # worker or script has no page, and a language the site has not enabled has
  # no URLs). It is the page's own code, never the Gettext locale: the shop's
  # catalogues are a subset of the languages a site can enable, so a buyer in
  # one of the others would read back the shop default there.
  defp buyer_language(language) when is_binary(language) do
    base = DialectMapper.extract_base(language)

    if Languages.enabled?() and base in enabled_bases(),
      do: base,
      else: Translations.default_language()
  end

  defp buyer_language(_language), do: Translations.default_language()

  defp enabled_bases do
    Enum.map(Languages.get_enabled_languages(), &DialectMapper.extract_base(&1.code))
  end

  @doc """
  Notifies the admin who started an import that it finished.

  Job-level only: one message per import carrying aggregate counts, never
  one per row — a 10k-row import must not produce 10k notifications.
  """
  def import_completed(import_log, stats) do
    safely(fn ->
      notify_initiator(import_log, %{
        action: @import_completed_action,
        text: import_summary(import_log, stats),
        icon: "hero-check-circle"
      })
    end)
  end

  @doc """
  Notifies the initiator that an import failed.

  Call ONLY on the terminal attempt: Oban retries a failed job, and
  notifying on every attempt turns one transient failure into three
  alerts followed by a success.
  """
  def import_failed(import_log, reason) do
    safely(fn ->
      notify_initiator(import_log, %{
        action: @import_failed_action,
        text: "Import failed: #{truncate(to_string(reason), 120)}",
        icon: "hero-exclamation-triangle"
      })
    end)
  end

  # Import logs predate the user_uuid column; there is nobody to tell.
  defp notify_initiator(%{user_uuid: nil}, _attrs), do: :ok

  defp notify_initiator(import_log, attrs) do
    Notifications.create(
      Map.merge(attrs, %{
        recipient_uuid: import_log.user_uuid,
        link: Routes.path("/admin/shop/imports/#{import_log.uuid}")
      })
    )
  end

  @doc """
  Everyone who should hear about shop operations: holders of `key`,
  unioned with Owner-role holders and `"*"` superadmins.
  """
  def admin_recipients(key) do
    (Permissions.users_with_permission(key) ++
       Permissions.users_with_permission("*") ++
       Roles.users_with_role("Owner"))
    |> Enum.map(&user_uuid/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  rescue
    error ->
      Logger.warning("[Shop] could not resolve notification recipients: #{inspect(error)}")
      []
  end

  defp user_uuid(%{uuid: uuid}), do: uuid
  defp user_uuid(%{user_uuid: uuid}), do: uuid
  defp user_uuid(uuid) when is_binary(uuid), do: uuid
  defp user_uuid(_), do: nil

  defp order_total(%{total: total, currency: currency}) when not is_nil(total) do
    "#{Decimal.round(total, 2)} #{currency}"
  end

  defp order_total(_), do: ""

  defp import_summary(import_log, stats) when is_map(stats) do
    created = Map.get(stats, :created) || Map.get(stats, "created") || 0
    updated = Map.get(stats, :updated) || Map.get(stats, "updated") || 0
    failed = Map.get(stats, :failed) || Map.get(stats, "failed") || 0

    "Import finished: #{created} created, #{updated} updated, #{failed} failed" <>
      import_name(import_log)
  end

  defp import_summary(import_log, _stats), do: "Import finished" <> import_name(import_log)

  defp import_name(%{filename: name}) when is_binary(name) and name != "", do: " (#{name})"
  defp import_name(_), do: ""

  # Cut on GRAPHEMES, not bytes. `binary_part/3` splits mid-character on any
  # multi-byte text — and an import failure reason routinely carries the
  # product title that caused it, which on a Cyrillic catalogue is entirely
  # multi-byte. The invalid string that produced is rejected by Postgres, so
  # `safely/1` swallowed the insert and the failure notification never
  # arrived: silence exactly when the operator most needs to hear.
  defp truncate(text, max) when byte_size(text) > max do
    String.slice(text, 0, max) <> "…"
  end

  defp truncate(text, _max), do: text

  # A notification must never take down the thing it is reporting on.
  defp safely(fun) do
    fun.()
    :ok
  rescue
    error ->
      Logger.warning("[Shop] notification failed: #{inspect(error)}")
      :ok
  catch
    kind, value ->
      Logger.warning("[Shop] notification failed: #{inspect(kind)} #{inspect(value)}")
      :ok
  end
end
