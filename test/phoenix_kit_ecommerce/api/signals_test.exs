defmodule PhoenixKitEcommerce.API.SignalsTest do
  @moduledoc """
  One capped "via assistant" message per API write: the toggles, the per-cart
  and global hourly caps, the dropped-signal note, and the guarantee that a
  broken notification layer never fails a write.
  """

  # async: false - settings and the Hammer counters are shared.
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Signals

  @first "shop.cart_first_item_added"
  @every "shop.cart_item_added"

  setup do
    ensure_currencies!()
    owner = fixture_user()
    reset_signal_counters!()
    %{owner: owner}
  end

  defp toggles(first, every) do
    {:ok, _} =
      Settings.update_setting_with_module("shop_notify_cart_first_item", to_string(first), "shop")

    {:ok, _} =
      Settings.update_setting_with_module("shop_notify_cart_item", to_string(every), "shop")
  end

  # A cart with one line, so `cart_totals/1` has a subtotal to print.
  defp cart!(owner) do
    {:ok, cart} = Shop.create_cart(user_uuid: owner.uuid)
    {:ok, cart} = Shop.add_to_cart(cart, product!(), 1, via: :assistant)
    Repo.get!(PhoenixKitEcommerce.Cart, cart.uuid)
  end

  defp lines(titles), do: Enum.map(titles, &%{title: &1, quantity: 1})

  test "sends one message, worded via assistant, with the lines and the total", %{owner: owner} do
    toggles(true, false)
    cart = cart!(owner)

    assert :ok =
             Signals.cart_changed(cart, [
               %{title: "Widget A", quantity: 2},
               %{title: "Widget B", quantity: 1}
             ])

    assert [text] = notification_texts_for_action(@first)
    assert text =~ "New cart started via assistant"
    assert text =~ "Widget A ×2"
    assert text =~ "Widget B ×1"
    assert text =~ "USD"
    assert notifications_for_action(@every) == []
  end

  test "the first-item message is sent once per cart; later writes use the every-add toggle", %{
    owner: owner
  } do
    toggles(true, false)
    cart = cart!(owner)

    Signals.cart_changed(cart, lines(["One"]))
    Signals.cart_changed(cart, lines(["Two"]))
    assert count_notifications(@first) == 1
    assert count_notifications(@every) == 0

    toggles(true, true)
    Signals.cart_changed(cart, lines(["Three"]))
    assert count_notifications(@first) == 1
    assert count_notifications(@every) == 1
    assert [text] = notification_texts_for_action(@every)
    assert text =~ "Cart updated via assistant"
  end

  test "a 50-line write is one message that shows three lines and counts the rest", %{
    owner: owner
  } do
    toggles(true, false)
    cart = cart!(owner)

    Signals.cart_changed(cart, lines(for n <- 1..50, do: "Item #{n}"))

    assert [text] = notification_texts_for_action(@first)
    assert text =~ "Item 1 ×1, Item 2 ×1, Item 3 ×1"
    assert text =~ "(+47 more lines)"
    refute text =~ "Item 4 "
  end

  test "long and non-ASCII titles are cut on characters, not bytes", %{owner: owner} do
    toggles(true, false)
    cart = cart!(owner)

    Signals.cart_changed(cart, lines([String.duplicate("é", 60), "Straußenei Vase"]))

    assert [text] = notification_texts_for_action(@first)
    assert text =~ String.duplicate("é", 40) <> "…"
    assert text =~ "Straußenei Vase"
    assert String.valid?(text)
  end

  test "with both toggles off nothing is sent and no budget is spent", %{owner: owner} do
    put_setting!("api_signal_per_cart_per_hour", 1)
    put_setting!("api_signal_global_per_hour", 1)
    toggles(false, false)
    cart = cart!(owner)

    for _ <- 1..3, do: Signals.cart_changed(cart, lines(["Quiet"]))
    assert count_notifications(@first) + count_notifications(@every) == 0

    toggles(true, false)
    Signals.cart_changed(cart, lines(["Loud"]))
    assert count_notifications(@first) == 1
  end

  test "no lines, no message", %{owner: owner} do
    toggles(true, true)
    cart = cart!(owner)

    assert :ok = Signals.cart_changed(cart, [])
    assert count_notifications(@first) + count_notifications(@every) == 0
  end

  test "the per-cart cap holds", %{owner: owner} do
    toggles(false, true)
    put_setting!("api_signal_per_cart_per_hour", 2)
    cart = cart!(owner)

    for n <- 1..4, do: Signals.cart_changed(cart, lines(["Write #{n}"]))

    assert count_notifications(@every) == 2

    # The two writes the cap dropped are not "more assistant carts".
    Signals.cart_changed(cart!(owner), lines(["Another cart"]))

    texts = notification_texts_for_action(@every)
    assert length(texts) == 3
    refute Enum.any?(texts, &(&1 =~ "more assistant carts"))
  end

  test "a cap of zero silences assistant messages", %{owner: owner} do
    toggles(true, true)
    put_setting!("api_signal_per_cart_per_hour", 0)
    cart = cart!(owner)

    Signals.cart_changed(cart, lines(["Silent"]))

    assert count_notifications(@first) + count_notifications(@every) == 0
  end

  test "the global cap holds, and the next message that goes out counts what was dropped", %{
    owner: owner
  } do
    toggles(true, false)
    put_setting!("api_signal_global_per_hour", 1)
    {a, b, c} = {cart!(owner), cart!(owner), cart!(owner)}

    Signals.cart_changed(a, lines(["A"]))
    Signals.cart_changed(b, lines(["B"]))
    assert count_notifications(@first) == 1

    put_setting!("api_signal_global_per_hour", 10)
    Signals.cart_changed(c, lines(["C"]))

    assert count_notifications(@first) == 2
    texts = notification_texts_for_action(@first)
    assert Enum.any?(texts, &(&1 =~ "(+1 more assistant carts)"))
    assert Enum.count(texts, &(&1 =~ "more assistant carts")) == 1

    # A drop is named once: the message after that one does not repeat it.
    Signals.cart_changed(cart!(owner), lines(["D"]))

    assert count_notifications(@first) == 3
    texts = notification_texts_for_action(@first)
    assert Enum.count(texts, &(&1 =~ "more assistant carts")) == 1
  end

  test "a global cap of zero silences messages and is not counted as dropped", %{owner: owner} do
    toggles(true, true)
    put_setting!("api_signal_global_per_hour", 0)

    for n <- 1..3, do: Signals.cart_changed(cart!(owner), lines(["Off #{n}"]))
    assert count_notifications(@first) + count_notifications(@every) == 0

    put_setting!("api_signal_global_per_hour", 10)
    Signals.cart_changed(cart!(owner), lines(["On"]))

    texts = notification_texts_for_action(@first)
    assert length(texts) == 1
    refute Enum.any?(texts, &(&1 =~ "more assistant carts"))
  end

  test "a cart that cannot even be keyed never fails the write", %{owner: _owner} do
    toggles(true, true)

    assert :ok =
             Signals.cart_changed(
               %{uuid: nil, metadata: %{}, subtotal: nil, currency: nil},
               lines(["X"])
             )
  end
end
