defmodule PhoenixKitEcommerce.Search.Dictionary do
  @moduledoc """
  Picks the Postgres text search configuration for a language.

  Postgres ships stemming configurations for a fixed set of languages; every
  other language (Ukrainian, Estonian, Polish ...) uses `simple`, which lower-
  cases and splits words without stemming. The same function is used when a
  document is written and when a query is parsed, so the two always agree. If
  this table changes, run a rebuild (`Search.Indexer.rebuild/0`).
  """

  alias PhoenixKit.Modules.Languages.DialectMapper

  @configs %{
    "en" => "english",
    "de" => "german",
    "fr" => "french",
    "es" => "spanish",
    "it" => "italian",
    "pt" => "portuguese",
    "nl" => "dutch",
    "ru" => "russian",
    "sv" => "swedish",
    "da" => "danish",
    "fi" => "finnish",
    "no" => "norwegian",
    "nb" => "norwegian",
    "hu" => "hungarian",
    "ro" => "romanian",
    "tr" => "turkish"
  }

  @doc ~s|The configuration name for `language` ("de-DE" and "de" alike); "simple" when there is none.|
  @spec regconfig(String.t() | nil) :: String.t()
  def regconfig(language) when is_binary(language) and language != "" do
    Map.get(@configs, DialectMapper.extract_base(language), "simple")
  end

  def regconfig(_language), do: "simple"

  @doc "Every stemming configuration this module can return (without `simple`)."
  @spec configs() :: [String.t()]
  def configs, do: @configs |> Map.values() |> Enum.uniq() |> Enum.sort()
end
