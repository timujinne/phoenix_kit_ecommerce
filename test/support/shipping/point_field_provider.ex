defmodule PhoenixKitEcommerce.Test.Shipping.PointFieldProvider do
  @moduledoc """
  A `StubProvider` whose settings also ask for the branch the sender hands
  parcels over at (`sender_point`, a `:pickup_point` field listed for the city
  of `sender_city`). Everything else is the stub's.
  """

  @behaviour PhoenixKitEcommerce.Shipping.Provider

  alias PhoenixKitEcommerce.Shipping.Field
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  @impl true
  def key, do: "point_stub"

  @impl true
  def label, do: "Point stub"

  @impl true
  def services(ctx), do: StubProvider.services(ctx)

  @impl true
  def settings_fields do
    StubProvider.settings_fields() ++
      [
        %Field{
          key: "sender_point",
          label: "Sender branch",
          type: :pickup_point,
          locality_key: "sender_city"
        }
      ]
  end

  @impl true
  def quote(request, ctx), do: StubProvider.quote(request, ctx)

  @impl true
  def search_localities(query, ctx), do: StubProvider.search_localities(query, ctx)

  @impl true
  def list_pickup_points(locality, service, query, ctx),
    do: StubProvider.list_pickup_points(locality, service, query, ctx)
end
