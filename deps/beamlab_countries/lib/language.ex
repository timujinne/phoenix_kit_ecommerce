defmodule BeamLabCountries.Language do
  @moduledoc """
  Language struct representing an ISO 639-1 language.

  ## Fields

  - `code` - ISO 639-1 two-letter code (e.g., "en", "es", "de")
  - `name` - English name of the language (e.g., "English", "Spanish")
  - `native_name` - Name in the native language (e.g., "Deutsch" for German)
  - `family` - Language family (e.g., "Indo-European", "Sino-Tibetan")

  ## Examples

      iex> BeamLabCountries.Languages.get("en")
      %BeamLabCountries.Language{
        code: "en",
        name: "English",
        native_name: "English",
        family: "Indo-European"
      }

  """

  defstruct [:code, :name, :native_name, :family]

  @type t :: %__MODULE__{
          code: String.t(),
          name: String.t(),
          native_name: String.t(),
          family: String.t() | nil
        }
end
