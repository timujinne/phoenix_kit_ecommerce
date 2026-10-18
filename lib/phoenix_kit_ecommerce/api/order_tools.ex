defmodule PhoenixKitEcommerce.API.OrderTools do
  @moduledoc """
  The tools that let an external system read orders and mark the ones it has
  taken.

  | Tool | Scope | Permission |
  |---|---|---|
  | `ecommerce.list_orders` | `ecommerce.orders:read` | `shop` |
  | `ecommerce.get_orders` | `ecommerce.orders:read` | `shop` |
  | `ecommerce.get_order_customers` | `ecommerce.orders:customer` | `shop.manage_orders` |
  | `ecommerce.set_order_sync` | `ecommerce.orders:sync` | `shop.manage_orders` |

  The order tools answer with the buyer's `id` and `type` only. The contacts
  (name, phone, email, company, tax id, address) are part of an answer when
  the key holds `ecommerce.orders:customer`. A key is given a scope through the
  tools that declare it, so `ecommerce.get_order_customers` is the tool that
  declares this one.

  The tools are offered only with a billing that keeps the revision and the
  mark of an order (`PhoenixKitBilling.put_order_sync/2`); without it an order
  has no revision to read or to check.
  """

  alias PhoenixKit.API.Tool
  alias PhoenixKitEcommerce.API.{OrderExport, Schemas}

  alias PhoenixKitEcommerce.API.{
    GetOrderCustomers,
    GetOrders,
    ListOrders,
    SetOrderSync
  }

  @compile {:no_warn_undefined, [PhoenixKit.API.Tool, PhoenixKitBilling]}

  @scope_customer "ecommerce.orders:customer"
  @max_refs 100
  @uuid "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

  @doc "The scope that lets the order tools answer with the buyer's contacts."
  @spec customer_scope() :: String.t()
  def customer_scope, do: @scope_customer

  @doc "Whether the key of the call holds `ecommerce.orders:customer`."
  @spec contacts?(map()) :: boolean()
  def contacts?(ctx), do: @scope_customer in (Map.get(ctx, :scopes) || [])

  @doc "The sections of an order to build for an `include` input; all of them when not given."
  @spec include(list() | nil) :: [atom()]
  def include(nil), do: OrderExport.sections()
  def include(names), do: Enum.filter(OrderExport.sections(), &(Atom.to_string(&1) in names))

  @doc """
  The tools for `PhoenixKitEcommerce.api_tools/0`; `[]` on a core without the
  tool registry or a billing without `put_order_sync/2`.
  """
  @spec tools(boolean()) :: [struct()]
  def tools(available? \\ available?()) do
    if available? and Code.ensure_loaded?(Tool),
      do: [
        list_orders_tool(),
        get_orders_tool(),
        get_order_customers_tool(),
        set_order_sync_tool()
      ],
      else: []
  end

  @doc "Whether the loaded billing keeps the revision and the mark of an order."
  @spec available?() :: boolean()
  def available? do
    Code.ensure_loaded?(PhoenixKitBilling) and
      function_exported?(PhoenixKitBilling, :put_order_sync, 2)
  end

  @doc false
  defdelegate list_orders(input, ctx), to: ListOrders, as: :run
  @doc false
  defdelegate get_orders(input, ctx), to: GetOrders, as: :run
  @doc false
  defdelegate get_order_customers(input, ctx), to: GetOrderCustomers, as: :run
  @doc false
  defdelegate set_order_sync(input, ctx), to: SetOrderSync, as: :run

  # -- definitions ------------------------------------------------------------

  defp list_orders_tool do
    Tool.new!(
      name: "ecommerce.list_orders",
      audience: :admin,
      scope: "ecommerce.orders:read",
      permission: "shop",
      title: "List orders",
      description:
        "Lists orders in the order of their last change, by cursor. " <>
          "Pass next_cursor back as cursor to get the next page; the cursor is opaque. " <>
          "sync pending returns the orders the external system has not taken yet, or that changed after it took them, " <>
          "so a caller that asks for pending needs no cursor of its own; synced the orders it took; any (default) all. " <>
          "Draft orders are left out unless statuses names draft. limit is 1 to 100 (default 50) and a larger one is refused, not cut. " <>
          "Each order has a sync.revision that grows with every change the external system cares about. " <>
          "The buyer's contacts are included only for a key with the ecommerce.orders:customer scope.",
      input_schema: list_orders_input(),
      output_schema: %{
        "type" => "object",
        "required" => ["orders", "has_more"],
        "properties" => %{
          "orders" => %{"type" => "array", "items" => %{"type" => "object"}},
          "next_cursor" => %{"type" => ["string", "null"]},
          "has_more" => %{"type" => "boolean"}
        }
      },
      handler: {__MODULE__, :list_orders},
      annotations: %{read_only: true, idempotent: true}
    )
  end

  defp get_orders_tool do
    Tool.new!(
      name: "ecommerce.get_orders",
      audience: :admin,
      scope: "ecommerce.orders:read",
      permission: "shop",
      title: "Get orders",
      description:
        "Reads orders by reference, an order id or an order number, at most #{@max_refs} per call. " <>
          "One result per reference, in the order given: the order or an error for that reference. " <>
          "The buyer's contacts are included only for a key with the ecommerce.orders:customer scope.",
      input_schema: get_orders_input(),
      output_schema: Schemas.batch_output(),
      handler: {__MODULE__, :get_orders},
      annotations: %{read_only: true, idempotent: true},
      max_items: @max_refs
    )
  end

  defp get_order_customers_tool do
    Tool.new!(
      name: "ecommerce.get_order_customers",
      audience: :admin,
      scope: @scope_customer,
      permission: "shop.manage_orders",
      title: "Get the buyers of orders",
      description:
        "Reads the buyer of each order, with name, phone, email, company, tax id and address, by order id or number, at most #{@max_refs} per call. " <>
          "A key with this scope also gets these contacts in ecommerce.list_orders and ecommerce.get_orders.",
      input_schema: refs_input(),
      output_schema: Schemas.batch_output(),
      handler: {__MODULE__, :get_order_customers},
      annotations: %{read_only: true, idempotent: true},
      max_items: @max_refs
    )
  end

  defp set_order_sync_tool do
    Tool.new!(
      name: "ecommerce.set_order_sync",
      audience: :admin,
      scope: "ecommerce.orders:sync",
      permission: "shop.manage_orders",
      title: "Mark orders as taken by the external system",
      description:
        "Records that the external system took orders (state synced, with its external_id, external_number and external_status) " <>
          "or refused them (state failed, with an error), at most #{@max_refs} rows per call, each independent of the others. " <>
          "Give the revision of the order as it was read. If the order changed since, the row answers conflict with context.reason stale_revision " <>
          "and context.current_revision, nothing is written and the order stays pending: read it again. " <>
          "Only the mark is written, never the order itself, and a mark does not move the order in ecommerce.list_orders. " <>
          "Repeating a row is safe. A batch longer than the confirmation threshold of the API (api_confirm_batch_over, 50 by default) is held for confirmation like any admin write.",
      input_schema: set_order_sync_input(),
      output_schema: Schemas.batch_output(),
      handler: {__MODULE__, :set_order_sync},
      annotations: %{idempotent: true},
      max_items: @max_refs
    )
  end

  # -- schemas ----------------------------------------------------------------

  defp order_ref do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "description" =>
        "Exactly one of id (the order UUID) or number (for example ORD-2026-0001).",
      "properties" => %{
        "id" => %{"type" => "string", "pattern" => @uuid},
        "number" => %{"type" => "string", "minLength" => 1, "maxLength" => 100}
      }
    }
  end

  defp refs_input do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["refs"],
      "properties" => %{
        "refs" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_refs,
          "items" => order_ref()
        }
      }
    }
  end

  defp include_property do
    %{
      "type" => "array",
      "maxItems" => length(OrderExport.sections()),
      "description" => "The parts of an order to return; all by default.",
      "items" => %{
        "type" => "string",
        "enum" => Enum.map(OrderExport.sections(), &Atom.to_string/1)
      }
    }
  end

  defp list_orders_input do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => %{
        "updated_since" => %{
          "type" => "string",
          "maxLength" => 40,
          "description" => "ISO 8601 date and time; only orders changed at or after it."
        },
        "cursor" => %{"type" => "string", "maxLength" => 512},
        "statuses" => %{
          "type" => "array",
          "maxItems" => length(ListOrders.statuses()),
          "items" => %{"type" => "string", "enum" => ListOrders.statuses()}
        },
        "sync" => %{"type" => "string", "enum" => ["pending", "synced", "any"]},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => ListOrders.max_limit()},
        "include" => include_property()
      }
    }
  end

  defp get_orders_input do
    update_in(refs_input(), ["properties"], &Map.put(&1, "include", include_property()))
  end

  defp set_order_sync_input do
    text = %{"type" => "string", "minLength" => 1, "maxLength" => 255}

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["orders"],
      "properties" => %{
        "orders" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_refs,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["ref", "revision", "state"],
            "properties" => %{
              "ref" => order_ref(),
              "revision" => %{"type" => "integer", "minimum" => 1},
              "state" => %{"type" => "string", "enum" => ["synced", "failed"]},
              "external_id" => text,
              "external_number" => text,
              "external_status" => text,
              "error" => %{"type" => "string", "minLength" => 1, "maxLength" => 2000}
            }
          }
        }
      }
    }
  end
end
