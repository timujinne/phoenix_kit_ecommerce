defmodule PhoenixKitEcommerce.Test.Hooks do
  @moduledoc """
  `on_mount` hooks used by the LiveView test endpoint.

  Production runs LiveViews inside `live_session :phoenix_kit_admin`,
  which is configured by core `phoenix_kit` to populate
  `socket.assigns[:phoenix_kit_current_scope]` and
  `socket.assigns[:phoenix_kit_current_user]` from the host app's
  authentication. Our test endpoint doesn't load core's hooks, so this
  module replicates the same effect by pulling scope data from the
  test session.

  Tests set scope via `LiveCase.put_test_scope/2` (which calls
  `Plug.Test.init_test_session/2`); the `:assign_scope` hook below
  reads it back and mirrors it onto socket assigns.
  """

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKitBilling.Currency

  @doc """
  `on_mount` callback. Reads `"phoenix_kit_test_scope"` from session and
  assigns `:phoenix_kit_current_scope` / `:phoenix_kit_current_user`
  onto the socket. No-op when session has no scope (LiveView mounts
  with the same nil-scope state production sees for logged-out users).
  """
  def on_mount(:assign_scope, _params, session, socket) do
    case Map.get(session, "phoenix_kit_test_scope") do
      nil ->
        # Production's `phoenix_kit_mount_current_scope` ALWAYS assigns a
        # scope — an anonymous one for logged-out visitors — so mirror that
        # rather than leaving the key absent (layouts read it on every page).
        socket =
          socket
          |> assign(:phoenix_kit_current_scope, Scope.for_user(nil))
          |> assign(:phoenix_kit_current_user, nil)

        {:cont, socket}

      %{user: user} = scope ->
        socket =
          socket
          |> assign(:phoenix_kit_current_scope, scope)
          |> assign(:phoenix_kit_current_user, user)

        {:cont, socket}
    end
  end

  # `on_mount` callback standing in for the HOST's own domain-currency hook
  # (Э1-A2, e.g. `Decor3dprintWeb.DomainCurrencyHook`) — production sets the
  # request-scoped display currency from the visitor's domain; this test
  # double sets it from `"phoenix_kit_test_currency"` in the session instead,
  # via `LiveCase.put_test_currency/2`. No-op (falls through to the base
  # currency, same as an unmapped domain) when the session carries no code.
  def on_mount(:assign_currency, _params, session, socket) do
    Currency.put_request_currency(Map.get(session, "phoenix_kit_test_currency"))

    {:cont, socket}
  end
end
