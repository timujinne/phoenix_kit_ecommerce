defmodule PhoenixKitEcommerce.Web.ClaimGettextTest do
  @moduledoc """
  The strings of the claim page and its notices exist in the template and in
  every catalogue, translated everywhere but `en`, and the catalogues parse
  (they are edited by hand, never merged).
  """

  use ExUnit.Case, async: true

  @msgids [
    "An assistant prepared this cart for you",
    "Continue to checkout",
    "You already have items in your cart. What would you like to do?",
    "Replace my cart",
    "Add these items to my cart",
    "This checkout link has already been used or has expired. Your cart is shown here.",
    "Your cart changed while you were deciding. Please choose again.",
    "Some items could not be added because they are no longer available: %{items}",
    "Something went wrong. Your cart was not changed.",
    "Assistant carts",
    "Carts built by an AI assistant through the shop API. The caps limit the notifications about them (0 turns them off). How many new assistant carts one client may open is set on the API settings page.",
    "Days before an idle assistant cart is abandoned",
    "Minutes a checkout link works",
    "Assistant notifications per cart per hour",
    "Assistant notifications per hour, all carts",
    "Assistant cart settings updated",
    "Enter whole numbers within the shown ranges."
  ]

  @gettext Path.expand("../../../priv/gettext", __DIR__)

  defp messages(path) do
    {:ok, po} = Expo.PO.parse_file(path)

    for %Expo.Message.Singular{msgid: id, msgstr: str} <- po.messages, into: %{} do
      {IO.iodata_to_binary(id), IO.iodata_to_binary(str)}
    end
  end

  test "the template has every msgid" do
    template = messages(Path.join(@gettext, "default.pot"))
    for id <- @msgids, do: assert(Map.has_key?(template, id), "#{id} missing from default.pot")
  end

  for locale <- ~w(de et fr ru uk) do
    test "#{locale} translates every msgid and keeps the placeholder" do
      catalogue = messages(Path.join(@gettext, "#{unquote(locale)}/LC_MESSAGES/default.po"))

      for id <- @msgids do
        translated = Map.get(catalogue, id)
        assert translated not in [nil, "", id], "#{unquote(locale)} lacks #{id}"
        assert String.contains?(translated, "%{items}") == String.contains?(id, "%{items}")
      end
    end
  end

  test "en lists every msgid and leaves it untranslated" do
    catalogue = messages(Path.join(@gettext, "en/LC_MESSAGES/default.po"))

    for id <- @msgids do
      assert Map.get(catalogue, id) == "", "en must carry #{id} with an empty msgstr"
    end
  end
end
