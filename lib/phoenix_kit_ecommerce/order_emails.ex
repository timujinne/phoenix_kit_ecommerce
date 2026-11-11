defmodule PhoenixKitEcommerce.OrderEmails do
  @moduledoc """
  The emails a shop order sends: the buyer's confirmation, the buyer's paid
  email, and the detailed email to the shop's own addresses.

  ## When

  | Moment | Buyer | Shop |
  |---|---|---|
  | placed, not awaiting online payment | `shop_order_confirmation` | `shop_order_received` |
  | placed, awaiting online payment | nothing | nothing |
  | paid | `shop_order_paid` | `shop_order_received`, unless already sent |

  An online order's emails wait until the money lands. The in-app admin
  notification still goes immediately through
  `PhoenixKitEcommerce.Notifications.order_placed/2`.

  ## Delivery

  Each email is one `Workers.OrderEmailWorker` job. The order's are queued in the
  transaction that creates it and the paid ones by billing's durable order event
  (`PhoenixKitEcommerce.OrderEmailHandler`), so no mail server is ever waited for
  at the checkout and a failure retries on its own.

  Once per order: a job is unique per order and email, and a sent email is marked
  in `metadata["_shop_emails"]`, which outlives the job row and changes neither
  the order's revision nor `updated_at`. A delivery first claims the email under
  the order's row lock, reading the stored mark and status there, and commits
  the claim before it sends. Cancelled and refunded orders send nothing. A second
  delivery that finds a claim sends nothing and answers `{:snooze, seconds}`, so
  overlapping deliveries cannot both send. A send that fails gives its claim
  back.

  The mail goes outside any transaction of this module, on purpose: an email
  provider writes its log on the same connection and keeps its errors to itself,
  and a failed statement inside a transaction would abort it, so the mail would
  go and the mark could not be written.

  The mark is written after the send, so a crash between the two can repeat an
  email; it cannot lose one. The claim of a delivery that died is good for five
  minutes, then the next delivery sends. The copy of a buyer's email has a mark
  of its own (`"buyer_placed_copy"`), so a copy that fails is retried without
  mailing the buyer again.

  ## Who

  The buyer is the address on the order, in the language of the checkout
  (`metadata["checkout_language"]`), and `buyer_emails_enabled?/0` can turn these
  off. The link to the order is the account page for a confirmed buyer. A guest
  has no account, and under the default `:strict` lookup policy the order page
  opens only in the session that placed the order, so a guest's email carries the
  link only under `:link`.

  Each buyer email that goes is also sent, as it is, to `copy_recipients/0`: the
  same template, language and link, with replies going to the buyer. It is a
  message of its own rather than a `Bcc:` (core's template sender takes none),
  and it goes only when the buyer's does.

  The shop's addresses are `shop_recipients/0`, in `shop_email_language/0` (the
  site's primary language unless one is chosen); with none, nothing is sent.
  Per-user notification preferences play no part.
  """

  import Ecto.Query, only: [from: 2]
  import PhoenixKit.RepoHelper, only: [repo: 0]

  require Logger

  alias PhoenixKit.Mailer
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Notifications
  alias PhoenixKitEcommerce.OnlinePayment
  alias PhoenixKitEcommerce.OrderEmailDefaults
  alias PhoenixKitEcommerce.Policy
  alias PhoenixKitEcommerce.Translations
  alias PhoenixKitEcommerce.Workers.OrderEmailWorker

  @emails %{
    "buyer_placed" => "shop_order_confirmation",
    "buyer_paid" => "shop_order_paid",
    "shop" => "shop_order_received"
  }

  @sent_key "_shop_emails"
  @claimed_key "claimed_at"
  @claim_seconds 300
  @buyer_setting "shop_order_emails_to_buyer"
  @recipients_setting "shop_order_email_recipients"
  @copy_setting "shop_order_email_copy_recipients"
  @language_setting "shop_order_email_language"
  @address ~r/\A[^\s@,;]+@[^\s@,;]+\.[^\s@,;]+\z/

  @doc """
  Queues the emails of an order just placed. Call it in the transaction that
  creates the order, so the jobs commit with it. An Oban that is not running is
  logged and never fails the checkout.
  """
  @spec order_placed(map()) :: :ok
  def order_placed(order) do
    if OnlinePayment.awaiting?(order), do: :ok, else: enqueue(order, ~w(buyer_placed shop))
  rescue
    error in [ArgumentError, RuntimeError] ->
      Logger.error(
        "[Shop] emails of order #{order.order_number} not queued: #{Exception.message(error)}"
      )

      :ok
  end

  @doc "Queues the emails of an order that became paid."
  @spec order_paid(map()) :: :ok
  def order_paid(order), do: enqueue(order, ~w(buyer_paid shop))

  defp enqueue(order, emails) do
    Enum.each(emails, fn email ->
      %{"order_uuid" => order.uuid, "email" => email}
      |> OrderEmailWorker.new()
      |> Oban.insert!()
    end)
  end

  @doc """
  Sends one email of `order` (`"buyer_placed"`, `"buyer_paid"` or `"shop"`), and
  a buyer email's copy, unless it was sent already or has nobody to go to.
  Returns `{:error, reason}` for the job to retry; an email that went is marked.
  `{:snooze, seconds}` means another delivery holds the email: nothing was sent,
  and that many seconds later its claim has run out.
  """
  @spec deliver(String.t(), map()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def deliver("shop", order) do
    case shop_recipients() do
      [] -> :ok
      recipients -> once(order, "shop", fn -> send_to_shop(order, recipients) end)
    end
  end

  def deliver(email, order) when is_map_key(@emails, email) do
    case buyer_emails_enabled?() && buyer_address(order) do
      address when is_binary(address) -> deliver_to_buyer(email, order, address)
      _off_or_nobody -> :ok
    end
  end

  defp deliver_to_buyer(email, order, address) do
    language = Notifications.buyer_language(order.metadata["checkout_language"])
    url = order_url(order, language)

    with :ok <- once(order, email, fn -> send_to_buyer(email, order, address, language, url) end) do
      send_copy(email, order, address, language, url)
    end
  end

  defp once(order, mark, send) do
    case claim(order.uuid, mark) do
      {:claimed, claimed_at} -> send_claimed(order.uuid, mark, claimed_at, send)
      :done -> :ok
      {:busy, seconds} -> {:snooze, seconds}
    end
  end

  defp send_claimed(order_uuid, mark, claimed_at, send) do
    result =
      try do
        send.()
      catch
        kind, reason ->
          release(order_uuid, mark, claimed_at)
          :erlang.raise(kind, reason, __STACKTRACE__)
      end

    case result do
      :ok ->
        mark_sent(order_uuid, mark)

      {:error, reason} ->
        release(order_uuid, mark, claimed_at)
        {:error, reason}
    end
  end

  # The stored order decides, not the caller's copy of it: the mark may have
  # been written, or the order cancelled, since that copy was read.
  defp claim(order_uuid, mark) do
    now = System.os_time(:second)

    update_marks(order_uuid, fn order, marks ->
      wait = seconds_left(marks[mark], now)

      cond do
        order.status in ~w(cancelled refunded) or marks[mark] == true -> :done
        wait > 0 -> {:busy, wait}
        true -> {:store, Map.put(marks, mark, %{@claimed_key => now}), {:claimed, now}}
      end
    end)
  end

  # A claim from a clock ahead of this one is held for no longer than a claim
  # made now would be.
  defp seconds_left(%{@claimed_key => claimed_at}, now) when is_integer(claimed_at),
    do: (claimed_at + @claim_seconds - now) |> max(0) |> min(@claim_seconds)

  defp seconds_left(_no_claim, _now), do: 0

  # Only its own claim: one that outlived its time may belong to the delivery
  # that took over.
  defp release(order_uuid, mark, claimed_at) do
    update_marks(order_uuid, fn _order, marks ->
      case marks[mark] do
        %{@claimed_key => ^claimed_at} -> {:store, Map.delete(marks, mark), :ok}
        _not_ours -> :ok
      end
    end)
  end

  defp mark_sent(order_uuid, mark) do
    update_marks(order_uuid, fn _order, marks -> {:store, Map.put(marks, mark, true), :ok} end)
  end

  # Reads the marks of the order under its row lock. `fun` answers
  # `{:store, marks, result}` to write them, or its result alone.
  defp update_marks(order_uuid, fun) do
    {:ok, result} =
      repo().transaction(fn ->
        order =
          repo().one!(from(o in Billing.Order, where: o.uuid == ^order_uuid, lock: "FOR UPDATE"))

        metadata = order.metadata || %{}

        case fun.(order, metadata[@sent_key] || %{}) do
          {:store, marks, result} ->
            store_marks(order_uuid, metadata, marks)
            result

          result ->
            result
        end
      end)

    result
  end

  defp store_marks(order_uuid, metadata, marks) do
    metadata =
      if marks == %{},
        do: Map.delete(metadata, @sent_key),
        else: Map.put(metadata, @sent_key, marks)

    repo().update_all(from(o in Billing.Order, where: o.uuid == ^order_uuid),
      set: [metadata: metadata]
    )
  end

  defp send_to_buyer(email, order, address, language, url) do
    deliver_template(email, order, address, language, url, user_uuid: order.user_uuid)
  end

  # The buyer's email as the buyer got it, for the shop to read: replies go to
  # the buyer, and it is tracked against no account.
  defp send_copy(email, order, buyer, language, url) do
    case copy_recipients() do
      [] ->
        :ok

      recipients ->
        once(order, email <> "_copy", fn ->
          deliver_template(email, order, recipients, language, url, reply_to: buyer)
        end)
    end
  end

  defp send_to_shop(order, recipients) do
    reply_to = get_in(order.billing_snapshot || %{}, ["email"])

    deliver_template("shop", order, recipients, shop_email_language(), nil,
      reply_to: if(is_binary(reply_to) and reply_to != "", do: reply_to)
    )
  end

  defp deliver_template(email, order, to, language, order_url, opts) do
    template = Map.fetch!(@emails, email)
    locale = base_locale(language)

    variables =
      Gettext.with_locale(PhoenixKitEcommerce.Gettext, locale, fn ->
        OrderEmailDefaults.variables(order, order_url)
      end)

    defaults = OrderEmailDefaults.defaults_for(template, variables)

    result =
      Mailer.send_from_template(
        template,
        to,
        variables,
        [
          locale: language,
          defaults: fn -> Gettext.with_locale(PhoenixKitEcommerce.Gettext, locale, defaults) end,
          layout: OrderEmailDefaults.layout_group(),
          metadata: %{order_uuid: order.uuid}
        ] ++ opts
      )

    case result do
      {:ok, _delivered} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp base_locale(language),
    do: language |> String.split(["-", "_"]) |> hd() |> String.downcase()

  defp buyer_address(order) do
    case order.billing_snapshot do
      %{"email" => email} when is_binary(email) and email != "" -> email
      _no_email -> account_email(order)
    end
  end

  defp account_email(%{user_uuid: uuid}) when is_binary(uuid) do
    case Auth.get_user(uuid) do
      %{email: email} -> email
      nil -> nil
    end
  end

  defp account_email(_order), do: nil

  defp order_url(order, language) do
    cond do
      confirmed_account?(order) ->
        absolute("/dashboard/orders/#{order.uuid}", language)

      Policy.order_lookup_policy() == :link ->
        absolute("/checkout/complete/#{order.uuid}", language)

      true ->
        nil
    end
  end

  defp confirmed_account?(%{user_uuid: uuid}) when is_binary(uuid),
    do: match?(%{confirmed_at: %DateTime{}}, Auth.get_user(uuid))

  defp confirmed_account?(_order), do: false

  defp absolute(path, language) do
    built = Routes.path(path, locale: Shop.url_locale(language))
    Routes.canonical_absolute_or_nil(built, language) || Routes.base_url() <> built
  end

  # -- settings ---------------------------------------------------------------

  @doc "Whether buyers get the order emails. On by default; a read error counts as off."
  @spec buyer_emails_enabled?() :: boolean()
  def buyer_emails_enabled? do
    Settings.get_setting_cached(@buyer_setting, "true") == "true"
  rescue
    _ -> false
  end

  @doc "Turns the buyer's order emails on or off."
  @spec set_buyer_emails_enabled(boolean()) :: {:ok, boolean()} | {:error, :update_failed}
  def set_buyer_emails_enabled(enabled) when is_boolean(enabled) do
    case Settings.update_boolean_setting_with_module(@buyer_setting, enabled, "shop") do
      {:ok, _} -> {:ok, enabled}
      _error -> {:error, :update_failed}
    end
  end

  @doc """
  The addresses that get the shop's order email. A stored value that is not an
  address is left out, and a read error counts as none.
  """
  @spec shop_recipients() :: [String.t()]
  def shop_recipients do
    @recipients_setting
    |> Settings.get_setting_cached("")
    |> split_addresses()
    |> Enum.filter(&Regex.match?(@address, &1))
  rescue
    _ -> []
  end

  @doc """
  Stores the shop's addresses from what a person typed: separated by commas,
  semicolons, spaces or new lines. Nothing is stored if one of them is not an
  address.
  """
  @spec set_shop_recipients(String.t()) ::
          {:ok, [String.t()]}
          | {:error, {:invalid_order_email_addresses, [String.t()]} | :update_failed}
  def set_shop_recipients(text) when is_binary(text) do
    addresses = text |> split_addresses() |> Enum.uniq()

    case Enum.reject(addresses, &Regex.match?(@address, &1)) do
      [] -> store_recipients(addresses)
      invalid -> {:error, {:invalid_order_email_addresses, invalid}}
    end
  end

  @doc """
  The addresses that get a copy of each email sent to a buyer. Read like
  `shop_recipients/0`.
  """
  @spec copy_recipients() :: [String.t()]
  def copy_recipients do
    @copy_setting
    |> Settings.get_setting_cached("")
    |> split_addresses()
    |> Enum.filter(&Regex.match?(@address, &1))
  rescue
    _ -> []
  end

  @doc "Stores the addresses for the copies, as `set_shop_recipients/1` does."
  @spec set_copy_recipients(String.t()) ::
          {:ok, [String.t()]}
          | {:error, {:invalid_order_email_addresses, [String.t()]} | :update_failed}
  def set_copy_recipients(text) when is_binary(text) do
    addresses = text |> split_addresses() |> Enum.uniq()

    case Enum.reject(addresses, &Regex.match?(@address, &1)) do
      [] -> store_addresses(@copy_setting, addresses)
      invalid -> {:error, {:invalid_order_email_addresses, invalid}}
    end
  end

  defp store_recipients(addresses), do: store_addresses(@recipients_setting, addresses)

  defp store_addresses(key, addresses) do
    value = Enum.join(addresses, ", ")

    case Settings.update_setting_with_module(key, value, "shop") do
      {:ok, _} -> {:ok, addresses}
      _error -> {:error, :update_failed}
    end
  end

  @doc """
  The language of the shop's email: the one chosen for it while the site still
  serves it, the site's primary language otherwise. A read error counts as
  nothing chosen.
  """
  @spec shop_email_language() :: String.t()
  def shop_email_language do
    Notifications.buyer_language(chosen_shop_email_language())
  end

  @doc "The language chosen for the shop's email, `nil` for the site's primary language."
  @spec chosen_shop_email_language() :: String.t() | nil
  def chosen_shop_email_language do
    case Settings.get_setting_cached(@language_setting, "") do
      code when is_binary(code) and code != "" -> code
      _none -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  Chooses the language of the shop's email: one the site serves, or `""` for
  the site's primary language.
  """
  @spec set_shop_email_language(String.t()) ::
          {:ok, String.t() | nil} | {:error, :unsupported_language | :update_failed}
  def set_shop_email_language(code) when is_binary(code) do
    code = String.trim(code)

    cond do
      code != "" and code not in Translations.enabled_languages() ->
        {:error, :unsupported_language}

      match?({:ok, _}, Settings.update_setting_with_module(@language_setting, code, "shop")) ->
        {:ok, if(code == "", do: nil, else: code)}

      true ->
        {:error, :update_failed}
    end
  end

  defp split_addresses(text) when is_binary(text),
    do: String.split(text, [",", ";", " ", "\n", "\r", "\t"], trim: true)

  defp split_addresses(_other), do: []
end
