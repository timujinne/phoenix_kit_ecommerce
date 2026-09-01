defmodule PhoenixKitEcommerce.Shopify.Sync do
  @moduledoc """
  Orchestrates a Shopify → local product sync: fetch, diff, and selectively
  apply confirmed changes.

  This is the domain layer only — no LiveView/UI wiring here (see
  `PhoenixKitEcommerce.Shopify.Provider` moduledoc for why "Test Connection"
  doesn't exercise this; that's this module's job instead, via `check/2`).
  """

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.ProductDiff.Change
  alias PhoenixKitEcommerce.Shopify.Source
  alias PhoenixKitEcommerce.Translations

  @localized_fields [:title, :body_html, :description]

  @doc """
  Fetches Shopify products for `integration_uuid` via `Source.fetch/2`
  (Admin API primary, public storefront fallback — see that module's
  moduledoc for the fallback/abort rules), diffs them against the local
  catalog, and returns the changes an operator can review.

  The result carries `:source` (`:admin` or `:storefront`) and
  `:fallback_reason` alongside `:changes` — a caller MUST branch on
  `:source` before presenting the result as a complete diff. A
  `:storefront` result only ever contains price changes (see
  `Source`/`StorefrontClient`), because the Admin API rejected the
  connection's credentials; `:fallback_reason` carries why (e.g.
  `:unauthorized`). Treating it as a full diff would report "no changes"
  for text fields that were never actually compared.

  `opts[:base_locale]` is the locale read for matching/diffing localized
  fields, defaulting to `Translations.default_language/0` — pass it
  explicitly to keep a call free of that default's database access
  (e.g. in tests), same reason `ProductDiff.diff/4` takes it. The rest
  of `opts` (`:admin_options`, `:storefront_options`) is forwarded to
  `Source.fetch/2`.
  """
  @spec check(String.t(), keyword()) ::
          {:ok,
           %{
             changes: [Change.t()],
             source: :admin | :storefront,
             fallback_reason: term() | nil
           }}
          | {:error, term()}
  def check(integration_uuid, opts \\ []) do
    {base_locale, source_opts} =
      Keyword.pop_lazy(opts, :base_locale, &Translations.default_language/0)

    with {:ok, %{source: source, products: products, only: only, fallback_reason: reason}} <-
           Source.fetch(integration_uuid, source_opts) do
      changes = ProductDiff.diff(Shop.list_products(), products, base_locale, only: only)

      {:ok, %{changes: changes, source: source, fallback_reason: reason}}
    end
  end

  @doc """
  Applies fields from `change` to its product.

  `fields` is `:all` (every field in `change.changes`) or an explicit list
  of field atoms — only fields present in BOTH `change.changes` and
  `fields` are written, everything else on the product is left untouched.
  Localized fields (`title`, `body_html`, `description`) are merged into
  the base locale only; other languages already on the product are
  preserved.
  """
  @spec apply_change(Change.t(), :all | [atom()]) ::
          {:ok, PhoenixKitEcommerce.Product.t()} | {:error, Ecto.Changeset.t()}
  def apply_change(%Change{} = change, fields \\ :all) do
    product = Shop.get_product!(change.product_uuid)
    base_locale = Translations.default_language()
    fields_to_apply = resolve_fields(fields, change.changes)

    attrs =
      Enum.reduce(fields_to_apply, %{}, fn field, acc ->
        %{incoming: incoming} = Map.fetch!(change.changes, field)
        Map.merge(acc, build_attr(product, field, incoming, base_locale))
      end)

    Shop.update_product(product, attrs)
  end

  @doc """
  Applies `fields` to every change in `changes`, partitioning them by outcome.

  A changeset failure on one product doesn't stop the rest from being
  attempted. Returns `%{succeeded: [Change.t()], failed: [Change.t()]}`,
  each preserving the input order — so a caller can drop `succeeded` and
  keep offering `failed` for retry instead of reporting them as done.
  """
  @spec apply_changes([Change.t()], :all | [atom()]) :: %{
          succeeded: [Change.t()],
          failed: [Change.t()]
        }
  def apply_changes(changes, fields \\ :all) do
    %{succeeded: succeeded, failed: failed} =
      Enum.reduce(changes, %{succeeded: [], failed: []}, fn change, acc ->
        case apply_change(change, fields) do
          {:ok, _product} -> %{acc | succeeded: [change | acc.succeeded]}
          {:error, _changeset} -> %{acc | failed: [change | acc.failed]}
        end
      end)

    %{succeeded: Enum.reverse(succeeded), failed: Enum.reverse(failed)}
  end

  defp resolve_fields(:all, changes), do: Map.keys(changes)

  defp resolve_fields(fields, changes) when is_list(fields) do
    Enum.filter(fields, &Map.has_key?(changes, &1))
  end

  defp build_attr(product, field, incoming, base_locale) when field in @localized_fields do
    Translations.changeset_attrs(product, field, base_locale, incoming)
  end

  defp build_attr(_product, field, incoming, _base_locale) do
    %{field => incoming}
  end
end
