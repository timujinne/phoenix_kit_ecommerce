defmodule PhoenixKitEcommerce.Search.DictionaryTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Search.Dictionary

  test "regconfig/1 maps a language code, dialect or not, to a Postgres text search configuration" do
    assert Dictionary.regconfig("en") == "english"
    assert Dictionary.regconfig("en-US") == "english"
    assert Dictionary.regconfig("de-DE") == "german"
    assert Dictionary.regconfig("DE") == "german"
    assert Dictionary.regconfig("fr-FR") == "french"
    assert Dictionary.regconfig("ru") == "russian"
  end

  test "languages without a built-in configuration use simple, and so does a missing code" do
    assert Dictionary.regconfig("uk") == "simple"
    assert Dictionary.regconfig("et-EE") == "simple"
    assert Dictionary.regconfig("pl") == "simple"
    assert Dictionary.regconfig(nil) == "simple"
    assert Dictionary.regconfig("") == "simple"
  end
end
