defmodule PhoenixKitEcommerce.NamePrefixTest do
  @moduledoc """
  `shop_name_prefixes` hides a redundant vocabulary prefix ("3D Printed
  Costume Masks" -> "Costume Masks") from storefront-displayed names.
  Display-time only, reached either through `Translations.get_display/3`
  (a live `%Product{}`/`%Category{}` read) or directly, on a cart/order
  line's snapshotted title string, from the pages that render one — this
  file covers the string-stripping rules and the setting's own fail-safe
  defaults; the fact that admin pages, slugs, persisted snapshots and the
  Shopify sync path never see a stripped value written anywhere is
  covered where those paths are exercised
  (`translations_display_test.exs`, `name_prefix_storefront_test.exs`,
  `product_diff_name_prefix_test.exs`, `collection_sync_name_prefix_test.exs`).
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.NamePrefix

  defp set(value), do: Settings.update_setting(NamePrefix.setting_key(), value)

  describe "prefixes/0" do
    test "defaults to empty when unset" do
      assert NamePrefix.prefixes() == []
    end

    test "splits, trims and drops blanks from a comma-separated value" do
      set(" 3D Printed ,, Hand Made ")
      assert NamePrefix.prefixes() == ["3D Printed", "Hand Made"]
    end

    test "a malformed (non-string) stored value falls back to the empty default" do
      # Simulates a hand-edited settings row that isn't a plain string
      # (e.g. saved as JSON by mistake) — the reader must fail to the
      # SAFE default (no stripping), not raise.
      {:ok, _} = Settings.update_json_setting(NamePrefix.setting_key(), %{"oops" => true})
      assert NamePrefix.prefixes() == []
    end
  end

  describe "strip/1 — the empty (default) setting changes nothing" do
    test "returns the name unchanged when no prefix is configured" do
      set("")
      assert NamePrefix.strip("3D Printed Costume Masks") == "3D Printed Costume Masks"
    end
  end

  describe "strip/1 — matching and separators" do
    setup do
      set("3D Printed")
      :ok
    end

    test "strips the prefix followed by a space" do
      assert NamePrefix.strip("3D Printed Costume Masks") == "Costume Masks"
    end

    test "is case-insensitive" do
      assert NamePrefix.strip("3d printed Costume Masks") == "Costume Masks"
      assert NamePrefix.strip("3D PRINTED Costume Masks") == "Costume Masks"
    end

    # Iterates the module's OWN separator list (NamePrefix.separators/0)
    # rather than a hardcoded copy here, so adding or removing a
    # separator in the source can't silently go untested.
    for sep <- PhoenixKitEcommerce.NamePrefix.separators() do
      test "strips the prefix followed by separator #{inspect(sep)} and its whitespace" do
        assert NamePrefix.strip("3D Printed #{unquote(sep)} Costume Masks") == "Costume Masks"
        # No space before the separator either.
        assert NamePrefix.strip("3D Printed#{unquote(sep)} Costume Masks") == "Costume Masks"
      end
    end

    test "the separator list carries exactly the separators this feature supports" do
      # Pinned so a change to NamePrefix.separators/0 is a deliberate,
      # reviewed edit — including the em-dash, which a shop's own
      # "3D Printed — Costume Masks" copy-paste style can carry.
      assert NamePrefix.separators() == ["-", "–", "—", "|", ":"]
    end

    test "does not strip when the prefix appears mid-name, not at the start" do
      assert NamePrefix.strip("Costume Masks - 3D Printed") == "Costume Masks - 3D Printed"
    end

    test "does not strip when the prefix directly abuts more letters (no boundary)" do
      assert NamePrefix.strip("3D Printedstuff") == "3D Printedstuff"
    end

    test "a name that IS exactly the prefix is left intact rather than rendering blank" do
      assert NamePrefix.strip("3D Printed") == "3D Printed"
    end

    test "a name that is the prefix plus only whitespace/separator is left intact" do
      assert NamePrefix.strip("3D Printed - ") == "3D Printed - "
      assert NamePrefix.strip("3D Printed   ") == "3D Printed   "
    end

    test "a name without the configured prefix is untouched" do
      assert NamePrefix.strip("Hand-poured Candles") == "Hand-poured Candles"
    end

    test "nil and non-binary values pass through unchanged" do
      assert NamePrefix.strip(nil) == nil
      assert NamePrefix.strip(%{}) == %{}
    end
  end

  describe "strip/1 — multiple configured prefixes" do
    test "each configured prefix strips its own matching name" do
      set("3D Printed, Hand Made")
      assert NamePrefix.strip("3D Printed Costume Masks") == "Costume Masks"
      assert NamePrefix.strip("Hand Made Soap") == "Soap"
      assert NamePrefix.strip("Vintage Lamp") == "Vintage Lamp"
    end

    # Deliberate change from an earlier first-match-wins behavior, pinned
    # by an earlier review round: first-match left the dangling fragment
    # "Printed Costume Masks" when both "3D" and "3D Printed" were
    # configured. The LONGEST applicable prefix always wins now,
    # regardless of configuration order — there is no shop-visible upside
    # to matching the shorter one first.
    test "the LONGEST applicable prefix wins on overlap, not the first configured" do
      set("3D, 3D Printed")
      assert NamePrefix.strip("3D Printed Costume Masks") == "Costume Masks"
    end

    test "longest-match wins regardless of which order the prefixes are configured in" do
      set("3D Printed, 3D")
      assert NamePrefix.strip("3D Printed Costume Masks") == "Costume Masks"
    end
  end
end
