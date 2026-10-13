defmodule PhoenixKitEcommerce.Test.Shipping.CountryProvider do
  @moduledoc """
  A `StubProvider` that declares the countries it delivers to
  (`countries/0`), read from the application env `:shipping_country_provider`
  so a test can change them. Everything else is the stub's.
  """

  @behaviour PhoenixKitEcommerce.Shipping.Provider

  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @impl true
  def key, do: "country_stub"

  @impl true
  def label, do: "Country stub"

  @impl true
  def countries, do: Application.get_env(:phoenix_kit_ecommerce, :shipping_country_provider, [])

  @impl true
  def services(ctx), do: StubProvider.services(ctx)

  @impl true
  def settings_fields, do: StubProvider.settings_fields()

  @impl true
  def quote(request, ctx), do: StubProvider.quote(request, ctx)

  @impl true
  def search_localities(query, ctx), do: StubProvider.search_localities(query, ctx)

  @impl true
  def list_pickup_points(locality, service, query, ctx),
    do: StubProvider.list_pickup_points(locality, service, query, ctx)
end
