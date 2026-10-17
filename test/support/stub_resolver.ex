defmodule PhoenixKitEcommerce.Test.StubResolver do
  @moduledoc """
  A name resolver for the SSRF guard's tests (`:image_resolver`): it answers
  one family at once and never answers the other, so the guard's per-lookup
  deadline is what ends the wait.
  """

  def getaddrs(~c"half.example.test", :inet, _timeout), do: {:ok, [{93, 184, 216, 34}]}
  def getaddrs(_host, _family, _timeout), do: Process.sleep(:infinity)
end
