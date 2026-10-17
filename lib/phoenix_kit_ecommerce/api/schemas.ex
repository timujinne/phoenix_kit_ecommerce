defmodule PhoenixKitEcommerce.API.Schemas do
  @moduledoc """
  JSON Schemas of the e-commerce admin tools. Input schemas are closed
  (`additionalProperties: false`); core's executor closes them again and adds
  its own control fields. Patterns are written for the validator's `$` and
  are checked a second time by `PhoenixKitEcommerce.API.Money` in the
  handlers.
  """

  alias PhoenixKitEcommerce.API.{AttachImages, AvailabilityPlan, DetachImages, Money}

  @max_rows 500
  @uuid "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"

  @doc "Rows a batch tool accepts."
  @spec max_rows() :: pos_integer()
  def max_rows, do: @max_rows

  @doc "A product reference: exactly one of `id`, `sku`, `external_id` (the handler checks 'exactly')."
  @spec ref() :: map()
  def ref do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "description" => "Exactly one of id (the product UUID), sku or external_id.",
      "properties" => %{
        "id" => %{"type" => "string", "pattern" => @uuid},
        "sku" => %{"type" => "string", "minLength" => 1, "maxLength" => 200},
        "external_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 200}
      }
    }
  end

  defp catalogue_id do
    %{
      "type" => "string",
      "description" => "Optional. Must be the catalogue the shop reads; the default."
    }
  end

  @doc "Input of `ecommerce.get_prices`."
  @spec get_prices_input() :: map()
  def get_prices_input do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["refs"],
      "properties" => %{
        "catalogue_id" => catalogue_id(),
        "refs" => %{"type" => "array", "minItems" => 1, "maxItems" => @max_rows, "items" => ref()}
      }
    }
  end

  @doc "Input of `ecommerce.set_prices`."
  @spec set_prices_input() :: map()
  def set_prices_input do
    amount = %{"type" => "string", "pattern" => Money.amount_pattern()}
    nullable_amount = %{"type" => ["string", "null"], "pattern" => Money.amount_pattern()}

    modifier_value = %{"type" => ["string", "null"], "pattern" => Money.delta_pattern()}

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["items"],
      "properties" => %{
        "catalogue_id" => catalogue_id(),
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_rows,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["ref"],
            "properties" => %{
              "ref" => ref(),
              "price" =>
                Map.put(
                  amount,
                  "description",
                  "New price, a decimal string with at most 2 decimals, in the product's currency."
                ),
              "compare_at" =>
                Map.put(
                  nullable_amount,
                  "description",
                  "The struck-through price; null clears it."
                ),
              "price_modifiers" => %{
                "type" => "object",
                "description" =>
                  "option => value => amount (may be negative). Merged into the product's own; null removes one value's modifier.",
                "additionalProperties" => %{
                  "type" => "object",
                  "additionalProperties" => modifier_value
                }
              }
            }
          }
        }
      }
    }
  end

  @doc "Input of `ecommerce.set_availability`."
  @spec set_availability_input() :: map()
  def set_availability_input do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["items"],
      "properties" => %{
        "catalogue_id" => catalogue_id(),
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_rows,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["ref"],
            "properties" => %{
              "ref" => ref(),
              "visibility" => %{"type" => "string", "enum" => AvailabilityPlan.visibilities()},
              "made_to_order" => %{"type" => "boolean"}
            }
          }
        }
      }
    }
  end

  @doc "Input of `ecommerce.attach_images`."
  @spec attach_images_input() :: map()
  def attach_images_input do
    max = AttachImages.max_images()

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["items"],
      "properties" => %{
        "catalogue_id" => catalogue_id(),
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => max,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["ref", "images"],
            "properties" => %{
              "ref" => ref(),
              "images" => %{
                "type" => "array",
                "minItems" => 1,
                "maxItems" => max,
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "required" => ["url"],
                  "properties" => %{
                    "url" => %{
                      "type" => "string",
                      "maxLength" => 2048,
                      "pattern" => "^https?://[^/@?#]*([/?#]|$)"
                    },
                    "featured" => %{"type" => "boolean"}
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  @doc "Input of `ecommerce.detach_images`."
  @spec detach_images_input() :: map()
  def detach_images_input do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["items"],
      "properties" => %{
        "catalogue_id" => catalogue_id(),
        "items" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => @max_rows,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["ref", "images"],
            "properties" => %{
              "ref" => ref(),
              "images" => %{
                "type" => "array",
                "minItems" => 1,
                "maxItems" => DetachImages.max_images(),
                "items" => %{
                  "type" => "object",
                  "additionalProperties" => false,
                  "description" =>
                    "Exactly one of id (the picture's file UUID) or url (the URL it was attached from).",
                  "properties" => %{
                    "id" => %{"type" => "string", "pattern" => @uuid},
                    "url" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048}
                  }
                }
              }
            }
          }
        }
      }
    }
  end

  @doc "Success output of the batch tools: `results` and `summary`."
  @spec batch_output() :: map()
  def batch_output do
    %{
      "type" => "object",
      "required" => ["results", "summary"],
      "properties" => %{
        "results" => %{"type" => "array", "items" => %{"type" => "object"}},
        "summary" => %{"type" => "object"}
      }
    }
  end
end
