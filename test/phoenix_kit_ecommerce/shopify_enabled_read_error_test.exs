defmodule PhoenixKitEcommerce.ShopifyEnabledReadErrorTest do
  @moduledoc """
  `shopify_enabled?/0` fails closed. The `:shopify_setting_reader` seam
  makes the settings read raise or exit, which reaches the `rescue` and
  `catch` clauses of `shopify_enabled?/0` itself.

  The last test does not use the seam. With no sandbox connection checked
  out a real read fails, but core's `get_setting_cached/2` swallows that and
  returns the default, so that test pins the `"false"` default under a
  failing read, not the module's own clauses.
  """

  use ExUnit.Case, async: false

  defmodule Reader do
    @moduledoc false
    def raise_error(_key, _default), do: raise("settings read failed")
    def exit_error(_key, _default), do: exit(:settings_unavailable)
    def stored_true(_key, _default), do: "true"
  end

  setup do
    on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :shopify_setting_reader) end)
  end

  defp use_reader(fun),
    do: Application.put_env(:phoenix_kit_ecommerce, :shopify_setting_reader, {Reader, fun})

  test "a raising settings read answers false" do
    use_reader(:raise_error)
    refute PhoenixKitEcommerce.shopify_enabled?()
  end

  test "an exiting settings read answers false" do
    use_reader(:exit_error)
    refute PhoenixKitEcommerce.shopify_enabled?()
  end

  test "the seam is live: a reader answering \"true\" enables Shopify" do
    use_reader(:stored_true)
    assert PhoenixKitEcommerce.shopify_enabled?()
  end

  test "the default stays false when the real settings read fails (no sandbox connection)" do
    refute PhoenixKitEcommerce.shopify_enabled?()
  end
end
