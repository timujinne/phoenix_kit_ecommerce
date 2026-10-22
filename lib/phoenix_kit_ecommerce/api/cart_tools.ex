defmodule PhoenixKitEcommerce.API.CartTools do
  @moduledoc """
  Definitions of the seven public cart tools. Audience `:public`: no key, no
  scope, no permission; the cart token in the input identifies the cart, and is
  the module's client token (`client_token: "cart_token"`, declared on a core
  whose `PhoenixKit.API.Tool` has the field): core hashes it for the caller's
  rate limit, idempotency scope and confirmation, and never keeps it in clear.
  Names are dotted here; core derives the underscored MCP names.

  Every tool also accepts the shared control fields `language` and `currency`
  (`API.Public.Schemas.control_fields/0`): core closes every schema and adds
  neither. Schemas use only what core's validator checks (`type`, `required`,
  `properties`, `additionalProperties`, `minItems`, `maxItems`, `minLength`,
  `maxLength`, `pattern`, `items`), because an agent is told by them. The
  `quantity` of a line has deliberately no `type`: a bad quantity is a per-line
  error with the allowed range, not a refusal of the whole request, and the
  handler checks it.

  `tools/0` is `[]` against a core without the tool registry, the way
  `PhoenixKitEcommerce.API.PublicTools.tools/0` is. It fails closed without
  core's confirmation gate: `shop.clear_cart` declares a `danger` check, which a
  core without the gate ignores, so the tool is withheld unless
  `gate_available?/0` finds the gate's marker, `PhoenixKit.API.Keys.active?/1`
  (the same marker as every other module of the package). The check is on the
  loaded code, not on a version number.
  """

  alias PhoenixKit.API.Tool
  alias PhoenixKitEcommerce.API.Public.Schemas
  alias PhoenixKitEcommerce.API.PublicTools

  @compile {:no_warn_undefined, [PhoenixKit.API.Tool, PhoenixKit.API.ControlFields]}

  @handlers PhoenixKitEcommerce.API.CartHandlers

  @token %{
    "type" => "string",
    "minLength" => 1,
    "maxLength" => 256,
    "description" => "The cart token returned by shop.create_cart."
  }

  @money %{
    "type" => "object",
    "description" =>
      "An amount as a decimal string with its currency, e.g. {\"amount\": \"12.50\", \"currency\": \"EUR\"}.",
    "properties" => %{"amount" => %{"type" => "string"}, "currency" => %{"type" => "string"}}
  }

  @cart %{
    "type" => "object",
    "description" => "The cart: status, lines, totals, shipping, thresholds and a revision.",
    "properties" => %{
      "status" => %{
        "type" => "string",
        "description" => "open, or checking_out once the buyer confirmed the checkout link."
      },
      "revision" => %{
        "type" => "string",
        "description" =>
          "Changes when lines, options, quantities or the shipping choice change; not with prices."
      },
      "read_at" => %{"type" => "string"},
      "currency" => %{"type" => "string"},
      "lines" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "properties" => %{
            "product_id" => %{"type" => "string"},
            "title" => %{"type" => "string"},
            "options" => %{
              "type" => "array",
              "description" =>
                "The chosen options: the keys to send back, and the labels to show a buyer, in the language of the request (for a value the product no longer offers, the label the line was added under).",
              "items" => %{
                "type" => "object",
                "required" => ["attribute_key", "value_key", "attribute_label", "value_label"],
                "properties" => %{
                  "attribute_key" => %{"type" => "string"},
                  "value_key" => %{"type" => "string"},
                  "attribute_label" => %{
                    "type" => "string",
                    "description" => "The option's name, e.g. \"Size\"."
                  },
                  "value_label" => %{
                    "type" => "string",
                    "description" => "What the value is shown as, e.g. \"5 inches (13 cm)\"."
                  }
                }
              }
            },
            "quantity" => %{"type" => "integer"},
            "unit_price" => @money,
            "line_total" => @money,
            "status" => %{
              "type" => "string",
              "description" => "ok, or unavailable when the product left the shop."
            }
          }
        }
      },
      "totals" => %{"type" => "object"},
      "shipping" => %{"type" => "object"},
      "thresholds" => %{"type" => "array"}
    }
  }

  @doc """
  The seven cart tools, in a fixed order. `shop.clear_cart` (the only `danger`
  tool) is left out unless `gate?` is true; the default asks `gate_available?/0`.
  `shop.create_cart` (it has no cart to key a replay by) and `shop.get_checkout_link`
  (its answer carries a credential, so core never stores it for replay) declare
  `replay: false`, so core offers neither an `idempotency_key`. They declare it only
  when `replay?` is true; the default asks `replay_available?/0`, because a core
  without the field refuses the tool.
  """
  @spec tools(boolean(), boolean()) :: [struct()]
  def tools(gate? \\ gate_available?(), replay? \\ replay_available?()) do
    if Code.ensure_loaded?(Tool) do
      all = [
        create_cart(replay?),
        get_cart(),
        set_cart_items(),
        clear_cart(),
        get_shipping_options(),
        set_shipping(),
        get_checkout_link(replay?)
      ]

      specs = if gate?, do: all, else: Enum.reject(all, &(not is_nil(&1[:danger])))

      # A tool that core refuses is left out and logged once; it never takes
      # the other tools (or the module's other API tools) down with it.
      client_fields? = Map.has_key?(struct(Tool), :client_token)

      specs
      |> Enum.map(&declare_client_fields(&1, client_fields?))
      |> PublicTools.build_all()
    else
      []
    end
  end

  # A core with the module-neutral API reads the caller's identity from the input
  # field a public tool declares as its `client_token`, and redacts the output fields
  # named in `credentials` from stored replays. An older core rejects a `Tool` with
  # fields it does not know, and finds the cart token by name; so the fields are
  # declared only where `Tool` has them.
  defp declare_client_fields(spec, true),
    do: Keyword.merge(spec, client_token_field(spec) ++ credentials_field(spec))

  defp declare_client_fields(spec, false), do: spec

  defp client_token_field(spec) do
    if Map.has_key?(spec[:input_schema]["properties"], "cart_token"),
      do: [client_token: "cart_token"],
      else: []
  end

  # The checkout link is the one place a tool hands out a secret: its url carries the claim token.
  defp credentials_field(spec) do
    if spec[:name] == "shop.get_checkout_link", do: [credentials: ["url"]], else: []
  end

  @doc """
  True when the loaded core carries the confirmation gate, judged by the
  exported marker function `PhoenixKit.API.Keys.active?/1`, not by a version
  number.
  """
  @spec gate_available?() :: boolean()
  def gate_available? do
    Code.ensure_loaded?(PhoenixKit.API.Keys) and
      function_exported?(PhoenixKit.API.Keys, :active?, 1)
  end

  @doc """
  True when the loaded core lets a tool give up replay (`:replay` of
  `PhoenixKit.API.Tool`), judged by the exported marker function
  `PhoenixKit.API.ControlFields.replay_tool?/1`, not by a version number.
  """
  @spec replay_available?() :: boolean()
  def replay_available? do
    Code.ensure_loaded?(PhoenixKit.API.ControlFields) and
      function_exported?(PhoenixKit.API.ControlFields, :replay_tool?, 1)
  end

  defp create_cart(replay?) do
    [
      name: "shop.create_cart",
      audience: :public,
      title: "Create a cart",
      description:
        "Returns a new cart token. Nothing is stored until the first shop.set_cart_items, so an unused token costs nothing and a retry after a timeout is harmless. " <>
          "Not idempotent: every call returns a new token. " <>
          "Keep the token secret: whoever holds it can read and change the cart.",
      input_schema: object([], %{}),
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "cart_token" => %{"type" => "string"},
          "expires_in_seconds" => %{
            "type" => "integer",
            "description" => "How long an idle cart is kept before it is swept."
          }
        }
      },
      handler: {@handlers, :create_cart},
      annotations: %{read_only: false, destructive: false, idempotent: false, open_world: false}
    ] ++ if(replay?, do: [replay: false], else: [])
  end

  defp get_cart do
    [
      name: "shop.get_cart",
      audience: :public,
      title: "Read a cart",
      description:
        "Lines, totals, the chosen shipping, shipping thresholds (how much more to reach free shipping or a minimum) and a revision. " <>
          "A token that has not written yet reads as an empty open cart. Once the buyer has confirmed the checkout link the status is checking_out and there are no lines.",
      input_schema: object(["cart_token"], %{"cart_token" => @token}),
      output_schema: @cart,
      handler: {@handlers, :get_cart},
      annotations: %{read_only: true, destructive: false, idempotent: true, open_world: false}
    ]
  end

  defp set_cart_items do
    [
      name: "shop.set_cart_items",
      audience: :public,
      title: "Set cart lines",
      description:
        "Sets the named lines to their FINAL quantities (a new line is added, an existing one is set, 0 removes it); lines you do not name stay. " <>
          "Up to 50 lines per call, and a cart holds at most 50 different lines (a new line beyond that is a validation_failed line error with reason cart_lines_limit). A line is identified by product_id and options; options are {attribute_key, value_key} pairs " <>
          "(product details list the keys). A bad line gets its own error and never stops the others: " <>
          "not_found, not_on_sale, option_required, option_invalid, quantity_invalid (a whole number from 0 to 99), duplicate_line, validation_failed. " <>
          "Send expected_revision from your last read to be told if the cart changed meanwhile (409 revision_mismatch, with what changed). " <>
          "The cart's currency is fixed by its first write.",
      input_schema:
        object(["cart_token", "items"], %{
          "cart_token" => @token,
          "expected_revision" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
          "items" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 50,
            "items" => %{
              "type" => "object",
              "required" => ["product_id"],
              "properties" => %{
                "product_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 64},
                "options" => %{
                  "type" => "array",
                  "maxItems" => 20,
                  "items" => %{
                    "type" => "object",
                    "required" => ["attribute_key", "value_key"],
                    "properties" => %{
                      "attribute_key" => %{
                        "type" => "string",
                        "minLength" => 1,
                        "maxLength" => 128
                      },
                      "value_key" => %{"type" => "string", "minLength" => 1, "maxLength" => 128}
                    }
                  }
                },
                "quantity" => %{
                  "description" =>
                    "Final quantity: a whole number from 0 to 99; 0 removes the line. " <>
                      "A line with any other value is refused on its own with quantity_invalid while the other lines apply."
                }
              }
            }
          }
        }),
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "results" => %{
            "type" => "array",
            "description" =>
              "One entry per requested line: index, ref, action (created, updated, removed, unchanged, error), and error details."
          },
          "summary" => %{"type" => "object"},
          "before" => %{"type" => "object"},
          "after" => %{"type" => "object"},
          "effects" => %{
            "type" => "array",
            "description" => "Consequences, e.g. shipping_method_unavailable, line_price_changed."
          },
          "changes" => %{"type" => "object"},
          "revision" => %{"type" => "string"},
          "cart" => @cart
        }
      },
      handler: {@handlers, :set_cart_items},
      annotations: %{read_only: false, destructive: false, idempotent: true, open_world: false},
      max_items: 50,
      cost: {@handlers, :set_cart_items_cost}
    ]
  end

  defp clear_cart do
    [
      name: "shop.clear_cart",
      audience: :public,
      title: "Empty a cart",
      description:
        "Removes every line. A cart that has lines always asks for confirmation: the first call changes nothing and returns a preview and a confirmation code; repeat the call with the code to empty the cart. A cart with nothing in it is answered at once.",
      input_schema: object(["cart_token"], %{"cart_token" => @token}),
      output_schema: %{
        "type" => "object",
        "properties" => %{"lines_removed" => %{"type" => "integer"}, "cart" => @cart}
      },
      handler: {@handlers, :clear_cart},
      annotations: %{read_only: false, destructive: true, idempotent: true, open_world: false},
      danger: {@handlers, :clear_needs_confirmation?}
    ]
  end

  defp get_shipping_options do
    [
      name: "shop.get_shipping_options",
      audience: :public,
      title: "Shipping options",
      description:
        "Every active shipping method for this cart and a destination country (ISO 3166-1 alpha-2, e.g. DE): price, whether it is free or pay-on-delivery, " <>
          "estimated days, whether it is available, and when it is not, why (country_not_served, order_below_minimum, order_above_maximum, weight_below_minimum, weight_above_maximum). " <>
          "A method with calculated: true is priced by a carrier after the buyer has chosen a destination on the site, so it has no price here.",
      input_schema:
        object(["cart_token", "country"], %{"cart_token" => @token, "country" => country_schema()}),
      output_schema: %{
        "type" => "object",
        "properties" => %{"country" => %{"type" => "string"}, "methods" => %{"type" => "array"}}
      },
      handler: {@handlers, :get_shipping_options},
      annotations: %{read_only: true, destructive: false, idempotent: true, open_world: false}
    ]
  end

  defp set_shipping do
    [
      name: "shop.set_shipping",
      audience: :public,
      title: "Choose shipping",
      description:
        "Chooses a shipping method (an id from shop.get_shipping_options) and destination country for a cart that has lines. " <>
          "A method that is not available for this cart and country is refused with the ids that are. " <>
          "For a method with calculated: true the answer shows quote_status; the buyer finishes the destination and sees the carrier price at checkout, and totals.shipping stays provisional until then.",
      input_schema:
        object(["cart_token", "country", "method_id"], %{
          "cart_token" => @token,
          "country" => country_schema(),
          "method_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 64}
        }),
      output_schema: @cart,
      handler: {@handlers, :set_shipping},
      annotations: %{read_only: false, destructive: false, idempotent: true, open_world: false}
    ]
  end

  defp get_checkout_link(replay?) do
    [
      name: "shop.get_checkout_link",
      audience: :public,
      title: "Checkout link",
      description:
        "Returns a one-time link where the buyer reviews the cart and continues to checkout on the site. Payment and personal details never pass through this API. " <>
          "Each call issues a new link and replaces the earlier one; the link expires (see expires_in_seconds). Opening the link changes nothing; the cart is locked when the buyer confirms on the page, and a change made to the cart after the page was shown makes the page ask the buyer again.",
      input_schema: object(["cart_token"], %{"cart_token" => @token}),
      output_schema: %{
        "type" => "object",
        "properties" => %{
          "url" => %{"type" => "string"},
          "expires_at" => %{"type" => "string"},
          "expires_in_seconds" => %{"type" => "integer"}
        }
      },
      handler: {@handlers, :get_checkout_link},
      annotations: %{read_only: false, destructive: false, idempotent: false, open_world: false}
    ] ++ if(replay?, do: [replay: false], else: [])
  end

  # An object schema with the shared control fields (`language`, `currency`)
  # merged into its properties. `required: []` is left out.
  defp object(required, properties) do
    schema = %{
      "type" => "object",
      "properties" => Map.merge(properties, Schemas.control_fields())
    }

    if required == [], do: schema, else: Map.put(schema, "required", required)
  end

  defp country_schema do
    %{
      "type" => "string",
      "minLength" => 2,
      "maxLength" => 2,
      "pattern" => "^[A-Za-z]{2}$",
      "description" => "ISO 3166-1 alpha-2 country code, e.g. DE."
    }
  end
end
