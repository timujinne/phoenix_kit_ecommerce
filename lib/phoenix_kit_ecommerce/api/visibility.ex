defmodule PhoenixKitEcommerce.API.Visibility do
  @moduledoc """
  What a public caller may see of a product. The rules are evaluated in order
  and the first match wins:

    1. item `deleted` or `inactive`, catalogue not active, category not
       `active` or `unlisted` (`hidden`, `archived`, `deleted`, anything
       else), shop status `draft`: `:hidden`.
    2. item `discontinued`, shop status `archived`: `:discontinued`.
    3. item `active` and shop status `active`: `:listed`.

  Anything else (a status nobody defined) is `:hidden`: the rule fails closed.
  A category with shop status `unlisted` keeps its products listed (it only
  leaves the navigation), as it does on the storefront; a product without a
  category (`nil`) is not held back by one.
  """

  alias PhoenixKitEcommerce.API.Facts

  @type state :: :listed | :discontinued | :hidden

  @visible_categories [nil, "active", "unlisted"]

  # Three tiers instead of one eight-branch `cond`: Credo's cyclomatic
  # complexity limit (9) fails `mix credo --strict` on the single function.
  @spec classify(Facts.t()) :: state()
  def classify(%Facts{} = facts) do
    cond do
      hidden?(facts) -> :hidden
      discontinued?(facts) -> :discontinued
      facts.item_status == "active" and facts.shop_status == "active" -> :listed
      true -> :hidden
    end
  end

  @spec listed?(Facts.t()) :: boolean()
  def listed?(%Facts{} = facts), do: classify(facts) == :listed

  # Rule 1 of the table.
  defp hidden?(facts) do
    facts.item_status in ["deleted", "inactive"] or
      facts.catalogue_listed? != true or
      facts.category_status not in @visible_categories or
      facts.shop_status == "draft"
  end

  # Rule 2 of the table.
  defp discontinued?(facts),
    do: facts.item_status == "discontinued" or facts.shop_status == "archived"
end
