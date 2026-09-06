defmodule PhoenixKitEcommerce.Catalogue.ValueResolverTest do
  @moduledoc """
  `ValueResolver.resolve/3` (2026-09-06 plan, Task 4): Shopify-style raw
  option strings resolved to an attribute set's value slugs, unknown
  values created as `draft`.

  Needs `phoenix_kit_catalogue` AND `phoenix_kit_entities` loaded (with
  their migrations applied to the test DB) — excluded via
  `test_helper.exs`'s `ExUnit.configure(exclude: ...)` whenever the
  optional dependency isn't present, same as every other `:catalogue`
  test in this fork.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  # Quiets the compiler's static xref check for `mix test` runs where the
  # optional `phoenix_kit_catalogue`/`phoenix_kit_entities` dependencies
  # aren't declared — every test in this module is excluded in that case
  # (see `test_helper.exs`), so the calls below are never actually reached.
  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue.AttributeSets}

  alias PhoenixKitCatalogue.Catalogue.AttributeSets
  alias PhoenixKitEcommerce.Catalogue.ValueResolver

  setup do
    # Entities gates on a settings toggle (default false) — same setup
    # `phoenix_kit_catalogue`'s own `AttributeSetsTest` uses.
    AttributeSets.register_deletion_guard()
    PhoenixKit.Settings.update_setting("entities_enabled", "true")
    on_exit(fn -> PhoenixKit.Settings.update_setting("entities_enabled", "false") end)

    {:ok, set} = AttributeSets.create_set(%{name: "Size"}, actor_uuid: Ecto.UUID.generate())

    # Explicit, non-derived slug ("s") deliberately does NOT match
    # `Slug.slugify("Small")` ("small") — this is what lets a test tell
    # the slug-lookup step apart from the label-lookup step below.
    {:ok, small} =
      AttributeSets.create_value(set, %{label: "Small", slug: "s"},
        actor_uuid: Ecto.UUID.generate()
      )

    {:ok, medium} =
      AttributeSets.create_value(set, %{label: "Medium", slug: "medium"},
        actor_uuid: Ecto.UUID.generate()
      )

    %{set: set, small: small, medium: medium}
  end

  describe "resolve/3 — slug match" do
    test "matches an existing value whose stored slug equals slugify(label)" do
      assert ValueResolver.resolve("size", "Medium") == {:ok, "medium"}
    end

    test "matches through the catalogue_set_ prefix too", %{set: set} do
      assert ValueResolver.resolve(set.name, "Medium") == {:ok, "medium"}
    end
  end

  describe "resolve/3 — exact-label match" do
    test "falls back to the value's title when the slug doesn't match" do
      # slugify("Small") == "small", not "s" — so a slug match alone
      # would miss; only the label fallback finds it.
      assert ValueResolver.resolve("size", "Small") == {:ok, "s"}
    end

    test "collapses whitespace before comparing labels" do
      assert ValueResolver.resolve("size", "  Small   ") == {:ok, "s"}
    end
  end

  describe "resolve/3 — miss creates a draft value" do
    test "creates a new value and returns {:created, slug}" do
      assert {:created, slug} = ValueResolver.resolve("size", "Extra Large")
      assert slug == "extra-large"
    end

    test "the created value's status is draft, not published", %{set: set} do
      {:created, slug} = ValueResolver.resolve("size", "Extra Large")

      created = set |> AttributeSets.list_values() |> Enum.find(&(&1.slug == slug))
      assert created.status == "draft"
      assert created.title == "Extra Large"
    end

    test "resolving the same raw label again finds the draft instead of duplicating", %{
      set: set
    } do
      assert {:created, slug} = ValueResolver.resolve("size", "Extra Large")
      assert ValueResolver.resolve("size", "Extra Large") == {:ok, slug}

      matches = set |> AttributeSets.list_values() |> Enum.filter(&(&1.slug == slug))
      assert length(matches) == 1
    end
  end

  describe "resolve/3 — set not found" do
    test "returns {:error, :set_not_found} for an unknown set slug", %{set: _set} do
      assert ValueResolver.resolve("no-such-set", "Small") == {:error, :set_not_found}
    end
  end

  describe "resolve_many/3 — one set/values read for the whole batch (review fix)" do
    test "resolves several labels, matching resolve/3 label-by-label" do
      assert ValueResolver.resolve_many("size", ["Medium", "Small", "Large"]) == %{
               "Medium" => {:ok, "medium"},
               "Small" => {:ok, "s"},
               "Large" => {:created, "large"}
             }
    end

    test "two distinct new labels in the SAME call both persist (no re-fetch masks either)", %{
      set: set
    } do
      results = ValueResolver.resolve_many("size", ["X-Large", "XL"])

      assert {:created, xl_slug} = results["X-Large"]
      assert {:created, _other_slug} = results["XL"]

      values = AttributeSets.list_values(set)
      assert Enum.count(values, &(&1.slug == xl_slug)) == 1
    end

    test "duplicate raw labels in one call collapse to a single lookup/create", %{set: set} do
      assert ValueResolver.resolve_many("size", ["Gold", "Gold"]) == %{
               "Gold" => {:created, "gold"}
             }

      values = AttributeSets.list_values(set)
      assert Enum.count(values, &(&1.slug == "gold")) == 1
    end

    test "returns :set_not_found for every label when the set doesn't exist" do
      assert ValueResolver.resolve_many("no-such-set", ["A", "B"]) == %{
               "A" => {:error, :set_not_found},
               "B" => {:error, :set_not_found}
             }
    end
  end
end
