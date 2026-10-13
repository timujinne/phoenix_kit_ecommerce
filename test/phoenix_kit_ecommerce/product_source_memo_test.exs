defmodule PhoenixKitEcommerce.ProductSourceMemoTest do
  @moduledoc """
  `ProductSource.current/0` is asked several times per storefront mount.
  It reads the config row once per process per interval.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ShopConfig
  alias PhoenixKitEcommerce.Test.Repo

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :product_source_memo_ms)

    on_exit(fn ->
      Application.put_env(:phoenix_kit_ecommerce, :product_source_memo_ms, previous)
    end)

    :ok
  end

  defp memo(ms), do: Application.put_env(:phoenix_kit_ecommerce, :product_source_memo_ms, ms)

  defp set_source(value),
    do: Repo.insert!(%ShopConfig{key: "shop_product_source", value: %{"value" => value}})

  describe "with the catalogue loaded" do
    @describetag :catalogue

    test "a switch is not re-read inside the interval, and is after it" do
      memo(150)
      assert ProductSource.current() == ProductSource.Legacy

      set_source("catalogue")
      assert ProductSource.current() == ProductSource.Legacy

      Process.sleep(200)
      assert ProductSource.current() == ProductSource.Catalogue
    end

    test "another process reads for itself" do
      memo(60_000)
      assert ProductSource.current() == ProductSource.Legacy
      set_source("catalogue")

      parent = self()

      task =
        Task.async(fn ->
          Sandbox.allow(Repo, parent, self())
          ProductSource.current()
        end)

      assert Task.await(task) == ProductSource.Catalogue
      assert ProductSource.current() == ProductSource.Legacy
    end
  end
end
