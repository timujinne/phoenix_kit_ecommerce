defmodule PhoenixKitEcommerce.Web.Authz do
  @moduledoc """
  Sub-permission checks for the bundled admin LiveViews.

  Core's route gate admits anyone holding the base `"shop"` key (or a sub,
  which implies the base). That is the right granularity for *reaching* the
  admin area, but not for acting inside it: a catalog editor should not be
  able to rewrite the security policy, and someone who only runs imports
  should not be reading customer contact details out of carts.

  Every mutating event handler in this module's admin LiveViews therefore
  re-checks the specific capability it needs, and the pages that display
  customer data check on mount.

  ## Scope of enforcement

  This is **bundled-UI policy**, and deliberately so. The public context API
  (`PhoenixKitEcommerce.create_product/1` and friends, including the
  `compat/shop.ex` re-exports) stays scope-less: it is a library, hosts call
  it from their own controllers, workers and scripts, and it cannot know
  whose authority those run under. Core says the same — sub-permissions are
  capabilities the module checks itself. Where a context function guards
  *ownership* (billing profiles, cart sessions) it keeps doing so
  regardless; those are invariants, not UI policy.

  Background jobs are authorized at ENQUEUE time by the LiveView that
  starts them; the workers themselves run without a scope by design.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Utils.Routes

  @doc """
  True when the socket's scope holds the given shop capability.

  Fails closed: an absent or malformed scope is not authorized.
  """
  def can?(socket, capability) when is_atom(capability) or is_binary(capability) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> false
      scope -> Scope.can?(scope, "shop.#{capability}")
    end
  rescue
    _ -> false
  end

  @doc """
  True when the socket's scope holds core's `api` permission, the one that
  manages API keys. It is opt-in: core does not grant it to the Admin role.
  Changing the price-change confirmation threshold takes it on top of
  `shop.manage_settings`, because the threshold decides what an API key may
  do without a confirmation.

  Fails closed: an absent or malformed scope is not authorized.
  """
  def can_manage_api?(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      nil -> false
      scope -> Scope.can?(scope, "api")
    end
  rescue
    _ -> false
  end

  @doc """
  Runs `fun` when the scope holds `capability`, otherwise returns the
  socket with a denial flash and no side effect.

  `fun` returns the usual `{:noreply, socket}` (or `{:ok, socket}` for a
  mount-time guard — whatever the caller's contract is).
  """
  def authorize(socket, capability, fun) when is_function(fun, 0) do
    if can?(socket, capability) do
      fun.()
    else
      {:noreply, deny(socket)}
    end
  end

  @doc """
  Mount-time guard for pages whose mere CONTENT is privileged (carts carry
  customer contact details). Redirects to the shop admin dashboard.
  """
  def authorize_mount(socket, capability, fun) when is_function(fun, 0) do
    if can?(socket, capability) do
      fun.()
    else
      {:ok,
       socket
       |> Phoenix.LiveView.put_flash(:error, denial_message())
       |> Phoenix.LiveView.push_navigate(to: Routes.path("/admin/shop"))}
    end
  end

  # The AI-translate modal's events. `PhoenixKitAI.Components.AITranslate.Embed`
  # handles them in a `:handle_event` lifecycle hook with no authorization
  # callback, and `ai_translate_lang` enqueues translation jobs.
  @ai_translate_events ~w(ai_translate_lang ai_toggle_modal ai_select_endpoint
                          ai_select_prompt ai_select_scope ai_generate_prompt)

  @doc """
  `on_mount({Authz, {:gate_ai_translate, capability}})` — halts the
  AI-translate modal's events with a denial when the socket's CURRENT scope
  lacks `capability`.

  The Embed handles those events before the LiveView's own `handle_event/3`
  can check anything, so declare this BEFORE `use
  PhoenixKitAI.Components.AITranslate.Embed`: lifecycle hooks run in the
  order they attach. Checked per event, so a grant revoked while the page
  is open (core swaps the new scope in) stops the next event.
  """
  def on_mount({:gate_ai_translate, capability}, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :shop_ai_translate_gate, :handle_event, fn
       event, _params, socket when event in @ai_translate_events ->
         if can?(socket, capability), do: {:cont, socket}, else: {:halt, deny(socket)}

       _event, _params, socket ->
         {:cont, socket}
     end)}
  end

  @doc "Adds the denial flash without navigating."
  def deny(socket) do
    Phoenix.LiveView.put_flash(socket, :error, denial_message())
  end

  defp denial_message, do: gettext("You don't have permission to do that")
end
