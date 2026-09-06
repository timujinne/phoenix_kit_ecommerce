defmodule PhoenixKitEcommerce.Catalogue.SetSlugTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Catalogue.SetSlug

  describe "normalise/1" do
    test "downcases and joins words with underscores" do
      assert SetSlug.normalise("Cup Color") == "cup_color"
    end

    test "collapses punctuation runs to a single underscore" do
      assert SetSlug.normalise("Size!!") == "size"
      assert SetSlug.normalise("Größe/Size") == "gr_e_size"
    end

    test "trims leading and trailing underscores" do
      assert SetSlug.normalise("  Size  ") == "size"
    end

    test "already-slug input passes through unchanged" do
      assert SetSlug.normalise("liquid_color") == "liquid_color"
    end
  end
end
