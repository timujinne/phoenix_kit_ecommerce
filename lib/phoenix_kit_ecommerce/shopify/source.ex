defmodule PhoenixKitEcommerce.Shopify.Source do
  @moduledoc """
  Picks where a sync reads Shopify product data from: the Admin API
  (primary, full-fidelity) or the public storefront JSON endpoint
  (fallback, price-only — see `PhoenixKitEcommerce.Shopify.StorefrontClient`
  for why it is deliberately narrow).

  Split into a pure decision core (`decide/2`) and a thin I/O shell
  (`fetch/2`) on purpose: this app's test environment has no database
  available, so any test written against `PhoenixKitEcommerce.DataCase`
  is excluded on every run (see `test/test_helper.exs`). `fetch/2` needs
  the database (`PhoenixKit.Integrations.get_credentials/1`), so its
  branches cannot be exercised here. `decide/2` needs none of that, so
  the actual fallback/abort logic lives there and is fully tested.

  Falling back to the storefront is only correct when the Admin API
  failure is about the *credential* — a token that's missing, wrong, or
  no longer authorized. Anything else (a rate limit, a 5xx, a timeout) is
  a transient problem with the Admin API itself; falling back on those
  would silently narrow the sync to price-only and report "no text
  changes" when the truth is "we could not check". Those abort instead.
  """

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.Shopify.AdminClient
  alias PhoenixKitEcommerce.Shopify.StorefrontClient

  # Admin API failures that mean "this token doesn't work" rather than
  # "the Admin API is having a moment". Only these justify falling back
  # to the storefront.
  @credential_errors [:forbidden, :missing_credentials, :unauthorized]

  @type result :: %{
          source: :admin | :storefront,
          products: [map()],
          only: [atom()] | :all,
          fallback_reason: term() | nil
        }

  @doc """
  Decides how to source products, given the Admin API's fetch result and
  an (already looked-up) shop domain.

  Pure — no I/O. Rules:

    * Admin succeeded → `{:use_admin, products}`.
    * Admin failed with a credential error (`:unauthorized`,
      `:missing_credentials`, `:forbidden`) and a shop domain is
      available → `{:use_storefront, reason}`, `reason` being the
      Admin failure that triggered the fallback.
    * Admin failed with a credential error but no shop domain is
      available → `{:abort, reason}` — there is nothing to fall back to.
    * Admin failed with anything else (rate limited, 5xx, timeout, ...)
      → `{:abort, reason}`, regardless of whether a domain is available.
  """
  @spec decide({:ok, [map()]} | {:error, term()}, {:ok, String.t()} | {:error, term()}) ::
          {:use_admin, [map()]} | {:use_storefront, term()} | {:abort, term()}
  def decide({:ok, products}, _shop_domain), do: {:use_admin, products}

  def decide({:error, reason}, {:ok, shop_domain})
      when reason in @credential_errors and is_binary(shop_domain) and shop_domain != "" do
    {:use_storefront, reason}
  end

  def decide({:error, reason}, _shop_domain), do: {:abort, reason}

  @doc """
  Fetches Shopify products for `integration_uuid`, preferring the Admin
  API and falling back to the public storefront per `decide/2`.

  `result.only` travels with the result so a caller doesn't have to
  re-derive it: `:all` for the Admin source, `[:price]` for the
  storefront source — hand it straight to
  `PhoenixKitEcommerce.Shopify.ProductDiff.diff/4`'s `:only` option.

  ## Options

    * `:admin_options` — forwarded to `AdminClient.fetch_products/2`.
    * `:storefront_options` — forwarded to
      `StorefrontClient.fetch_products/2`.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def fetch(integration_uuid, opts \\ []) do
    admin_options = Keyword.get(opts, :admin_options, [])
    storefront_options = Keyword.get(opts, :storefront_options, [])

    admin_result = AdminClient.fetch_products(integration_uuid, admin_options)
    shop_domain = shop_domain(integration_uuid)

    case decide(admin_result, shop_domain) do
      {:use_admin, products} ->
        {:ok, %{source: :admin, products: products, only: :all, fallback_reason: nil}}

      {:use_storefront, reason} ->
        {:ok, domain} = shop_domain
        use_storefront(domain, storefront_options, reason)

      {:abort, reason} ->
        {:error, reason}
    end
  end

  defp use_storefront(domain, storefront_options, reason) do
    case StorefrontClient.fetch_products(domain, storefront_options) do
      {:ok, products} ->
        {:ok, %{source: :storefront, products: products, only: [:price], fallback_reason: reason}}

      {:error, storefront_reason} ->
        {:error, storefront_reason}
    end
  end

  defp shop_domain(integration_uuid) do
    case Integrations.get_credentials(integration_uuid) do
      {:ok, %{"shop_domain" => shop_domain}} when is_binary(shop_domain) and shop_domain != "" ->
        {:ok, shop_domain}

      {:ok, _incomplete} ->
        {:error, :missing_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
