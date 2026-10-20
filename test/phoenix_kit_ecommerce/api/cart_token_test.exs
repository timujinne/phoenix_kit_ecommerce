defmodule PhoenixKitEcommerce.API.CartTokenTest do
  @moduledoc """
  The cart token: random, signed, never stored. A token the server did not
  issue must be indistinguishable from garbage.
  """

  # async: false - the signing secret is application env.
  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.API.CartToken

  setup do
    Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("k", 64))
    on_exit(fn -> Application.delete_env(:phoenix_kit, :secret_key_base) end)
    :ok
  end

  test "a minted token verifies and yields a stable 43-character hash" do
    assert {:ok, token} = CartToken.mint()
    assert byte_size(token) == 66
    assert {:ok, hash} = CartToken.verify(token)
    assert hash == CartToken.digest(token)
    assert byte_size(hash) == 43
    assert CartToken.verify(token) == {:ok, hash}
  end

  test "the hash is core's client_token_hash formula" do
    {:ok, token} = CartToken.mint()

    assert CartToken.digest(token) ==
             token |> then(&:crypto.hash(:sha256, &1)) |> Base.url_encode64(padding: false)
  end

  test "the cart row identity fits the session_id column (varchar 64)" do
    {:ok, token} = CartToken.mint()
    {:ok, hash} = CartToken.verify(token)

    assert CartToken.session_id(hash) == "api:" <> hash
    assert byte_size(CartToken.session_id(hash)) == 47
  end

  test "two tokens differ" do
    {:ok, a} = CartToken.mint()
    {:ok, b} = CartToken.mint()
    refute a == b
  end

  test "empty, truncated, edited, unsigned and oversized tokens do not verify" do
    {:ok, token} = CartToken.mint()
    [random, mac] = String.split(token, ".")

    flipped = String.replace_prefix(token, String.first(token), flip(String.first(token)))

    for bad <- [
          "",
          "x",
          random,
          random <> ".",
          "." <> mac,
          random <> "." <> String.duplicate("A", 22),
          token <> "x",
          String.slice(token, 0..-2//1),
          flipped,
          random <> "." <> mac <> ".extra",
          String.duplicate("a", 5000),
          nil,
          123,
          %{"cart_token" => token}
        ] do
      assert CartToken.verify(bad) == :error, "accepted #{inspect(bad)}"
    end
  end

  # The last character of the random part carries two unused bits, which the
  # decoder ignores: the same 32 bytes could be spelled four ways, and each
  # spelling would be a different cart. Only the spelling that was minted counts.
  test "a respelling of the random part with other unused bits does not verify" do
    {:ok, token} = CartToken.mint()
    [random, mac] = String.split(token, ".")
    {head, last} = String.split_at(random, -1)

    alphabet =
      String.graphemes("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")

    index = Enum.find_index(alphabet, &(&1 == last))
    other_last = Enum.at(alphabet, Bitwise.bxor(index, 1))
    respelled = head <> other_last <> "." <> mac

    # Same bytes after decoding, different text.
    assert Base.url_decode64(head <> other_last, padding: false) ==
             Base.url_decode64(random, padding: false)

    refute respelled == token
    assert CartToken.verify(respelled) == :error
    assert {:ok, _hash} = CartToken.verify(token)
  end

  test "a token minted under another secret does not verify" do
    {:ok, token} = CartToken.mint()
    Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("z", 64))

    assert CartToken.verify(token) == :error
  end

  test "without a secret nothing is minted and nothing is believed" do
    {:ok, token} = CartToken.mint()
    Application.delete_env(:phoenix_kit, :secret_key_base)

    assert CartToken.mint() == {:error, :no_secret}
    assert CartToken.verify(token) == :error
  end

  defp flip("A"), do: "B"
  defp flip(_other), do: "A"
end
