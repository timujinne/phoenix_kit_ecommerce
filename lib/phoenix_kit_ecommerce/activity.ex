defmodule PhoenixKitEcommerce.Activity do
  @moduledoc """
  Thin wrapper around `PhoenixKit.Activity.log/3` for the shop module:
  the module key (`"shop"`) and the `actor_role` metadata, so every LV
  call site stays consistent. Logging failures never crash the caller —
  core logs them and returns `{:error, _}`, whether the insert failed,
  raised, exited or threw.

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

  @module "shop"

  @doc """
  Logs a shop activity entry through `PhoenixKit.Activity.log/3`.

  ## Options

    * `:actor_uuid` — uuid of the acting user (use `actor_uuid/1`)
    * `:actor_role` — role-name string of the actor (use `actor_role/1`),
      stored in the metadata as `"actor_role"`
    * `:mode` — defaults to `"manual"`
    * `:resource_type` — e.g. `"product"`, `"category"`, `"shipping_method"`
    * `:resource_uuid` — uuid of the mutated record
    * `:target_uuid` — second-party uuid where applicable
    * `:metadata` — extra PII-safe metadata map (merged over defaults)
  """
  @spec log(String.t(), keyword()) :: {:ok, struct()} | {:error, any()}
  def log(action, opts) when is_binary(action) and is_list(opts) do
    PhoenixKit.Activity.log(@module, action, Keyword.put(opts, :metadata, build_metadata(opts)))
  end

  @doc """
  Logs a mutation that was ATTEMPTED but failed.

  The audit trail should record what a person tried to do, not only what
  succeeded — a run of failed deletes is exactly the kind of thing an
  operator wants to see afterwards. Core marks the row `db_pending: true`
  so a reader can tell an attempt from a completed change; the reason is
  stringified defensively (a changeset's errors can contain anything).
  """
  @spec log_failed(String.t(), term(), keyword()) :: {:ok, struct()} | {:error, any()}
  def log_failed(action, reason, opts \\ []) do
    metadata = Map.put(build_metadata(opts), "failure_reason", failure_reason(reason))
    PhoenixKit.Activity.log_failed(@module, action, Keyword.put(opts, :metadata, metadata))
  end

  # Never let an error's SHAPE leak PII into the audit trail: changeset
  # errors quote the offending value, which on a checkout is a customer's
  # address. Only the field names and atom reasons survive.
  defp failure_reason(%Ecto.Changeset{errors: errors}) do
    errors |> Enum.map_join(", ", fn {field, _} -> to_string(field) end)
  end

  defp failure_reason(reason) when is_atom(reason), do: to_string(reason)
  defp failure_reason({reason, _details}) when is_atom(reason), do: to_string(reason)
  defp failure_reason(_other), do: "error"

  @doc "The acting user's uuid — see `PhoenixKitWeb.Actor.uuid/1`."
  @spec actor_uuid(Phoenix.LiveView.Socket.t() | map() | nil) :: String.t() | nil
  defdelegate actor_uuid(source), to: PhoenixKitWeb.Actor, as: :uuid

  @doc """
  The acting user's primary role name (not PII), or `nil` — see
  `PhoenixKitWeb.Actor.role/1`.
  """
  @spec actor_role(Phoenix.LiveView.Socket.t() | map() | nil) :: String.t() | nil
  defdelegate actor_role(source), to: PhoenixKitWeb.Actor, as: :role

  # Merges caller metadata over the default `actor_role` key. Caller
  # values win on collision so a call site can override if needed.
  defp build_metadata(opts) do
    base =
      case Keyword.get(opts, :actor_role) do
        role when is_binary(role) -> %{"actor_role" => role}
        _ -> %{}
      end

    Map.merge(base, Keyword.get(opts, :metadata) || %{})
  end
end
