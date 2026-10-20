defmodule PhoenixKitEcommerce.API.CartToken do
  @moduledoc """
  The cart token of the public API: 32 random bytes plus a short HMAC,
  `<43 chars>.<22 chars>` in base64url. It is a bearer credential, **never
  stored**; only its digest is, as part of the cart's `session_id`.

  The MAC lets the server tell a token it issued from a guess: a guess is
  `cart_not_found`, a token with no row yet is an empty open cart. The key is
  `secret_key_base` (`PhoenixKit.Config`, else the parent endpoint's); without
  one nothing is minted and nothing is believed.

  `digest/1` is the same function core's executor applies to the raw token to
  fill `actor.client_token_hash` (`cart_token_hash` in a core before the
  module-neutral API); the cart row's identity is `"api:" <> digest` (47
  characters, so it fits `phoenix_kit_shop_carts.session_id`, which is
  `varchar(64)`).
  """

  alias PhoenixKit.Config

  @random_bytes 32
  @mac_bytes 16
  @domain "phoenix_kit_ecommerce:api_cart_token:"

  @doc "Mints a signed token. Fails closed without a signing secret."
  @spec mint() :: {:ok, String.t()} | {:error, :no_secret}
  def mint do
    with {:ok, secret} <- secret() do
      random = :crypto.strong_rand_bytes(@random_bytes)
      {:ok, encode(random) <> "." <> encode(mac(secret, random))}
    end
  end

  @doc """
  Checks the shape and the MAC. Returns the token's digest, or `:error` for
  anything else (wrong type, length, characters, MAC, secret).
  """
  @spec verify(term()) :: {:ok, String.t()} | :error
  def verify(token) when is_binary(token) and byte_size(token) == 66 do
    with [random_text, mac_text] <- String.split(token, "."),
         {:ok, random} when byte_size(random) == @random_bytes <-
           Base.url_decode64(random_text, padding: false),
         true <- encode(random) == random_text,
         {:ok, secret} <- secret(),
         true <- Plug.Crypto.secure_compare(encode(mac(secret, random)), mac_text) do
      {:ok, digest(token)}
    else
      _ -> :error
    end
  end

  def verify(_other), do: :error

  @doc "`Base.url_encode64(sha256(value), padding: false)`: core's cart token hash."
  @spec digest(String.t()) :: String.t()
  def digest(value) when is_binary(value) do
    :sha256 |> :crypto.hash(value) |> Base.url_encode64(padding: false)
  end

  @doc "The `phoenix_kit_shop_carts.session_id` of the cart behind a token hash."
  @spec session_id(String.t()) :: String.t()
  def session_id(hash) when is_binary(hash), do: "api:" <> hash

  defp mac(secret, random) do
    :hmac
    |> :crypto.mac(:sha256, secret, @domain <> random)
    |> binary_part(0, @mac_bytes)
  end

  defp encode(binary), do: Base.url_encode64(binary, padding: false)

  defp secret do
    case Config.get(:secret_key_base, nil) || endpoint_secret() do
      secret when is_binary(secret) and byte_size(secret) >= 32 -> {:ok, secret}
      _ -> {:error, :no_secret}
    end
  end

  defp endpoint_secret do
    case Config.get_parent_endpoint() do
      {:ok, endpoint} -> endpoint.config(:secret_key_base)
      :error -> nil
    end
  rescue
    _ -> nil
  end
end
