defmodule PhoenixKitEcommerce.Schemas.ImportConfigTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.ImportConfig

  describe "changeset/2 validity and required fields" do
    test "is valid with a name" do
      assert ImportConfig.changeset(%ImportConfig{}, %{name: "general"}).valid?
    end

    test "requires a name" do
      cs = ImportConfig.changeset(%ImportConfig{}, %{})
      assert "can't be blank" in errors_on(cs).name
    end
  end

  describe "category_rules validation" do
    test "accepts well-formed rules" do
      cs =
        ImportConfig.changeset(%ImportConfig{}, %{
          name: "x",
          category_rules: [%{"keywords" => ["vase"], "slug" => "vases"}]
        })

      assert cs.valid?
    end

    test "rejects rules missing slug" do
      cs =
        ImportConfig.changeset(%ImportConfig{}, %{
          name: "x",
          category_rules: [%{"keywords" => ["vase"]}]
        })

      assert %{category_rules: [_ | _]} = errors_on(cs)
    end
  end

  describe "option_mappings validation" do
    test "accepts well-formed mappings" do
      cs =
        ImportConfig.changeset(%ImportConfig{}, %{
          name: "x",
          option_mappings: [%{"csv_name" => "Cup Color", "slot_key" => "cup_color"}]
        })

      assert cs.valid?
    end

    test "rejects mappings missing slot_key" do
      cs =
        ImportConfig.changeset(%ImportConfig{}, %{
          name: "x",
          option_mappings: [%{"csv_name" => "Cup Color"}]
        })

      assert %{option_mappings: [_ | _]} = errors_on(cs)
    end
  end

  # Regression: ImportConfig.changeset/2 now pins the real DB index name
  # `idx_shop_import_configs_name`, so a duplicate-name insert is surfaced as a
  # changeset error instead of raising Ecto.ConstraintError.
  describe "duplicate name" do
    test "returns a changeset error (constraint name matches DB index)" do
      {:ok, _} =
        %ImportConfig{}
        |> ImportConfig.changeset(%{name: "dup-config"})
        |> Repo.insert()

      assert {:error, changeset} =
               %ImportConfig{}
               |> ImportConfig.changeset(%{name: "dup-config"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).name
    end
  end

  describe "keyword list length cap" do
    test "accepts a list at the 100-entry limit" do
      cs =
        ImportConfig.changeset(%ImportConfig{}, %{
          name: "x",
          include_keywords: for(i <- 1..100, do: "kw#{i}")
        })

      assert cs.valid?
    end

    test "rejects an include_keywords list over the limit" do
      cs =
        ImportConfig.changeset(%ImportConfig{}, %{
          name: "x",
          include_keywords: for(i <- 1..101, do: "kw#{i}")
        })

      assert "cannot contain more than 100 entries" in errors_on(cs).include_keywords
    end

    test "rejects an exclude_keywords list over the limit" do
      cs =
        ImportConfig.changeset(%ImportConfig{}, %{
          name: "x",
          exclude_keywords: for(i <- 1..101, do: "kw#{i}")
        })

      assert "cannot contain more than 100 entries" in errors_on(cs).exclude_keywords
    end

    test "rejects an exclude_phrases list over the limit" do
      cs =
        ImportConfig.changeset(%ImportConfig{}, %{
          name: "x",
          exclude_phrases: for(i <- 1..101, do: "phrase #{i}")
        })

      assert "cannot contain more than 100 entries" in errors_on(cs).exclude_phrases
    end
  end

  describe "factory helpers" do
    test "from_legacy_defaults/0 and no_filter_config/0 build valid structs" do
      assert %ImportConfig{is_default: true} = ImportConfig.from_legacy_defaults()
      assert %ImportConfig{skip_filter: true} = ImportConfig.no_filter_config()
    end
  end
end
