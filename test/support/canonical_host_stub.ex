defmodule PhoenixKitEcommerce.Test.CanonicalHostStub do
  @moduledoc false

  # Core hands the language over as given (`de-AT`), so the dialects are mapped here.
  def host(language) when is_binary(language) do
    case language |> String.split("-") |> hd() do
      "de" -> "shop.example.de"
      "fr" -> "shop.example.fr"
      _other -> nil
    end
  end

  def host(_language), do: nil

  def host_counted(language) do
    Process.put(:resolver_calls, Process.get(:resolver_calls, 0) + 1)
    host(language)
  end
end
