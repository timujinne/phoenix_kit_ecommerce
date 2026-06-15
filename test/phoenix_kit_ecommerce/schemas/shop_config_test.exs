defmodule PhoenixKitEcommerce.Schemas.ShopConfigTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.ShopConfig

  describe "changeset/2" do
    test "is valid with key and value" do
      cs = ShopConfig.changeset(%ShopConfig{}, %{key: "global", value: %{"options" => []}})
      assert cs.valid?
    end

    test "requires key and value" do
      errors = errors_on(ShopConfig.changeset(%ShopConfig{}, %{}))
      assert "can't be blank" in errors.key
      assert "can't be blank" in errors.value
    end

    test "key max length is 100" do
      cs =
        ShopConfig.changeset(%ShopConfig{}, %{
          key: String.duplicate("k", 101),
          value: %{}
        })

      assert %{key: [_ | _]} = errors_on(cs)
    end

    test "round-trips through the repo (string primary key)" do
      {:ok, inserted} =
        %ShopConfig{}
        |> ShopConfig.changeset(%{key: "demo_key", value: %{"a" => 1}})
        |> Repo.insert()

      assert inserted.key == "demo_key"
      assert Repo.get(ShopConfig, "demo_key").value == %{"a" => 1}
    end
  end
end
