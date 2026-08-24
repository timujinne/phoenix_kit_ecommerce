defmodule PhoenixKitEcommerce.Shopify.AdminClient do
  @moduledoc """
  Thin REST client for the Shopify Admin API's `products.json` endpoint.

  Resolves the shop domain and access token from the `PhoenixKit.Integrations`
  connection identified by `integration_uuid` — never from application env
  (see `PhoenixKitEcommerce.Shopify.Provider` for why). Authenticates with
  the `X-Shopify-Access-Token` header, NOT `Authorization: Bearer` — that is
  what the REST Admin API expects for a Custom App's static token.
  """

  require Logger

  alias PhoenixKit.Integrations

  # Shopify deprecates REST Admin API versions roughly a year after release
  # (see https://shopify.dev/docs/api/usage/versioning) — this needs
  # periodic bumping to a currently-supported stable version.
  @api_version "2025-01"

  @page_limit 250
  @product_fields ~w(id handle title body_html vendor product_type tags status images variants)
  @max_retries 5

  @doc """
  Fetches every product from the Shopify store connected via
  `integration_uuid`, following `Link: rel="next"` pagination.

  ## Options

    * `:req_options` — keyword list merged into `Req.new/1` (e.g. `plug:`
      to stub the transport in tests).
  """
  @spec fetch_products(String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def fetch_products(integration_uuid, opts \\ []) do
    case Integrations.get_credentials(integration_uuid) do
      {:ok, %{"shop_domain" => shop_domain, "access_token" => access_token}}
      when is_binary(shop_domain) and shop_domain != "" and
             is_binary(access_token) and access_token != "" ->
        req = build_req(access_token, Keyword.get(opts, :req_options, []))
        fetch_all(req, initial_url(shop_domain), [], @max_retries)

      {:ok, _incomplete} ->
        {:error, :missing_credentials}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp initial_url(shop_domain) do
    query =
      URI.encode_query(%{"limit" => @page_limit, "fields" => Enum.join(@product_fields, ",")})

    "https://#{shop_domain}/admin/api/#{@api_version}/products.json?" <> query
  end

  defp build_req(access_token, req_options) do
    [headers: [{"x-shopify-access-token", access_token}], retry: false]
    |> Keyword.merge(req_options)
    |> Req.new()
  end

  defp fetch_all(_req, nil, acc, _retries_left), do: {:ok, Enum.reverse(acc)}

  defp fetch_all(req, url, acc, retries_left) do
    case Req.get(req, url: url) do
      {:ok, %{status: 200, body: %{"products" => products}} = response} ->
        fetch_all(req, next_page_url(response), Enum.reverse(products, acc), @max_retries)

      {:ok, %{status: 429} = response} when retries_left > 0 ->
        retry_after = retry_after_seconds(response)
        Process.sleep(:timer.seconds(retry_after))
        fetch_all(req, url, acc, retries_left - 1)

      {:ok, %{status: 429}} ->
        {:error, :rate_limited}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 404}} ->
        {:error, :shop_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp next_page_url(response) do
    case response_header(response, "link") do
      nil -> nil
      link -> parse_next_link(link)
    end
  end

  defp parse_next_link(link_header) do
    case Regex.run(~r/<([^>]+)>;\s*rel="next"/, link_header) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp retry_after_seconds(response) do
    with value when is_binary(value) <- response_header(response, "retry-after"),
         {seconds, _} <- Integer.parse(value) do
      seconds
    else
      _ -> 1
    end
  end

  defp response_header(%{headers: headers}, name) do
    headers
    |> Enum.find_value(fn {key, value} ->
      if String.downcase(to_string(key)) == name, do: value
    end)
    |> List.wrap()
    |> List.first()
  end
end
