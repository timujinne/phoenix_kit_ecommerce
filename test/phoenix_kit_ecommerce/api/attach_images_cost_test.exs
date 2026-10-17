defmodule PhoenixKitEcommerce.API.AttachImagesCostTest do
  @moduledoc """
  `AttachImages.cost/1`: the rate-limit units of one call, from the raw input
  the limiter sees before validation.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.AttachImages

  test "one unit per picture asked for, over all rows" do
    input = %{"items" => [%{"images" => [%{}, %{}]}, %{"images" => [%{}]}]}
    assert AttachImages.cost(input) == 3
    assert AttachImages.cost(%{"items" => [%{"images" => List.duplicate(%{}, 20)}]}) == 20
  end

  test "never more than the most pictures a call may attach" do
    max = AttachImages.max_images()
    assert max == 20

    assert AttachImages.cost(%{"items" => [%{"images" => List.duplicate(%{}, 400)}]}) == max

    assert AttachImages.cost(%{
             "items" => List.duplicate(%{"images" => List.duplicate(%{}, 30)}, 10)
           }) == max
  end

  test "at least one, whatever the input looks like" do
    for input <- [%{}, nil, "x", %{"items" => "x"}, %{"items" => []}, %{"items" => [%{}, 5]}] do
      assert AttachImages.cost(input) == 1, "#{inspect(input)} must cost 1"
    end
  end

  test "a row whose images are not a list counts for nothing" do
    assert AttachImages.cost(%{"items" => [%{"images" => "x"}, %{"images" => [%{}]}]}) == 1
  end
end
