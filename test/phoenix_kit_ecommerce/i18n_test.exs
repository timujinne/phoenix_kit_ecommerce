defmodule PhoenixKitEcommerce.I18nTest do
  @moduledoc """
  Smoke test for the per-module i18n wiring.

  Confirms that:
    * Every tab registered by `PhoenixKitEcommerce.admin_tabs/0`,
      `settings_tabs/0`, and `user_dashboard_tabs/0` carries
      `gettext_backend: PhoenixKitEcommerce.Gettext`.
    * The shipped `priv/gettext/<locale>/LC_MESSAGES/default.po`
      catalogues resolve through the backend directly and through
      `Tab.localized_label/1`.
    * Falls back to the raw msgid for an unknown locale.
  """

  use ExUnit.Case, async: false

  # Excluded by `test/test_helper.exs` when running against a `phoenix_kit`
  # release that pre-dates the `gettext_backend` API (PR BeamLabEU/phoenix_kit#522).
  # Once the consumer's `phoenix_kit` dep resolves to a release that ships
  # `Tab.localized_label/1`, the helper detects it and these tests run
  # automatically — no follow-up edit needed.
  @moduletag :requires_phoenix_kit_i18n_api

  alias PhoenixKit.Dashboard.Tab
  alias PhoenixKitEcommerce.Gettext, as: EcommerceGettext

  setup do
    original = Gettext.get_locale(EcommerceGettext)
    on_exit(fn -> Gettext.put_locale(EcommerceGettext, original) end)
    :ok
  end

  describe "tab wiring" do
    test "every registered tab carries the module's own gettext backend" do
      tabs =
        PhoenixKitEcommerce.admin_tabs() ++
          PhoenixKitEcommerce.settings_tabs() ++
          PhoenixKitEcommerce.user_dashboard_tabs()

      # Sanity: 9 admin (incl. Translations) + 1 settings + 2 user-dashboard
      # = 12 sites.
      assert length(tabs) == 12

      for tab <- tabs do
        assert tab.gettext_backend == EcommerceGettext,
               "Tab #{inspect(tab.id)} is missing or wrong gettext_backend " <>
                 "(got #{inspect(tab.gettext_backend)})"

        assert tab.gettext_domain == "default"
      end
    end
  end

  describe "backend catalogue lookup" do
    test "ru locale resolves 'E-Commerce' through the backend directly" do
      Gettext.put_locale(EcommerceGettext, "ru")
      assert Gettext.gettext(EcommerceGettext, "E-Commerce") == "Электронная коммерция"
    end

    test "et locale resolves 'My Cart' through the backend directly" do
      Gettext.put_locale(EcommerceGettext, "et")
      assert Gettext.gettext(EcommerceGettext, "My Cart") == "Minu ostukorv"
    end
  end

  describe "Tab.localized_label/1 against the module's catalogue" do
    test "ru locale resolves the parent 'E-Commerce' tab to 'Электронная коммерция'" do
      Gettext.put_locale(EcommerceGettext, "ru")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == "Электронная коммерция"
    end

    test "et locale resolves the parent 'E-Commerce' tab to 'E-kaubandus'" do
      Gettext.put_locale(EcommerceGettext, "et")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == "E-kaubandus"
    end

    test "unknown locale falls back to the raw msgid" do
      Gettext.put_locale(EcommerceGettext, "zz")

      parent = admin_shop_tab()
      assert Tab.localized_label(parent) == parent.label
    end
  end

  describe "plural catalogue coverage (de, fr)" do
    # German's plural rule sends n=0 to the *plural* index (msgstr[1]), so a
    # hardcoded "1 ..." in msgstr[0] is only ever reached at n=1 and a bug
    # there is harmless. French sends n=0 to the *singular* index
    # (msgstr[0]) instead — a hardcoded "1 ..." there is reached at n=0 and
    # renders "1 item" for an empty cart. These assertions cover n=0
    # specifically because that is the case a plain smoke test at n=1 (or a
    # substring check against the msgid) cannot distinguish from correct.
    test "de resolves plural forms at n=0, 1, 2" do
      Gettext.put_locale(EcommerceGettext, "de")

      for {msgid, msgid_plural, expected} <- de_plural_fixtures(),
          {n, want} <- expected do
        got = Gettext.dngettext(EcommerceGettext, "default", msgid, msgid_plural, n, count: n)

        assert got == want,
               "de n=#{n} #{inspect(msgid)}: got #{inspect(got)}, want #{inspect(want)}"
      end
    end

    test "fr resolves plural forms at n=0, 1, 2" do
      Gettext.put_locale(EcommerceGettext, "fr")

      for {msgid, msgid_plural, expected} <- fr_plural_fixtures(),
          {n, want} <- expected do
        got = Gettext.dngettext(EcommerceGettext, "default", msgid, msgid_plural, n, count: n)

        assert got == want,
               "fr n=#{n} #{inspect(msgid)}: got #{inspect(got)}, want #{inspect(want)}"
      end
    end
  end

  describe "catalogue completeness" do
    # PR #26 added 84 msgids under `web/` and never ran
    # `mix gettext.extract && mix gettext.merge` (see AGENTS.md), so the
    # entire Shopify Sync page rendered in English on a de/fr/ru/et
    # install while every page around it translated. Nothing caught it:
    # a missing msgstr falls back to the msgid, which IS the English
    # source string, so the page looks correct in the only locale the
    # suite renders in. This asserts the property the four shipped
    # catalogues actually hold — every msgid translated — which is
    # exactly what an un-run extraction breaks.
    #
    # `en` is excluded on purpose: its msgstrs are empty by design (the
    # msgid already is the English text) and merging leaves them so.
    @translated_locales ~w(de fr ru et)

    for locale <- @translated_locales do
      test "#{locale} has no untranslated message" do
        untranslated =
          unquote(locale)
          |> catalogue_path()
          |> untranslated_msgids()

        assert untranslated == [],
               "#{unquote(locale)} is missing translations for " <>
                 "#{length(untranslated)} msgid(s): #{inspect(Enum.take(untranslated, 10))}. " <>
                 "Run: mix gettext.extract && mix gettext.merge priv/gettext --no-fuzzy"
      end
    end

    # The two label sets the Shopify Sync page renders — plural section
    # headers and the singular nouns it interpolates into confirm/flash
    # sentences as `%{field}`. Both used to live in module attributes,
    # where `mix gettext.extract` could not see them and `gettext/1`
    # could not read them back, so they printed English under every
    # locale. Pinned here rather than through the LiveView because the
    # suite only ever renders the page in `en`, where a regression is
    # invisible by construction.
    test "the Shopify Sync section headers and field labels resolve in every shipped locale" do
      # de and ru, not all four: the assertion is "the rendered string
      # differs from the msgid", and fr's "Descriptions" / et's "Tags"
      # are legitimately identical to the English, which would make the
      # test fail on a correct catalogue. Every one of these seven does
      # differ in de and ru, so those two carry the pin.
      for locale <- ~w(de ru),
          msgid <- ~w(Prices Titles Descriptions Statuses Vendors) ++ ["HTML texts", "HTML text"] do
        Gettext.put_locale(EcommerceGettext, locale)
        translated = Gettext.gettext(EcommerceGettext, msgid)

        refute translated == msgid,
               "#{locale}: #{inspect(msgid)} fell through to its msgid — " <>
                 "the label is not reaching the catalogue"
      end
    end
  end

  defp admin_shop_tab do
    Enum.find(PhoenixKitEcommerce.admin_tabs(), &(&1.id == :admin_shop))
  end

  defp catalogue_path(locale) do
    Application.app_dir(:phoenix_kit_ecommerce, "priv/gettext/#{locale}/LC_MESSAGES/default.po")
  end

  # A minimal `.po` reader: split on blank lines, and report any entry
  # whose `msgstr`/`msgstr[N]` is empty. Deliberately not a full parser —
  # it only has to distinguish "" from anything else, and the header
  # entry (whose msgid is "") is skipped.
  defp untranslated_msgids(path) do
    path
    |> File.read!()
    |> String.split("\n\n")
    |> Enum.flat_map(&untranslated_msgid/1)
  end

  defp untranslated_msgid(block) do
    with [_, msgid] when msgid != "" <- Regex.run(~r/^msgid "(.*)"$/m, block),
         true <- Regex.match?(~r/^msgstr(\[\d+\])? ""$/m, block) do
      [msgid]
    else
      _ -> []
    end
  end

  defp de_plural_fixtures do
    [
      {"1 category", "%{count} categories",
       %{0 => "0 Kategorien", 1 => "1 Kategorie", 2 => "2 Kategorien"}},
      {"1 product", "%{count} products",
       %{0 => "0 Produkte", 1 => "1 Produkt", 2 => "2 Produkte"}},
      {"1 item", "%{count} items", %{0 => "0 Artikel", 1 => "1 Artikel", 2 => "2 Artikel"}},
      {"1 cart total", "%{count} carts total",
       %{
         0 => "0 Warenkörbe insgesamt",
         1 => "1 Warenkorb insgesamt",
         2 => "2 Warenkörbe insgesamt"
       }},
      {"1 method configured", "%{count} methods configured",
       %{
         0 => "0 Methoden konfiguriert",
         1 => "1 Methode konfiguriert",
         2 => "2 Methoden konfiguriert"
       }},
      {"1 day", "%{count} days", %{0 => "0 Tage", 1 => "1 Tag", 2 => "2 Tage"}},
      # The translations page's call estimate is TWO independent counts
      # ("≈N model calls" and "about M minutes"), so it is two
      # `ngettext/4` calls. One sentence governed by the call count
      # rendered "etwa 1 Minuten." for every 2–13-call estimate — the
      # common case. These two fixtures pin each count separately.
      {"≈%{count} model call", "≈%{count} model calls",
       %{0 => "≈0 Modellaufrufe", 1 => "≈1 Modellaufruf", 2 => "≈2 Modellaufrufe"}},
      {"about %{count} minute.", "about %{count} minutes.",
       %{0 => "etwa 0 Minuten.", 1 => "etwa 1 Minute.", 2 => "etwa 2 Minuten."}}
    ]
  end

  defp fr_plural_fixtures do
    [
      {"1 category", "%{count} categories",
       %{0 => "0 catégorie", 1 => "1 catégorie", 2 => "2 catégories"}},
      {"1 product", "%{count} products",
       %{0 => "0 produit", 1 => "1 produit", 2 => "2 produits"}},
      {"1 item", "%{count} items", %{0 => "0 article", 1 => "1 article", 2 => "2 articles"}},
      {"1 cart total", "%{count} carts total",
       %{0 => "0 panier au total", 1 => "1 panier au total", 2 => "2 paniers au total"}},
      {"1 method configured", "%{count} methods configured",
       %{
         0 => "0 méthode configurée",
         1 => "1 méthode configurée",
         2 => "2 méthodes configurées"
       }},
      {"1 day", "%{count} days", %{0 => "0 jour", 1 => "1 jour", 2 => "2 jours"}},
      # See the German twin above — fr sends n=0 to the SINGULAR index,
      # so "environ 0 minute." is the correct French here and the
      # fixture has to say so.
      {"≈%{count} model call", "≈%{count} model calls",
       %{0 => "≈0 appel au modèle", 1 => "≈1 appel au modèle", 2 => "≈2 appels au modèle"}},
      {"about %{count} minute.", "about %{count} minutes.",
       %{0 => "environ 0 minute.", 1 => "environ 1 minute.", 2 => "environ 2 minutes."}}
    ]
  end
end
