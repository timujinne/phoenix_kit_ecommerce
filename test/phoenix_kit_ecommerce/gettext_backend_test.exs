defmodule PhoenixKitEcommerce.GettextBackendTest do
  @moduledoc """
  Pins `split_module_by: [:locale, :domain]` on `PhoenixKitEcommerce.Gettext`.

  Dropping the option leaves every lookup passing — the catalogues are the
  same — and the serial compile of ~45k lines of `.po` comes back. The
  parent beam is what this asserts against, so leftover `T_*` files from
  an earlier build cannot hide the regression.
  """

  use ExUnit.Case, async: true

  @locales ~w(de en et fr ru uk)
  @backend PhoenixKitEcommerce.Gettext

  test "the parent dispatches each shipped locale to its own module" do
    dispatched =
      @backend
      |> :code.which()
      |> :beam_lib.chunks([:abstract_code])
      |> then(fn {:ok, {_, [{:abstract_code, {:raw_abstract_v1, code}}]}} ->
        code
        |> atoms()
        |> Enum.filter(&split_module?/1)
        |> Enum.uniq()
        |> Enum.sort()
      end)

    assert dispatched == Enum.sort(split_modules())
    Enum.each(split_modules(), &assert(Code.ensure_loaded?(&1)))
  end

  test "looks up a translated msgid in each shipped locale" do
    expected = %{
      "de" => "Mein Warenkorb",
      "en" => "My Cart",
      "et" => "Minu ostukorv",
      "fr" => "Mon panier",
      "ru" => "Моя корзина",
      "uk" => "Мій кошик"
    }

    for locale <- @locales do
      assert lookup(locale, "My Cart") == expected[locale]
    end
  end

  # Ukrainian has three plural forms, and 21 takes the singular index
  # (msgstr[0]) while 11 takes the many index. Both have to survive the
  # move of the plural clause into the split module.
  test "uk plural forms resolve through the split module" do
    expected = %{
      1 => "1 товар",
      2 => "2 товари",
      5 => "5 товарів",
      11 => "11 товарів",
      21 => "21 товар"
    }

    for {n, want} <- expected do
      got =
        Gettext.with_locale(@backend, "uk", fn ->
          Gettext.dngettext(@backend, "default", "1 product", "%{count} products", n, count: n)
        end)

      assert got == want
    end
  end

  test "an unshipped locale or domain falls back to the msgid" do
    assert lookup("pt", "My Cart") == "My Cart"

    assert Gettext.with_locale(@backend, "ru", fn ->
             Gettext.dgettext(@backend, "missing", "My Cart")
           end) == "My Cart"
  end

  defp lookup(locale, msgid) do
    Gettext.with_locale(@backend, locale, fn ->
      Gettext.dgettext(@backend, "default", msgid)
    end)
  end

  defp split_modules do
    Enum.map(@locales, &Module.concat(@backend, "T_#{&1}_default"))
  end

  defp split_module?(atom) when is_atom(atom) do
    atom |> Atom.to_string() |> String.starts_with?("Elixir.PhoenixKitEcommerce.Gettext.T_")
  end

  defp atoms(atom) when is_atom(atom), do: [atom]
  defp atoms(list) when is_list(list), do: Enum.flat_map(list, &atoms/1)
  defp atoms(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> atoms()
  defp atoms(_other), do: []
end
