defmodule PhoenixKitEcommerce.SelectedSpecsTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Product
  alias PhoenixKitEcommerce.SelectedSpecs

  test "an old label cannot impersonate a current value key" do
    product = %Product{
      origin: :catalogue,
      metadata: %{"_value_slugs" => %{"color" => %{"Red" => "crimson"}}}
    }

    assert SelectedSpecs.keys(%CartItem{selected_specs: %{"color" => "Red"}}, product) ==
             %{"color" => "crimson"}

    assert SelectedSpecs.keys(%CartItem{selected_specs: %{"color" => "crimson"}}, product) ==
             %{"color" => nil}
  end

  test "catalogue schema options keep their identity beside keyed options" do
    product = %Product{
      origin: :catalogue,
      metadata: %{"_value_slugs" => %{"color" => %{"Red" => "crimson"}}}
    }

    item = %CartItem{selected_specs: %{"color" => "Red", "finish" => "Matte"}}

    assert SelectedSpecs.keys(item, product) == %{"color" => "crimson", "finish" => "Matte"}
  end

  test "legacy options keep their stored values" do
    item = %CartItem{selected_specs: %{"color" => "Red"}}

    assert SelectedSpecs.keys(item, %Product{}) == %{"color" => "Red"}
  end

  test "a keyed line retains its identity after its option disappears" do
    item = %CartItem{
      selected_specs: %{"color" => "crimson"},
      metadata: %{"selection" => %{"format" => 2, "labels" => %{"color" => "Red"}}}
    }

    assert SelectedSpecs.keys(item, %Product{origin: :catalogue}) == %{"color" => "crimson"}
    assert SelectedSpecs.labels(item) == %{"color" => "Red"}
  end
end
