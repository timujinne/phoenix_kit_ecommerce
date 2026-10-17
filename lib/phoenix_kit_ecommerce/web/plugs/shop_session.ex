defmodule PhoenixKitEcommerce.Web.Plugs.ShopSession do
  @moduledoc """
  Plug that ensures a persistent shop session ID exists.

  This plug generates a unique session ID for guest users and stores it
  both in a dedicated cookie AND in the Phoenix session. This ensures
  the same cart is used across different pages.
  """

  import Plug.Conn

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Policy

  @cookie_name "shop_session_id"
  # 30 days
  @cookie_max_age 60 * 60 * 24 * 30

  def init(opts), do: opts

  def call(conn, _opts) do
    if Shop.enabled?() do
      establish_session(conn)
    else
      # A disabled shop must not MINT new cart identities - but it must
      # still recognise an existing signed one. The order-confirmation page
      # is deliberately reachable while disabled (it is a receipt), and it
      # authorizes on this session's provenance; going fully inert here
      # locked returning guests out of their own receipts once the Phoenix
      # session expired but their 30-day signed cookie had not.
      case get_shop_session_id(conn) do
        {:signed, existing_id} -> put_shop_session(conn, existing_id, true)
        _ -> conn
      end
    end
  end

  defp establish_session(conn) do
    case get_shop_session_id(conn) do
      {:signed, existing_id} ->
        put_shop_session(conn, existing_id, true)

      {:legacy, legacy_id} ->
        # Migrate the CART onto a freshly minted id rather than re-signing
        # the value the client supplied.
        #
        # Re-signing was the flaw: on the next request the attacker's own
        # value came back as `{:signed, _}` and was fully trusted, so the
        # untrusted marking only DELAYED the capability by one request
        # instead of removing it. Minting a new id and re-keying the cart
        # means a replayed value can never become a trusted session — the
        # replayer gets an id that was never theirs to present, and the
        # legitimate visitor keeps their cart.
        # A failed re-key is not an error worth surfacing: the visitor
        # simply starts a new cart, which is what they would have got
        # without the migration at all.
        new_id = generate_session_id()
        _ = Shop.rekey_cart_session(legacy_id, new_id)

        conn
        |> put_resp_cookie(@cookie_name, new_id, cookie_opts(conn))
        |> put_shop_session(new_id, true)

      nil ->
        new_id = generate_session_id()

        conn
        |> put_resp_cookie(@cookie_name, new_id, cookie_opts(conn))
        |> put_shop_session(new_id, true)
    end
  end

  # Records the id AND where it came from.
  #
  # Provenance matters because this value does two different jobs. As a CART
  # identity, adopting an unsigned legacy cookie is fine — the worst case is
  # picking up a cart. As proof of ORDER ownership it is a capability, and an
  # unsigned value is replayable: anyone who obtains a real session id
  # out-of-band (a shared machine, a log, a Referer header) could present it
  # unsigned and read the victim's confirmation page. That is precisely what
  # signing was added to prevent, so `trusted` is false for the adopted case
  # and `PhoenixKitEcommerce.Web.CheckoutComplete` requires it to be true.
  #
  # The cost is one request: adoption re-issues the cookie signed, so the
  # visitor's NEXT request is trusted. Only a pre-upgrade order viewed on the
  # very first request after upgrading is affected.
  defp put_shop_session(conn, session_id, trusted?) do
    conn
    |> put_session("shop_session_id", session_id)
    |> put_session("shop_session_trusted", trusted?)
  end

  # This cookie is a cart identity, and since orders are now recognised by
  # the session that placed them (see `Policy.order_lookup_policy/0`) it is
  # also what proves "I am the guest who just checked out". It is therefore
  # signed: unsigned, a forged value picked up someone else's guest cart.
  #
  # `same_site: "Lax"` keeps it off cross-site requests, and `secure:` is
  # set whenever the request arrived over HTTPS — conditional rather than
  # hardcoded so plain-HTTP local development still gets a working cart.
  defp cookie_opts(conn) do
    [
      max_age: @cookie_max_age,
      http_only: true,
      same_site: "Lax",
      secure: conn.scheme == :https,
      sign: true
    ]
  end

  # Resolution order: signed cookie, Phoenix session, then the one-time
  # legacy-cookie migration.
  #
  # Returns `{:signed, id}` for a trusted value, `{:legacy, id}` for one
  # adopted from a pre-signing cookie (the caller re-issues it signed), or
  # nil to mint a fresh identity.
  defp get_shop_session_id(conn) do
    signed_conn = fetch_cookies(conn, signed: [@cookie_name])

    cond do
      value = signed_conn.cookies[@cookie_name] ->
        {:signed, value}

      value = get_session(conn, "shop_session_id") ->
        {:signed, value}

      true ->
        adopt_legacy_cookie(conn)
    end
  end

  # Migration for cookies written before this one was signed.
  #
  # `fetch_cookies/2` silently DROPS a value that fails verification, so
  # without this every existing guest would lose their in-progress cart the
  # moment the shop upgraded — a real break for every deployed store, not a
  # theoretical one.
  #
  # Three things keep this narrow, because an unsigned value is replayable
  # by anyone who obtains one out-of-band, and this cookie now also proves
  # guest ORDER ownership — blindly trusting any unsigned string would hand
  # over exactly the capability signing was added to protect:
  #
  #   1. It must name a LIVE GUEST cart — active, unclaimed by any account
  #      (`Shop.session_has_cart?/1`). A guessed value matches nothing; a
  #      real session id is 32 crypto-random bytes.
  #   2. It never authorizes an order. Adopted ids are marked untrusted,
  #      and `CheckoutComplete` requires a trusted one.
  #   3. It expires. `Policy.legacy_cookie_window_open?/0` closes the door
  #      on a configured date. This is load-bearing: only abandoned `api:`
  #      carts are deleted (after 30 days) and browser carts stay
  #      (`mark_abandoned_carts/1` only flips a status and is wired to no
  #      cron), so without a cutoff the criterion in (1) would stay
  #      satisfiable indefinitely and the window would never self-close.
  #
  # Legacy visitors with a cookie but no live cart lose nothing by being
  # issued a fresh id.
  defp adopt_legacy_cookie(conn) do
    conn = fetch_cookies(conn)

    with true <- Policy.legacy_cookie_window_open?(),
         raw when is_binary(raw) <- conn.cookies[@cookie_name],
         true <- plausible_session_id?(raw),
         true <- Shop.session_has_cart?(raw) do
      {:legacy, raw}
    else
      _ -> nil
    end
  end

  # Shape check before touching the database, so junk cookies cost nothing.
  # `generate_session_id/0` emits 32 random bytes as unpadded base64url.
  defp plausible_session_id?(value) do
    byte_size(value) == 43 and value =~ ~r/^[A-Za-z0-9_-]+$/
  end

  defp generate_session_id do
    :crypto.strong_rand_bytes(32) |> Base.url_encode64(padding: false)
  end
end
