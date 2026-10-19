defmodule PhoenixKitEcommerce.API.Public.Search do
  @moduledoc """
  Handlers and schemas of `shop.search_products` and `shop.search_products_batch`.
  The first answers one query; the batch tool answers up to 20 of them in one
  call, sharing one category lookup and one budget of 200 cards.

  A search is two steps. `PhoenixKitEcommerce.Search.Query` answers from the
  index with product ids, the exact count and the facets; the items are then
  built from live data (`PhoenixKitEcommerce.API.Loader`, `Cards.list_item/2`)
  and a product that is no longer listed is dropped, so the index can be a few
  seconds behind without ever showing a hidden product.

  What comes from the index alone is the `count`, the facets, the price range
  and the matching of the filters and the text: a change reaches them with the
  reindex job (five seconds and the queue, or the nightly rebuild if the job
  fails), so for that time a count can include a product the items no longer
  show. The product itself, its title and its id are never read from the index.

  Cost: what the cards of an answer share (the option schema, the categories,
  the pictures' variants) is read once for the answer, per query block in a
  batch, and only for the fields asked for (`fields`), so a page of any size
  runs a fixed handful of queries beside the search itself. Every search, each
  cursor page included, also reads the matched rows (up to 5000) for the
  facets, unless the query says `facets: false`. That is bounded by the page size (at most 100), the 200 cards of a
  batch and the rate limit, and accepted for a catalogue of some thousands of
  products.
  """

  require Logger

  alias PhoenixKitEcommerce.API.Cards
  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.API.Public.Schemas
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.API.SearchParams
  alias PhoenixKitEcommerce.Search.Query
  alias PhoenixKitEcommerce.Translations

  @max_queries 20
  @batch_default_limit 10
  @batch_card_budget 200
  # The most keys, or values of one key, a warning lists as valid.
  @valid_listed 100

  # --- handlers --------------------------------------------------------------

  @spec search_products(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def search_products(input, ctx) do
    with {:ok, context} <- Context.build(input, ctx) do
      Context.with_request_currency(context, fn -> search_one(input, context) end)
    end
  end

  defp search_one(input, context) do
    case run_one(input, context, "", Loader.categories()) do
      {:ok, block} ->
        {:ok, block}

      {:error, errors} ->
        {:error, :validation_failed, "The search input is not valid.", %{errors: errors}}
    end
  end

  @spec search_products_batch(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def search_products_batch(input, ctx), do: search_products_batch(input, ctx, @batch_card_budget)

  @doc false
  # The 3-arity form takes the card budget so that a test can use a small one.
  def search_products_batch(%{"queries" => queries} = input, ctx, budget) when is_list(queries) do
    with {:ok, context} <- Context.build(input, ctx) do
      results =
        Context.with_request_currency(context, fn -> batch_blocks(queries, context, budget) end)

      {:ok, %{"results" => results, "count" => length(results)}}
    end
  end

  # One batch builds at most @batch_card_budget cards in total (a batch of 20
  # queries x limit 100 would otherwise build 2000 cards serially in one request
  # for 20 rate-limit units; measured at 4122 queries / 1.4 s on 300 products).
  # The budget is spent in order, by the cards a query actually returned; a
  # query that asks for more than what is left is trimmed (never below 1) with a
  # `batch_limit_trimmed` warning.
  defp batch_blocks(queries, context, budget) do
    categories = Loader.categories()

    {blocks, _left} =
      queries
      |> Enum.with_index()
      |> Enum.map_reduce(budget, fn {query, index}, left ->
        block = batch_block(query, index, context, categories, left)
        {block, max(left - length(Map.get(block, "items", [])), 0)}
      end)

    blocks
  end

  @doc false
  # Public for the test: trims `params.limit` to what is left of the batch budget.
  @spec trim_to_budget(map(), [map()], non_neg_integer() | nil) :: {map(), [map()]}
  def trim_to_budget(params, warnings, nil), do: {params, warnings}

  def trim_to_budget(%{limit: limit} = params, warnings, left) do
    allowed = max(left, 1)

    if limit > allowed do
      warning = %{
        "code" => "batch_limit_trimmed",
        "message" =>
          "A batch builds about #{@batch_card_budget} cards; limit was reduced to #{allowed}.",
        "requested" => limit,
        "applied" => allowed
      }

      {%{params | limit: allowed}, warnings ++ [warning]}
    else
      {params, warnings}
    end
  end

  @doc """
  The rate-limit price of a batch: one unit per query. Declared
  on the tool as `cost: {#{inspect(__MODULE__)}, :batch_cost}`.

  The executor calls it with the RAW input, before validation,
  so it must answer a positive integer for any term and never raise. A batch
  over the cap is refused by the schema (422); it is charged the cap.
  """
  @spec batch_cost(term()) :: pos_integer()
  def batch_cost(%{"queries" => queries}) when is_list(queries),
    do: queries |> length() |> max(1) |> min(@max_queries)

  def batch_cost(_input), do: 1

  defp batch_block(query, index, context, categories, left) do
    base = %{"index" => index} |> put_unless_nil("ref", Map.get(query, "ref"))
    # Inside a batch a query that names no limit gets 10, not 20.
    query = Map.put_new(query, "limit", @batch_default_limit)

    case run_one(query, context, "queries[#{index}].", categories, left) do
      {:ok, block} ->
        Map.merge(base, block)

      {:error, errors} ->
        Map.put(base, "error", %{
          "code" => "validation_failed",
          "message" => "This query is not valid.",
          "context" => %{"errors" => Enum.map(errors, &stringify_keys/1)}
        })
    end
  rescue
    error ->
      # The exception module only: its message and stacktrace arguments may hold
      # request values (a search text, a cart token).
      Logger.error("[Search] a batch query failed: ** (#{inspect(error.__struct__)})")

      %{"index" => index}
      |> put_unless_nil("ref", Map.get(query, "ref"))
      |> Map.put("error", %{
        "code" => "internal_error",
        "message" => "This query failed unexpectedly.",
        "context" => %{}
      })
  end

  # --- one query -------------------------------------------------------------

  defp run_one(query, context, prefix, categories, left \\ nil) do
    with {:ok, params, warnings} <- SearchParams.normalize(query, context, prefix) do
      {params, warnings} = trim_to_budget(params, warnings, left)
      result = Query.run(params, context.language)
      {:ok, block(result, params, warnings, query, context, categories)}
    end
  end

  defp block(result, params, warnings, query, context, categories) do
    records = Loader.load(result.ids, language: context.language, categories: categories)

    keys = item_keys(Map.get(query, "fields"))

    listed =
      for id <- result.ids, %Record{state: :listed} = record <- [Map.get(records, id)], do: record

    lookup = Cards.lookup(listed, keys: keys)

    items = Enum.map(listed, &Cards.list_item(&1, context, keys: keys, lookup: lookup))

    warnings = warnings ++ unknown_option_warnings(params, context.language)
    warnings = if result.truncated?, do: warnings ++ [facets_truncated()], else: warnings

    %{
      "count" => result.count,
      "items" => items,
      "match_mode" => Atom.to_string(result.mode),
      "language" => context.language,
      "currency" => context.currency.code
    }
    |> put_unless_nil("facets", result.facets && facets(result.facets, context, categories))
    |> put_unless_nil("next_cursor", Query.next_cursor(params.offset, params.limit, result.count))
    |> put_unless_empty("warnings", warnings)
  end

  defp item_keys(fields) when is_list(fields), do: Enum.uniq(["id" | fields])
  defp item_keys(_none), do: nil

  # A key or value the index never saw makes the filter match nothing (a key),
  # or nothing for that value (a value): say so, with what is valid, so that a
  # typo reads differently from an empty result.
  defp unknown_option_warnings(%{options: options}, language) when map_size(options) > 0 do
    vocabulary = Query.option_vocabulary(language)

    options
    |> Enum.sort_by(fn {key, _values} -> key end)
    |> Enum.flat_map(fn {key, values} -> unknown_option(key, values, vocabulary) end)
  end

  defp unknown_option_warnings(_params, _language), do: []

  defp unknown_option(key, values, vocabulary) do
    case Map.fetch(vocabulary, key) do
      :error ->
        [
          %{
            "code" => "unknown_option_key",
            "message" =>
              "No product has the option #{inspect(key)}, so this filter matches nothing. " <>
                "Use a key from valid_keys.",
            "key" => key,
            "valid_keys" => vocabulary |> Map.keys() |> Enum.sort() |> Enum.take(@valid_listed)
          }
        ]

      {:ok, known} ->
        case Enum.reject(values, &(&1 in known)) do
          [] ->
            []

          unknown ->
            [
              %{
                "code" => "unknown_option_value",
                "message" =>
                  "No product has these values of the option #{inspect(key)}. " <>
                    "Use values from valid_values.",
                "key" => key,
                "values" => unknown,
                "valid_values" => Enum.take(known, @valid_listed)
              }
            ]
        end
    end
  end

  defp facets_truncated do
    %{
      "code" => "facets_truncated",
      "message" => "The facets were computed from the first 5000 matching products."
    }
  end

  defp facets(facets, context, categories) do
    %{
      "categories" => category_facets(facets.categories, context.language, categories),
      "vendors" =>
        facets.vendors
        |> Enum.map(fn {value, count} -> %{"value" => value, "count" => count} end)
        |> Enum.sort_by(&{-&1["count"], &1["value"]}),
      "options" => option_facets(facets.options),
      "on_sale" => facets.on_sale,
      "made_to_order" => facets.made_to_order
    }
    |> put_price(facets.price, context)
  end

  # Active categories only, as in list_categories: an unlisted or
  # hidden category is never named, though a product in it may be listed.
  defp category_facets(counts, language, categories) do
    counts
    |> Enum.flat_map(fn {uuid, count} ->
      category_facet(Map.get(categories, uuid), uuid, count, language)
    end)
    |> Enum.sort_by(&{-&1["count"], &1["name"]})
  end

  defp category_facet(%{status: "active"} = category, uuid, count, language) do
    [
      %{
        "id" => uuid,
        "name" => Translations.get_display(category, :name, language) || "",
        "count" => count
      }
    ]
  end

  defp category_facet(_none_or_not_listed, _uuid, _count, _language), do: []

  defp option_facets(options) do
    options
    |> Enum.group_by(& &1.key)
    |> Enum.sort_by(fn {key, _group} -> key end)
    |> Enum.map(fn {key, group} ->
      %{
        "key" => key,
        "label" => hd(group).set_label,
        "values" =>
          Enum.map(group, &%{"key" => &1.value, "label" => &1.label, "count" => &1.count})
      }
    end)
  end

  defp put_price(map, nil, _context), do: map

  defp put_price(map, {min, max}, context) do
    Map.put(map, "price", %{
      "min" => Context.money(context, min),
      "max" => Context.money(context, max)
    })
  end

  defp stringify_keys(map), do: Map.new(map, fn {key, value} -> {to_string(key), value} end)

  defp put_unless_nil(map, _key, nil), do: map
  defp put_unless_nil(map, key, value), do: Map.put(map, key, value)

  defp put_unless_empty(map, _key, []), do: map
  defp put_unless_empty(map, key, value), do: Map.put(map, key, value)

  # --- schemas ---------------------------------------------------------------

  @doc "The properties of one search query; shared by the single and the batch tool."
  @spec query_properties() :: map()
  def query_properties do
    %{
      "q" => %{
        "type" => "string",
        "maxLength" => 200,
        "description" =>
          "Words to search for in titles, descriptions, tags, vendor, categories and options. " <>
            "Quotes match a phrase, a leading minus excludes a word. Leave out to browse."
      },
      "category_id" => %{
        "type" => "string",
        "description" =>
          "A category id from shop.list_categories; its sub-categories are searched too."
      },
      "price_min" => %{
        "type" => ["number", "string"],
        "maximum" => 1.0e15,
        "maxLength" => 40,
        "description" => "Lowest price, in the response currency (a number or a decimal string)."
      },
      "price_max" => %{
        "type" => ["number", "string"],
        "maximum" => 1.0e15,
        "maxLength" => 40,
        "description" => "Highest price, in the response currency (a number or a decimal string)."
      },
      "options" => %{
        "type" => "object",
        "description" =>
          "Option filters: attribute key to a list of value keys, as in the facets. " <>
            "Values of one key are alternatives; several keys must all match. " <>
            "A key or value no product has adds a warning that lists the valid ones.",
        "additionalProperties" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => SearchParams.max_option_values(),
          "items" => %{"type" => "string", "maxLength" => SearchParams.max_text_length()}
        }
      },
      "vendor" => %{"type" => "string", "maxLength" => SearchParams.max_text_length()},
      "on_sale" => %{
        "type" => "boolean",
        "description" => "true: only products with a sale price; false: only products without."
      },
      "made_to_order" => %{"type" => "boolean"},
      "sort" => %{"type" => "string", "enum" => SearchParams.sorts()},
      "limit" => %{
        "type" => "integer",
        "minimum" => 1,
        "maximum" => 1_000_000,
        "description" => "Page size. Default 20; above 100 is reduced to 100 with a warning."
      },
      "cursor" => %{
        "type" => "string",
        "maxLength" => 64,
        "description" => "The next_cursor of the previous page."
      },
      "fields" => %{
        "type" => "array",
        "maxItems" => length(Cards.list_fields()),
        "items" => %{"type" => "string", "enum" => Cards.list_fields()},
        "description" => "Item fields to return; id is always returned."
      },
      "facets" => %{
        "type" => "boolean",
        "description" =>
          "false: leave the facets out of the answer (a much smaller answer when you only need the items). Default true."
      }
    }
  end

  @spec search_input_schema() :: map()
  def search_input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => Map.merge(query_properties(), Schemas.control_fields())
    }
  end

  @spec batch_input_schema() :: map()
  def batch_input_schema do
    query =
      %{
        "type" => "object",
        "additionalProperties" => false,
        "properties" =>
          Map.put(query_properties(), "ref", %{
            "type" => "string",
            "maxLength" => 100,
            "description" => "Your own label for this query; it is returned unchanged."
          })
      }

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["queries"],
      "properties" =>
        Map.merge(
          %{
            "queries" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => @max_queries,
              "items" => query
            }
          },
          Schemas.control_fields()
        )
    }
  end

  @spec search_output_schema() :: map()
  def search_output_schema do
    %{
      "type" => "object",
      "required" => ["count", "items", "match_mode"],
      "properties" => block_properties()
    }
  end

  @spec batch_output_schema() :: map()
  def batch_output_schema do
    %{
      "type" => "object",
      "required" => ["results", "count"],
      "properties" => %{
        "count" => %{"type" => "integer"},
        "results" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["index"],
            "properties" =>
              Map.merge(block_properties(), %{
                "index" => %{"type" => "integer"},
                "ref" => %{"type" => "string"},
                "error" => %{
                  "type" => "object",
                  "required" => ["code", "message"],
                  "properties" => %{
                    "code" => %{"type" => "string"},
                    "message" => %{"type" => "string"},
                    "context" => %{"type" => "object"}
                  }
                }
              })
          }
        }
      }
    }
  end

  defp block_properties do
    %{
      "count" => %{
        "type" => "integer",
        "description" => "How many products match, over all pages."
      },
      "items" => %{"type" => "array", "items" => Schemas.list_item()},
      "facets" => %{"type" => "object", "description" => "Left out when facets is false."},
      "match_mode" => %{"type" => "string", "enum" => ["browse", "fulltext", "typo"]},
      "language" => %{"type" => "string"},
      "currency" => %{"type" => "string"},
      "next_cursor" => %{"type" => "string"},
      "warnings" => Schemas.warnings()
    }
  end
end
