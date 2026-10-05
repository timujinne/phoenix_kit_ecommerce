defmodule PhoenixKitEcommerce.PackageFilesConformanceTest do
  @moduledoc """
  Guards what the Hex package ships. Hex packs exactly the `files:` list and
  ignores `.gitignore`, and the test Storage writes real image files into
  `priv/media`: listing `priv` as a whole turns a few local test runs into a
  tarball over Hex's 16 MB limit and a failed `mix hex.publish`.
  """

  use ExUnit.Case, async: true

  @files Mix.Project.config()[:package][:files]

  test "the package ships priv/gettext and not the whole priv directory" do
    assert "priv/gettext" in @files
    refute "priv" in @files
  end

  test "nothing under priv/media is listed" do
    refute Enum.any?(@files, &String.starts_with?(&1, "priv/media"))
  end
end
