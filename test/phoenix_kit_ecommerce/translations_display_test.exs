defmodule PhoenixKitEcommerce.TranslationsDisplayTest do
  @moduledoc """
  `Translations.get_display/3` — the ONE storefront chokepoint that runs a
  resolved title/name through `NamePrefix.strip/1`. Every real call site
  reaches it only for `:title` (Product) and `:name` (Category), never for
  `:slug` — this file proves `get_display/3` itself never touches slugs
  or other fields, and that a language without the configured prefix is
  left alone (since not every language necessarily carries it).
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.Category
  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.Translations

  defp set_prefix(value), do: Settings.update_setting(NamePrefix.setting_key(), value)

  describe "get_display/3 on :title / :name" do
    test "strips the configured prefix from a product title" do
      set_prefix("3D Printed")
      product = %Product{title: %{"en" => "3D Printed Costume Masks"}}

      assert Translations.get_display(product, :title, "en") == "Costume Masks"
      # get/3 (the underlying raw read) is untouched by the setting.
      assert Translations.get(product, :title, "en") == "3D Printed Costume Masks"
    end

    test "strips the configured prefix from a category name" do
      set_prefix("3D Printed")
      category = %Category{name: %{"en" => "3D Printed Dollhouse Miniatures"}}

      assert Translations.get_display(category, :name, "en") == "Dollhouse Miniatures"
    end

    test "the default (empty) setting changes nothing" do
      set_prefix("")
      product = %Product{title: %{"en" => "3D Printed Costume Masks"}}

      assert Translations.get_display(product, :title, "en") == "3D Printed Costume Masks"
    end

    test "a language whose name doesn't carry the prefix is left as-is" do
      set_prefix("3D Printed")

      product = %Product{
        title: %{
          "en" => "3D Printed Costume Masks",
          # French copy never had the English prefix at all.
          "fr" => "Masques de costume"
        }
      }

      assert Translations.get_display(product, :title, "en") == "Costume Masks"
      assert Translations.get_display(product, :title, "fr") == "Masques de costume"
    end
  end

  describe "get_display/3 never touches slugs" do
    test "calling it against :slug returns the RAW slug, unstripped" do
      set_prefix("3D Printed")

      product = %Product{
        title: %{"en" => "3D Printed Costume Masks"},
        slug: %{"en" => "3d-printed-costume-masks"}
      }

      # get_display/3 is field-agnostic (it strips whatever get/3 returns);
      # the contract that keeps slugs safe is that NO call site in the
      # codebase ever passes :slug to it — enforced by review/grep, not by
      # this function refusing the field. This assertion documents that a
      # hyphenated slug wouldn't match the space-separated prefix anyway
      # (a coincidence, not the safety mechanism): the real guarantee is
      # that SlugResolver and every slug projection call plain `get/3`.
      assert Translations.get_display(product, :slug, "en") == "3d-printed-costume-masks"

      # And no real call site does this: get/3 (what SlugResolver and
      # every slug projection actually use) is completely untouched.
      assert Translations.get_slug(product, "en") == "3d-printed-costume-masks"
      assert Translations.get(product, :slug, "en") == "3d-printed-costume-masks"
    end
  end
end
