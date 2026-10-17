defmodule PhoenixKitEcommerce.API.Public.Catalog do
  @moduledoc """
  Handlers and schemas of `shop.get_products`, `shop.list_categories` and
  `shop.similar_products`.

  What a caller may see of a product is decided in one place,
  `PhoenixKitEcommerce.API.Visibility`, and all three tools go
  through it: a hidden product, a malformed id and an unknown id produce the
  same `not_found`, so an answer never tells a caller that a hidden product
  exists.

  `shop.list_categories` answers an empty tree while the shop's catalogue is
  not active (archived, or not found), as every product of it is then not found.
  Its `count` is the number of categories in the answered tree, so it matches
  what a caller can walk (a category inside a cycle of parents has no root and
  is in neither). The per-category product counts come from the search index
  and can lag a changed product by the re-index delay; the products themselves
  are always read live. A category under an unlisted middle category is a root
  of the tree, and its products count towards that category only, while a
  search by the listed ancestor's id (`category_id`) still finds them: the
  tree follows the storefront's flat navigation, the search follows the path.
  """

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Cards
  alias PhoenixKitEcommerce.API.Context
  alias PhoenixKitEcommerce.API.Loader
  alias PhoenixKitEcommerce.API.Public.Schemas
  alias PhoenixKitEcommerce.API.Record
  alias PhoenixKitEcommerce.Search.Query
  alias PhoenixKitEcommerce.Translations

  @max_ids 50
  @ids_per_unit 10
  @default_similar 10
  @max_similar 20
  @not_found %{"code" => "not_found", "message" => "No such product."}

  # --- shop.get_products -----------------------------------------------------

  @spec get_products(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def get_products(%{"ids" => ids} = input, ctx) when is_list(ids) do
    with {:ok, context} <- Context.build(input, ctx) do
      format = Map.get(input, "format", "text")

      Context.with_request_currency(context, fn ->
        {:ok, products_answer(ids, format, context)}
      end)
    end
  end

  @doc """
  The rate-limit price of `shop.get_products`: one unit per ten ids, so a
  full call of 50 costs 5. Declared on the tool as
  `cost: {#{inspect(__MODULE__)}, :get_products_cost}`.

  The executor calls it with the RAW input, before validation, so it must
  answer a positive integer for any term and never raise. A call over the cap
  is refused by the schema (422); it is charged the cap.
  """
  @spec get_products_cost(term()) :: pos_integer()
  def get_products_cost(%{"ids" => ids}) when is_list(ids) do
    units = div(length(ids) + @ids_per_unit - 1, @ids_per_unit)
    units |> max(1) |> min(div(@max_ids, @ids_per_unit))
  end

  def get_products_cost(_input), do: 1

  # Each distinct id is loaded once and its card built once, however often the
  # caller repeats it; the answer still has one row per input id, in order.
  defp products_answer(ids, format, context) do
    canonical = Enum.map(ids, &Loader.canonical_uuid/1)
    unique = canonical |> Enum.reject(&is_nil/1) |> Enum.uniq()
    records = Loader.load(unique, language: context.language)

    lookup =
      records |> Map.values() |> Enum.filter(&(&1.state == :listed)) |> Cards.lookup(card?: true)

    products =
      Map.new(unique, fn id -> {id, product(Map.get(records, id), context, format, lookup)} end)

    results =
      ids
      |> Enum.zip(canonical)
      |> Enum.map(fn {ref, id} -> row(ref, id && Map.get(products, id)) end)

    %{"results" => results, "summary" => summary(results)}
  end

  defp product(%Record{state: :listed} = record, context, format, lookup),
    do: Cards.card(record, context, format: format, lookup: lookup)

  defp product(%Record{state: :discontinued} = record, context, _format, _lookup),
    do: Cards.stub(record, context)

  defp product(_hidden_or_unknown, _context, _format, _lookup), do: nil

  defp row(ref, nil), do: %{"ref" => ref, "error" => @not_found}
  defp row(ref, product), do: %{"ref" => ref, "product" => product}

  defp summary(results) do
    %{
      "found" => Enum.count(results, &(get_in(&1, ["product", "status"]) == "active")),
      "discontinued" =>
        Enum.count(results, &(get_in(&1, ["product", "status"]) == "discontinued")),
      "not_found" => Enum.count(results, &Map.has_key?(&1, "error"))
    }
  end

  # --- shop.list_categories --------------------------------------------------

  @spec list_categories(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def list_categories(input, ctx) do
    with {:ok, context} <- Context.build(input, ctx) do
      Context.with_request_currency(context, fn -> {:ok, categories_answer(context)} end)
    end
  end

  # An archived or missing shop catalogue lists nothing (a product of it is
  # not found either), so the tree is empty rather than a list of categories
  # with no products.
  defp categories_answer(context) do
    if Loader.catalogue_listed?() do
      categories =
        Loader.categories()
        |> Map.values()
        |> Enum.filter(&(&1.status == "active"))

      counts = Query.category_counts(context.language)

      tree = tree(categories, counts, context)

      %{"categories" => tree, "count" => node_count(tree)}
    else
      %{"categories" => [], "count" => 0}
    end
  end

  defp node_count(nodes),
    do: Enum.reduce(nodes, 0, &(&2 + 1 + node_count(&1["children"])))

  defp tree(categories, counts, context) do
    by_parent = Enum.group_by(categories, & &1.parent_uuid)
    known = MapSet.new(categories, & &1.uuid)

    categories
    |> Enum.filter(&(is_nil(&1.parent_uuid) or not MapSet.member?(known, &1.parent_uuid)))
    |> sort(context)
    |> Enum.map(&category_node(&1, by_parent, counts, context))
  end

  # Only the subtrees of roots are walked, and a category has one parent, so a
  # cycle of parents (which contains no root) is never reached.
  defp category_node(category, by_parent, counts, context) do
    children =
      by_parent
      |> Map.get(category.uuid, [])
      |> sort(context)
      |> Enum.map(&category_node(&1, by_parent, counts, context))

    own = Map.get(counts, category.uuid, 0)
    language = context.language
    slug = Cards.link_slug(category, language)

    %{
      "id" => category.uuid,
      "name" => Translations.get_display(category, :name, language) || "",
      "slug" => slug,
      "url" => slug && Context.absolute(context, Shop.category_url(category, language)),
      "product_count" => own,
      "total_count" => own + Enum.sum(Enum.map(children, & &1["total_count"])),
      "children" => children
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp sort(categories, context) do
    Enum.sort_by(
      categories,
      &{&1.position || 0, Translations.get_display(&1, :name, context.language) || ""}
    )
  end

  # --- shop.similar_products -------------------------------------------------

  @spec similar_products(map(), map()) :: {:ok, map()} | {:error, atom(), String.t(), map()}
  def similar_products(%{"id" => id} = input, ctx) do
    with {:ok, context} <- Context.build(input, ctx),
         {:ok, base} <- listed_entry(id, context) do
      {limit, warnings} = similar_limit(Map.get(input, "limit"))

      Context.with_request_currency(context, fn ->
        {:ok, similar_answer(base, limit, warnings, context)}
      end)
    end
  end

  defp similar_answer(base, limit, warnings, context) do
    ids = Query.similar(base, limit)
    records = Loader.load(ids, language: context.language)

    listed = for id <- ids, %Record{state: :listed} = record <- [Map.get(records, id)], do: record
    lookup = Cards.lookup(listed)
    items = Enum.map(listed, &Cards.list_item(&1, context, lookup: lookup))

    out = %{"items" => items, "count" => length(items)}
    if warnings == [], do: out, else: Map.put(out, "warnings", warnings)
  end

  # The base product must be listed now (a live check) and indexed, else not_found.
  defp listed_entry(id, context) do
    with uuid when is_binary(uuid) <- Loader.canonical_uuid(id),
         %{} = entry <- Query.entry(uuid, context.language),
         %Record{state: :listed} <- Map.get(Loader.load([uuid], language: context.language), uuid) do
      {:ok, entry}
    else
      _none -> {:error, :not_found, "No such product.", %{}}
    end
  end

  defp similar_limit(nil), do: {@default_similar, []}

  defp similar_limit(n) when is_integer(n) and n > @max_similar do
    {@max_similar,
     [
       %{
         "code" => "limit_trimmed",
         "message" => "limit was reduced to #{@max_similar}",
         "requested" => n,
         "applied" => @max_similar
       }
     ]}
  end

  defp similar_limit(n) when is_integer(n) and n >= 1, do: {n, []}
  defp similar_limit(_other), do: {@default_similar, []}

  # --- schemas ---------------------------------------------------------------

  @spec get_products_input_schema() :: map()
  def get_products_input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["ids"],
      "properties" =>
        Map.merge(
          %{
            "ids" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => @max_ids,
              "items" => %{"type" => "string", "maxLength" => 64},
              "description" => "Product ids, as returned by search (at most #{@max_ids})."
            },
            "format" => %{
              "type" => "string",
              "enum" => ["text", "markdown"],
              "description" =>
                "How to write the description: plain text (default) or Markdown. Markdown is the " <>
                  "seller's, with the links as they were written: sanitise it before rendering."
            }
          },
          Schemas.control_fields()
        )
    }
  end

  @spec get_products_output_schema() :: map()
  def get_products_output_schema do
    %{
      "type" => "object",
      "required" => ["results", "summary"],
      "properties" => %{
        "results" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "required" => ["ref"],
            "properties" => %{
              "ref" => %{"type" => "string"},
              "product" => Schemas.card(),
              "error" => %{
                "type" => "object",
                "required" => ["code", "message"],
                "properties" => %{
                  "code" => %{"type" => "string"},
                  "message" => %{"type" => "string"}
                }
              }
            }
          }
        },
        "summary" => %{
          "type" => "object",
          "properties" => %{
            "found" => %{"type" => "integer"},
            "discontinued" => %{"type" => "integer"},
            "not_found" => %{"type" => "integer"}
          }
        }
      }
    }
  end

  @spec list_categories_input_schema() :: map()
  def list_categories_input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "properties" => Schemas.control_fields()
    }
  end

  @spec list_categories_output_schema() :: map()
  def list_categories_output_schema do
    node = %{
      "type" => "object",
      "required" => ["id", "name", "product_count", "total_count", "children"],
      "properties" => %{
        "id" => %{"type" => "string"},
        "name" => %{"type" => "string"},
        "slug" => %{"type" => "string"},
        "url" => %{"type" => "string"},
        "product_count" => %{"type" => "integer"},
        "total_count" => %{"type" => "integer"},
        "children" => %{"type" => "array", "items" => %{"type" => "object"}}
      }
    }

    %{
      "type" => "object",
      "required" => ["categories", "count"],
      "properties" => %{
        "categories" => %{"type" => "array", "items" => node},
        "count" => %{"type" => "integer"}
      }
    }
  end

  @spec similar_products_input_schema() :: map()
  def similar_products_input_schema do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["id"],
      "properties" =>
        Map.merge(
          %{
            "id" => %{"type" => "string", "maxLength" => 64, "description" => "A product id."},
            "limit" => %{
              "type" => "integer",
              "minimum" => 1,
              "maximum" => 1_000_000,
              "description" =>
                "How many products. Default #{@default_similar}; above #{@max_similar} is reduced with a warning."
            }
          },
          Schemas.control_fields()
        )
    }
  end

  @spec similar_products_output_schema() :: map()
  def similar_products_output_schema do
    %{
      "type" => "object",
      "required" => ["items", "count"],
      "properties" => %{
        "items" => %{"type" => "array", "items" => Schemas.list_item()},
        "count" => %{"type" => "integer"},
        "warnings" => Schemas.warnings()
      }
    }
  end
end
