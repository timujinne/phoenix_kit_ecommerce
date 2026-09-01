defmodule PhoenixKitEcommerce.Shopify.Source do
  @moduledoc """
  Picks where a sync reads Shopify product data from: the Admin API
  (primary, full-fidelity) or the public storefront JSON endpoint
  (fallback, price-only — see `PhoenixKitEcommerce.Shopify.StorefrontClient`
  for why it is deliberately narrow).

  Split into a pure decision core (`decide/2`) and a thin I/O shell
  (`fetch/2`). That split is not, on its own, a testability necessity in
  this repo — `test/test_helper.exs` excludes `DataCase` tests only when
  no test database is reachable, and one normally is (`createdb
  phoenix_kit_ecommerce_test`; see that file for details). It earns its
  place anyway: the fallback/abort *decision* — which is the one property
  worth being certain about, since getting it wrong either silently
  narrows a sync to price-only or leaves it stuck on a dead token — is
  fully expressible without a domain lookup, an HTTP call, or a database,
  so keeping it in a pure function makes every branch a plain data-in,
  data-out assertion instead of an HTTP-stub scenario.

  Falling back to the storefront is only correct when the Admin API
  failure is about the *credential* — a token that's missing, wrong, or
  no longer authorized. Anything else (a rate limit, a 5xx, a timeout) is
  a transient problem with the Admin API itself; falling back on those
  would silently narrow the sync to price-only and report "no text
  changes" when the truth is "we could not check". Those abort instead.
  """

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.Shopify.AdminClient
  alias PhoenixKitEcommerce.Shopify.ProductDiff
  alias PhoenixKitEcommerce.Shopify.StorefrontClient

  # Admin API failures that mean "this token doesn't work" rather than
  # "the Admin API is having a moment". Only these justify falling back
  # to the storefront.
  @credential_errors [:forbidden, :missing_credentials, :unauthorized]

  # The storefront JSON endpoint only ever carries price (see
  # `StorefrontClient`'s moduledoc for why that narrowness is deliberate)
  # — this is the `:only` `PhoenixKitEcommerce.Shopify.ProductDiff.diff/4`
  # must be called with whenever `source == :storefront`.
  @storefront_fields [:price]

  @type result :: %{
          source: :admin | :storefront,
          products: [map()],
          only: [atom()],
          fallback_reason: term() | nil
        }

  @doc """
  Decides how to source products, given the Admin API's fetch result and
  an (already looked-up) shop domain, and what field set the resulting
  products carry.

  Pure — no I/O. Rules:

    * Admin succeeded → `{:use_admin, products, only}`, `only` being
      `ProductDiff.comparable_fields/0` — the Admin API carries every
      field.
    * Admin failed with a credential error (`:unauthorized`,
      `:missing_credentials`, `:forbidden`) and a shop domain is
      available → `{:use_storefront, domain, reason, only}` — `reason`
      is the Admin failure that triggered the fallback, `only` is
      `[:price]`.
    * Admin failed with a credential error but no shop domain is
      available → `{:abort, reason}` — there is nothing to fall back to.
    * Admin failed with anything else (rate limited, 5xx, timeout, ...)
      → `{:abort, reason}`, regardless of whether a domain is available.
  """
  @spec decide({:ok, [map()]} | {:error, term()}, {:ok, String.t()} | {:error, term()}) ::
          {:use_admin, [map()], [atom()]}
          | {:use_storefront, String.t(), term(), [atom()]}
          | {:abort, term()}
  def decide({:ok, products}, _shop_domain) do
    {:use_admin, products, ProductDiff.comparable_fields()}
  end

  def decide({:error, reason}, {:ok, shop_domain})
      when reason in @credential_errors and is_binary(shop_domain) and shop_domain != "" do
    {:use_storefront, shop_domain, reason, @storefront_fields}
  end

  def decide({:error, reason}, _shop_domain), do: {:abort, reason}

  @doc """
  Fetches Shopify products for `integration_uuid`, preferring the Admin
  API and falling back to the public storefront per `decide/2`.

  `result.only` travels with the result so a caller doesn't have to
  re-derive it: `ProductDiff.comparable_fields/0` for the Admin source,
  `[:price]` for the storefront source — hand it straight to
  `ProductDiff.diff/4`'s `:only` option.

  The shop domain is only looked up when the Admin API actually failed —
  `decide/2` never needs it on the success path (see its first clause),
  so this is meant to spare a successful sync a second
  `PhoenixKit.Integrations.get_credentials/1` call it would otherwise
  make and discard. That is the intent, not a pinned guarantee: nothing
  in this suite currently asserts the call count.

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

    admin_result
    |> decide(shop_domain_if_needed(admin_result, integration_uuid))
    |> resolve(storefront_options)
  end

  # `decide/2` ignores its second argument whenever the first is
  # `{:ok, _}` (see its first clause) — so on the Admin success path
  # there is nothing to look up, and doing so anyway would mean every
  # successful sync pays for a database read it always discards.
  defp shop_domain_if_needed({:ok, _admin_products}, _integration_uuid), do: {:error, :not_needed}

  defp shop_domain_if_needed({:error, _reason}, integration_uuid),
    do: shop_domain(integration_uuid)

  defp resolve({:use_admin, products, only}, _storefront_options) do
    {:ok, build_result(:admin, products, only, nil)}
  end

  defp resolve({:use_storefront, domain, reason, only}, storefront_options) do
    case StorefrontClient.fetch_products(domain, storefront_options) do
      {:ok, products} -> {:ok, build_result(:storefront, products, only, reason)}
      {:error, storefront_reason} -> {:error, storefront_reason}
    end
  end

  defp resolve({:abort, reason}, _storefront_options), do: {:error, reason}

  defp build_result(source, products, only, fallback_reason) do
    %{source: source, products: products, only: only, fallback_reason: fallback_reason}
  end

  defp shop_domain(integration_uuid) do
    case Integrations.get_credentials(integration_uuid) do
      {:ok, %{"shop_domain" => shop_domain}} when is_binary(shop_domain) and shop_domain != "" ->
        {:ok, shop_domain}

      # Reachable, not defensive: `Integrations.has_credentials?/1` (core)
      # treats a present, non-empty `access_token` as sufficient on its
      # own — it short-circuits on `present?(data["access_token"])` before
      # it ever checks which fields this provider marks required. So a
      # connection saved with a token and a blank/absent shop domain still
      # resolves to `{:ok, data}` here, not `{:error, :not_configured}`.
      # An operator who pastes the token and leaves the domain field empty
      # reaches this exact branch (see `SourceFetchTest` for the case that
      # proves it).
      {:ok, _incomplete} ->
        {:error, :missing_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
