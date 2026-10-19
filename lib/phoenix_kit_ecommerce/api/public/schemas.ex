defmodule PhoenixKitEcommerce.API.Public.Schemas do
  @moduledoc """
  JSON Schema pieces shared by the public tools, as maps with string keys.

  They stay inside the subset core's validator understands (`type`,
  `required`, `properties`, `additionalProperties`, `enum`, bounds, `items`,
  `pattern`) plus the annotation keywords (`description`,
  `title`, `default`, `examples`, `format`), which never reject input and are
  read by OpenAPI / MCP clients. Any other keyword (`oneOf`, `$ref`, ...) is
  not used here.

  Output schemas list only the fields that are always present as `required`:
  a value that is `nil` is left out of the answer, never sent as `null`.
  """

  @string %{"type" => "string"}
  @boolean %{"type" => "boolean"}

  @doc "The two fields every public tool accepts besides its own."
  @spec control_fields() :: map()
  def control_fields do
    %{
      "language" => %{
        "type" => "string",
        "minLength" => 2,
        "maxLength" => 16,
        "description" =>
          ~s|Language of the answer: an enabled language code such as "de" or "de-DE". | <>
            "Defaults to the language of the domain the request came to."
      },
      "currency" => %{
        "type" => "string",
        "minLength" => 3,
        "maxLength" => 3,
        "description" =>
          "Currency of every price in the answer: an enabled ISO 4217 code such as \"EUR\". " <>
            "Defaults to the currency of the domain the request came to, else the shop's base currency."
      }
    }
  end

  @doc ~s|`{"amount": "12.50", "currency": "EUR"}`.|
  @spec money() :: map()
  def money do
    %{
      "type" => "object",
      "required" => ["amount", "currency"],
      "properties" => %{"amount" => @string, "currency" => @string}
    }
  end

  @spec category_ref() :: map()
  def category_ref do
    %{
      "type" => "object",
      "required" => ["id", "name"],
      "properties" => %{"id" => @string, "name" => @string}
    }
  end

  @doc "A product in a list."
  @spec list_item() :: map()
  def list_item do
    %{
      "type" => "object",
      "required" => ["id"],
      "properties" => %{
        "id" => @string,
        "title" => @string,
        "slug" => @string,
        "url" => @string,
        "price" => money(),
        "price_from" => money(),
        "compare_at" => money(),
        "discount_pct" => %{"type" => "integer"},
        "price_on_request" => @boolean,
        "made_to_order" => @boolean,
        "vendor" => @string,
        "product_type" => @string,
        "category_path" => %{"type" => "array", "items" => category_ref()},
        "status" => @string,
        "image" => @string
      }
    }
  end

  @doc """
  The full card of `shop.get_products`: a list item plus description, tags,
  options (a value of an option that changes the price carries `price`) and
  images. The stub of a discontinued product (`id`, `title` and
  `status`) satisfies it too.
  """
  @spec card() :: map()
  def card do
    base = list_item()

    extra = %{
      "description" => @string,
      "tags" => %{"type" => "array", "items" => @string},
      "images" => %{"type" => "array", "items" => @string},
      "options" => %{
        "type" => "array",
        "items" => %{
          "type" => "object",
          "required" => ["key", "label", "values"],
          "properties" => %{
            "key" => @string,
            "label" => @string,
            "affects_price" => @boolean,
            "values" => %{
              "type" => "array",
              "items" => %{
                "type" => "object",
                "required" => ["key", "label"],
                "properties" => %{
                  "key" => @string,
                  "label" => @string,
                  "price" => money()
                }
              }
            }
          }
        }
      }
    }

    %{base | "properties" => Map.merge(base["properties"], extra)}
  end

  @spec warnings() :: map()
  def warnings do
    %{
      "type" => "array",
      "items" => %{
        "type" => "object",
        "required" => ["code", "message"],
        "properties" => %{"code" => @string, "message" => @string}
      }
    }
  end
end
