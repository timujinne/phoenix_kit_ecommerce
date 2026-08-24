defmodule PhoenixKitEcommerce.ShippingMethodSlugTest do
  @moduledoc """
  Shipping-method slugs after adopting core's `Slug.put_slug/3`.

  The local generator keyed on `get_change(:name)` — renaming a method moved
  its slug — and its slugify was ASCII-only, so a Cyrillic name wrote `""`,
  and the unique index then locked every later Cyrillic-named method out:
  the same shape as the product empty-slug bug fixed alongside this.
  """
  use PhoenixKitEcommerce.DataCase, async: true

  alias Ecto.Changeset
  alias PhoenixKitEcommerce.ShippingMethod

  defp changeset(attrs, method \\ %ShippingMethod{}) do
    ShippingMethod.changeset(method, Map.merge(%{"price" => 5, "currency" => "EUR"}, attrs))
  end

  test "a Cyrillic name yields a romanized slug, not an empty one" do
    cs = changeset(%{"name" => "Курьер по городу"})

    slug = Changeset.get_change(cs, :slug)
    assert is_binary(slug) and slug != ""
    assert slug =~ ~r/^[a-z0-9-]+$/
  end

  test "renaming does not move an existing slug" do
    existing = %ShippingMethod{name: "Old", slug: "old"}
    cs = changeset(%{"name" => "Renamed"}, existing)

    assert Changeset.get_change(cs, :slug) == nil
    assert Changeset.get_field(cs, :slug) == "old"
  end

  test "a name collision suffixes -2 instead of a constraint error" do
    {:ok, first} = %{"name" => "Express"} |> changeset() |> Repo.insert()
    {:ok, second} = %{"name" => "Express"} |> changeset() |> Repo.insert()

    assert first.slug == "express"
    assert second.slug == "express-2"
  end

  test "a generated slug respects the 100-character cap, suffix included" do
    long = String.duplicate("a", 150)
    {:ok, first} = %{"name" => long} |> changeset() |> Repo.insert()
    {:ok, second} = %{"name" => long} |> changeset() |> Repo.insert()

    assert String.length(first.slug) <= 100
    assert String.ends_with?(second.slug, "-2")
    assert String.length(second.slug) <= 100
  end

  test "a CJK-only name gets a fallback slug — the column is NOT NULL" do
    # put_slug leaves the field alone when slugify returns "". Without a
    # fallback the insert raises not_null_violation. Two different names
    # must both insert, with distinct hashes, never "".
    {:ok, first} = %{"name" => "店舗受取"} |> changeset() |> Repo.insert()
    {:ok, second} = %{"name" => "宅配便"} |> changeset() |> Repo.insert()

    assert first.slug =~ ~r/^item-[0-9a-f]{10}$/
    assert second.slug =~ ~r/^item-[0-9a-f]{10}$/
    refute first.slug == second.slug
  end

  test "two identical CJK names suffix rather than colliding" do
    {:ok, first} = %{"name" => "店舗受取"} |> changeset() |> Repo.insert()
    {:ok, second} = %{"name" => "店舗受取"} |> changeset() |> Repo.insert()

    assert String.ends_with?(second.slug, "-2")
    assert String.length(second.slug) <= 100
    refute first.slug == second.slug
  end
end
