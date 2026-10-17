defmodule PhoenixKitEcommerce.Web.ClaimRoutesTest.Splice do
  @moduledoc false
  alias PhoenixKitEcommerce.Web.Routes

  defmacro claim_routes, do: Routes.generate("/")
end

defmodule PhoenixKitEcommerce.Web.ClaimRoutesTest do
  @moduledoc """
  `Web.Routes.generate/1` is what core splices into a host router. The test
  router of the suite declares the claim route by hand, so this test expands the
  real hook in a throwaway router.
  """
  use ExUnit.Case, async: true

  # Session, flash and CSRF; the logged-in user; the browser's cart id. They are
  # what protect the consuming POST.
  @pipelines [:browser, :phoenix_kit_auto_setup, :phoenix_kit_shop_session]

  defmodule ProbeRouter do
    use Phoenix.Router

    alias PhoenixKitEcommerce.Web.ClaimRoutesTest.Splice

    require Splice

    pipeline :browser do
      plug(:accepts, ["html"])
    end

    pipeline :phoenix_kit_auto_setup do
      plug(:accepts, ["html"])
    end

    pipeline :phoenix_kit_shop_session do
      plug(:accepts, ["html"])
    end

    Splice.claim_routes()
  end

  test "the hook declares the GET and the POST of the claim page, outside any locale prefix" do
    routes = Phoenix.Router.routes(ProbeRouter)

    assert [
             %{
               path: "/checkout/claim/:token",
               plug: PhoenixKitEcommerce.Web.ClaimController,
               plug_opts: :show
             }
           ] =
             Enum.filter(routes, &(&1.verb == :get))

    assert [%{path: "/checkout/claim/:token", plug_opts: :create}] =
             Enum.filter(routes, &(&1.verb == :post))
  end

  test "both routes run through the browser, auto-setup and shop-session pipelines" do
    for {verb, action} <- [{"GET", :show}, {"POST", :create}] do
      assert %{
               plug: PhoenixKitEcommerce.Web.ClaimController,
               plug_opts: ^action,
               pipe_through: @pipelines
             } = Phoenix.Router.route_info(ProbeRouter, verb, "/checkout/claim/abc", "")
    end
  end
end
