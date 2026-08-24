defmodule PhoenixKitEcommerce.LocalizedSlugTest do
  @moduledoc """
  Pure cases for the shared product/category slug fallback.

  Kept off DataCase so they still run on a checkout with no PostgreSQL —
  the hash contract is the part that must not drift between the two schemas.
  """
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.LocalizedSlug

  test "fallback is stable, ASCII, and distinct per title" do
    a = LocalizedSlug.fallback("日本語")
    b = LocalizedSlug.fallback("別の話")

    assert a == LocalizedSlug.fallback("日本語")
    refute a == b
    assert a =~ ~r/^item-[0-9a-f]{10}$/
    assert b =~ ~r/^item-[0-9a-f]{10}$/
  end
end
