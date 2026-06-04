defmodule PhoenixKitEcommerce.Schemas.CategoryTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.Category

  @valid %{"name" => %{"en" => "Electronics"}}

  describe "changeset/2 validity" do
    test "is valid with an English name" do
      assert Category.changeset(%Category{}, @valid).valid?
    end

    test "auto-generates a slug from the name" do
      cs = Category.changeset(%Category{}, @valid)
      assert get_change(cs, :slug) == %{"en" => "electronics"}
    end
  end

  describe "changeset/2 required fields and custom validations" do
    test "requires an English name translation" do
      cs = Category.changeset(%Category{}, %{})
      assert %{name: ["en translation is required"]} = errors_on(cs)
    end

    test "rejects negative position" do
      cs = Category.changeset(%Category{}, Map.put(@valid, "position", -1))
      assert %{position: [_ | _]} = errors_on(cs)
    end

    test "rejects invalid status" do
      cs = Category.changeset(%Category{}, Map.put(@valid, "status", "deleted"))
      assert %{status: ["is invalid"]} = errors_on(cs)
    end

    test "accepts each valid status" do
      for status <- ~w(active unlisted hidden) do
        assert Category.changeset(%Category{}, Map.put(@valid, "status", status)).valid?
      end
    end

    test "category cannot be its own parent" do
      uuid = Ecto.UUID.generate()
      cs = Category.changeset(%Category{uuid: uuid}, Map.put(@valid, "parent_uuid", uuid))
      assert %{parent_uuid: ["cannot be self"]} = errors_on(cs)
    end
  end

  describe "unique slug constraint" do
    test "rejects a second category whose primary slug collides" do
      {:ok, _first} =
        %Category{}
        |> Category.changeset(%{
          "name" => %{"en" => "Unique Cat"},
          "slug" => %{"en" => "dup-slug"}
        })
        |> Repo.insert()

      {:error, cs} =
        %Category{}
        |> Category.changeset(%{
          "name" => %{"en" => "Other Cat"},
          "slug" => %{"en" => "dup-slug"}
        })
        |> Repo.insert()

      # Schema declares unique_constraint(:slug, name: "idx_shop_categories_slug_primary"),
      # which matches the partial UNIQUE INDEX on extract_primary_slug(slug).
      assert %{slug: [_ | _]} = errors_on(cs)
    end
  end

  describe "predicates" do
    test "root?/1" do
      assert Category.root?(%Category{parent_uuid: nil})
      refute Category.root?(%Category{parent_uuid: Ecto.UUID.generate()})
    end

    test "active?/unlisted?/hidden?/1" do
      assert Category.active?(%Category{status: "active"})
      assert Category.unlisted?(%Category{status: "unlisted"})
      assert Category.hidden?(%Category{status: "hidden"})
    end

    test "products_visible?/1 for active and unlisted" do
      assert Category.products_visible?(%Category{status: "active"})
      assert Category.products_visible?(%Category{status: "unlisted"})
      refute Category.products_visible?(%Category{status: "hidden"})
    end

    test "show_in_menu?/1 only for active" do
      assert Category.show_in_menu?(%Category{status: "active"})
      refute Category.show_in_menu?(%Category{status: "unlisted"})
    end
  end
end
