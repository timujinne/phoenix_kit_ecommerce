defmodule PhoenixKitEcommerce.Shopify.ShopDomain do
  @moduledoc """
  The one rule for what a connection's `shop_domain` may be.

  The value is typed by an operator and interpolated into the URL every
  request goes to, the Admin API ones with the access token attached. It is
  therefore accepted only as a bare `<store>.myshopify.com` hostname: Shopify
  serves the Admin API on that domain alone (a store's custom domain does
  not), and anything looser — a port, a path, a fragment, another host —
  would point those requests, token included, wherever the value says.
  """

  @pattern ~r/\A[a-z0-9][a-z0-9-]{0,61}\.myshopify\.com\z/

  @doc """
  Returns the normalized (trimmed, lower-case) hostname, or
  `{:error, :invalid_shop_domain}`.
  """
  @spec validate(term()) :: {:ok, String.t()} | {:error, :invalid_shop_domain}
  def validate(value) when is_binary(value) do
    host = value |> String.trim() |> String.downcase()

    if Regex.match?(@pattern, host), do: {:ok, host}, else: {:error, :invalid_shop_domain}
  end

  def validate(_value), do: {:error, :invalid_shop_domain}

  @doc """
  Whether `url` is an `https` URL on exactly `host` (default port, no
  credentials) — the test a pagination link has to pass before a request
  carrying the access token follows it.
  """
  @spec same_host?(term(), String.t()) :: boolean()
  def same_host?(url, host) when is_binary(url) and is_binary(host) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: ^host, port: 443, userinfo: nil}} -> true
      _ -> false
    end
  end

  def same_host?(_url, _host), do: false
end
