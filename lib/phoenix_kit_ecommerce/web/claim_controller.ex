defmodule PhoenixKitEcommerce.Web.ClaimController do
  @moduledoc """
  The checkout claim page of the public cart API.

  GET shows the interstitial and consumes nothing (link-preview bots only ever
  GET); POST, through the browser pipeline's CSRF check, consumes the claim
  once. A POST has three destinations. Success goes to checkout. A choice that
  has gone stale (the browser's cart changed since the page was shown, or a
  deadlock victim) goes back to the claim page with a notice, to choose again.
  Every other dead end (unknown, used, superseded or expired link, a cart that
  is gone, an unexpected refusal) goes to the cart page with a notice, never an
  error page; a shop that is switched off goes to the host's root. One failure is outside this controller: a POST whose CSRF token no
  longer matches (the session expired between the page and the click) is refused
  by the host's browser pipeline before the action runs, with the host's own
  error page; the claim is not consumed and opening the link again works. See
  `PhoenixKitEcommerce.API.Claims` for what a POST does to the carts.
  """

  use PhoenixKitEcommerce.Web, :controller

  # The web analytics module is optional: the claim page marks itself as
  # not-to-be-tracked only when the installed version has the API for it.
  @compile {:no_warn_undefined, PhoenixKitWebAnalytics.Plug}

  require Logger

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.Web.ClaimHTML
  alias PhoenixKitEcommerce.Web.Helpers

  plug :put_view, html: ClaimHTML
  plug :privacy_headers
  plug :skip_analytics

  @dead_ends [:invalid, :used, :superseded, :expired, :cart_unavailable]
  @notice_titles 5
  @notice_title_length 60

  @doc "GET: the interstitial. Reads only."
  def show(conn, %{"token" => token}) do
    case browser(conn) do
      :closed -> shop_closed(conn)
      {:ok, browser} -> show_claim(conn, token, browser)
    end
  end

  @doc "POST: consumes the claim for this browser."
  def create(conn, %{"token" => token} = params) do
    case browser(conn) do
      :closed -> shop_closed(conn)
      {:ok, browser} -> redeem(conn, token, browser, params)
    end
  end

  defp show_claim(conn, token, browser) do
    case Claims.peek(token) do
      {:ok, %{claim: claim, cart: cart}} ->
        put_locale(claim.language)

        conn
        |> assign(:content_language, claim.language)
        |> render(:interstitial,
          cart: cart,
          options: CartView.labelled_options(cart, claim.language),
          existing: existing_cart(browser),
          action: Claims.path(token),
          revision: CartView.revision(cart),
          page_title: gettext("An assistant prepared this cart for you")
        )

      {:error, _reason} ->
        unavailable(conn, Claims.language_of(token))
    end
  end

  defp redeem(conn, token, browser, params) do
    # A browser always sends the revision (the page carries it); a missing or
    # malformed one becomes "", which matches no cart and shows the page again.
    decision = %{
      offer: text(params["offer"]),
      choice: choice(params["choice"]),
      revision: text(params["revision"])
    }

    redeem_reply(conn, token, Claims.redeem(token, browser, decision))
  end

  # The answer to a POST for every result `Claims.redeem/3` can give, the
  # unexpected ones included.
  @doc false
  def redeem_reply(conn, token, result) do
    case result do
      {:ok, %{language: language, skipped: skipped}} ->
        put_locale(language)

        conn
        |> skipped_notice(skipped)
        |> redirect(to: Shop.checkout_url(language))

      # The browser's cart changed since the page was shown: show the choice again.
      {:error, :reshow} ->
        put_locale(Claims.language_of(token))

        conn
        |> put_flash(
          :info,
          gettext("Your cart changed while you were deciding. Please choose again.")
        )
        |> redirect(to: Claims.path(token))

      # Postgres aborted this POST as a deadlock victim against a storefront add in another
      # tab (see `Claims.redeem/3`); nothing was claimed and the cart did not change. The
      # page is shown again so the buyer can try again.
      {:error, :busy} ->
        put_locale(Claims.language_of(token))

        conn
        |> put_flash(:error, gettext("Something went wrong. Your cart was not changed."))
        |> redirect(to: Claims.path(token))

      {:error, reason} when reason in @dead_ends ->
        unavailable(conn, Claims.language_of(token))

      # Not a refusal the claim flow is known to make: fail closed. Only the
      # atom is logged, never the token or any other term.
      {:error, reason} ->
        Logger.warning("[PhoenixKitEcommerce] claim redeem refused: #{log_reason(reason)}")
        failed(conn, Claims.language_of(token))
    end
  end

  defp failed(conn, language) do
    language = language || Shop.get_default_language()
    put_locale(language)

    conn
    |> put_flash(:error, gettext("Something went wrong. Your cart was not changed."))
    |> redirect(to: Shop.cart_url(language))
  end

  defp log_reason(reason) when is_atom(reason), do: inspect(reason)
  defp log_reason(_other), do: "not an atom"

  # The browser's identity: the shop session the shop-session plug put into the
  # Phoenix session, and the logged-in user core's auto-setup pipeline assigned.
  defp browser(conn) do
    session_id = get_session(conn, "shop_session_id")

    if Shop.enabled?() and is_binary(session_id) and session_id != "" do
      {:ok, %{session_id: session_id, user_uuid: user_uuid(conn)}}
    else
      :closed
    end
  end

  defp user_uuid(conn) do
    case conn.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  # The browser's cart with lines, as `Claims.redeem/3` will find it, else nil.
  defp existing_cart(browser) do
    case Claims.browser_cart(browser) do
      %{items: [_ | _]} = cart -> cart
      _none_or_empty -> nil
    end
  end

  defp shop_closed(conn) do
    # The process keeps the previous request's locale: use the shop's default.
    put_locale(nil)

    # The HOST's root, not Routes.path("/"), like the cart page does.
    conn
    |> put_flash(:error, gettext("The shop is currently unavailable"))
    |> redirect(to: "/")
  end

  defp unavailable(conn, language) do
    language = language || Shop.get_default_language()
    put_locale(language)

    conn
    |> put_flash(
      :info,
      gettext("This checkout link has already been used or has expired. Your cart is shown here.")
    )
    |> redirect(to: Shop.cart_url(language))
  end

  defp skipped_notice(conn, []), do: conn

  defp skipped_notice(conn, titles) do
    titles = Enum.map(titles, &NamePrefix.strip/1)

    put_flash(
      conn,
      :error,
      gettext("Some items could not be added because they are no longer available: %{items}",
        items: skipped_list(titles)
      )
    )
  end

  # The notice travels in the cookie-backed session, whose whole value is capped
  # at 4096 bytes, and a cart holds up to 50 lines with titles of any length:
  # name a few, cut long titles, and end with an ellipsis when there are more.
  defp skipped_list(titles) do
    shown = titles |> Enum.take(@notice_titles) |> Enum.map_join(", ", &shorten/1)

    if length(titles) > @notice_titles, do: shown <> ", \u2026", else: shown
  end

  defp shorten(title) do
    title = to_string(title)

    if String.length(title) > @notice_title_length,
      do: String.slice(title, 0, @notice_title_length - 1) <> "\u2026",
      else: title
  end

  defp text(value) when is_binary(value), do: value
  defp text(_other), do: ""

  defp choice(value) when value in ["replace", "add"], do: value
  defp choice(_other), do: nil

  defp put_locale(language),
    do: Helpers.put_content_locale(language || Shop.get_default_language())

  # The claim token is a credential: the page must not be recorded as a page
  # view whatever `web_analytics_exclude_paths` holds (the V5 migration step
  # adds the claim path to it, but only when the analytics tables existed at
  # that moment).
  defp skip_analytics(conn, _opts) do
    if Code.ensure_loaded?(PhoenixKitWebAnalytics.Plug) and
         function_exported?(PhoenixKitWebAnalytics.Plug, :skip, 1),
       do: PhoenixKitWebAnalytics.Plug.skip(conn),
       else: conn
  end

  defp privacy_headers(conn, _opts) do
    conn
    |> put_resp_header("referrer-policy", "no-referrer")
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
  end
end
