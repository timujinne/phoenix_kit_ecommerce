defmodule PhoenixKitEcommerce.Activity do
  @moduledoc """
  Thin wrapper around `PhoenixKit.Activity.log/1` for the shop module.

  Centralizes the `Code.ensure_loaded?/1` guard, the rescue clause, and
  the default metadata (`module: "shop"`, `actor_role`) so every LV call
  site stays consistent and **logging failures never crash the caller**.

  ## Where to call this

  Activity logging happens at the **LiveView layer**, on the `{:ok, _}`
  branch of each successful mutation — never inside context functions.
  The LiveView is where the actor is unambiguously known (via
  `socket.assigns[:phoenix_kit_current_scope]`) and where user intent is
  clear ("admin clicked Save"). Context functions stay pure and keep
  stable signatures.

  ## Action strings

  Actions follow `"shop.<resource>_<verb>"`, e.g.
  `"shop.product_created"`, `"shop.category_deleted"`.

  ## PII safety

  Only ever pass PII-safe metadata: resource uuids, status strings,
  slugs, SKUs, prices (as strings), counts, and flags. **Never** log
  customer email, phone, person names, addresses, or free text. Carts
  are customer data — log only the cart uuid + status/count, never
  customer contact fields.
  """

  require Logger

  @module "shop"

  @typedoc "Return value of `log/2`. Mirrors `PhoenixKit.Activity.log/1` plus the unavailable/rescued sentinels."
  @type log_result :: :ok | :activity_unavailable | {:ok, struct()} | {:error, any()}

  @doc """
  Logs a shop activity entry via `PhoenixKit.Activity`.

  No-ops (returns `:activity_unavailable`) when core's `PhoenixKit.Activity`
  module isn't loaded, and rescues/catches any failure so the calling
  LiveView event handler can't crash on a logging error.

  ## Options

    * `:actor_uuid` — uuid of the acting user (use `actor_uuid/1`)
    * `:actor_role` — role-name string of the actor (use `actor_role/1`)
    * `:mode` — defaults to `"manual"`
    * `:resource_type` — e.g. `"product"`, `"category"`, `"shipping_method"`
    * `:resource_uuid` — uuid of the mutated record
    * `:target_uuid` — second-party uuid where applicable
    * `:metadata` — extra PII-safe metadata map (merged over defaults)
  """
  @spec log(String.t(), keyword()) :: log_result()
  def log(action, opts) when is_binary(action) and is_list(opts) do
    if Code.ensure_loaded?(PhoenixKit.Activity) do
      entry = %{
        action: action,
        module: @module,
        mode: Keyword.get(opts, :mode, "manual"),
        actor_uuid: Keyword.get(opts, :actor_uuid),
        resource_type: Keyword.get(opts, :resource_type),
        resource_uuid: Keyword.get(opts, :resource_uuid),
        target_uuid: Keyword.get(opts, :target_uuid),
        metadata: build_metadata(opts)
      }

      PhoenixKit.Activity.log(entry)
    else
      :activity_unavailable
    end
  rescue
    Postgrex.Error ->
      :ok

    DBConnection.OwnershipError ->
      :ok

    e ->
      Logger.warning("[Shop] Activity logging error: #{Exception.message(e)}")
      {:error, e}
  catch
    :exit, _reason -> :ok
  end

  @doc """
  Extracts the acting user's uuid from the LiveView socket assigns.

  Reads `socket.assigns[:phoenix_kit_current_scope]` (the shop
  convention; the production `live_session :phoenix_kit_admin` on_mount
  hook populates it). Returns `nil` for an unauthenticated/absent scope.
  """
  @spec actor_uuid(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def actor_uuid(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{user: %{uuid: uuid}} -> uuid
      _ -> nil
    end
  end

  @doc """
  Extracts the acting user's primary role-name string from the socket's
  scope (first entry of `cached_roles`). Returns `nil` when no role is
  cached. Role names are not PII.
  """
  @spec actor_role(Phoenix.LiveView.Socket.t()) :: String.t() | nil
  def actor_role(socket) do
    case socket.assigns[:phoenix_kit_current_scope] do
      %{cached_roles: [role | _]} when is_binary(role) -> role
      _ -> nil
    end
  end

  # Merges caller metadata over the default `actor_role` key. Caller
  # values win on collision so a call site can override if needed.
  defp build_metadata(opts) do
    base =
      case Keyword.get(opts, :actor_role) do
        role when is_binary(role) -> %{"actor_role" => role}
        _ -> %{}
      end

    Map.merge(base, Keyword.get(opts, :metadata, %{}))
  end
end
