defmodule PhoenixKitEcommerce.Workers.SearchRebuildWorkerCatalogueTest do
  @moduledoc """
  The rebuild worker on the catalogue product source: the catalogue-event
  filter and the cancelled rebuild.

  `async: false`: the shop's catalogue is found by name across the database.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :catalogue

  @compile {:no_warn_undefined, PhoenixKitCatalogue.Catalogue}

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKitCatalogue.Catalogue
  alias PhoenixKitEcommerce.Search.Entry
  alias PhoenixKitEcommerce.Test.Repo
  alias PhoenixKitEcommerce.Workers.SearchRebuildWorker

  defp perform(args), do: SearchRebuildWorker.perform(%Oban.Job{args: args})

  defp titles, do: Repo.all(from(e in Entry, order_by: e.title, select: e.title))

  test "an event about the shop's own catalogue rebuilds the index" do
    catalogue = catalogue_source!()
    catalogue_item!(catalogue, "Red Vase")

    assert :ok = perform(%{"catalogue_uuid" => catalogue.uuid})

    assert titles() == ["Red Vase"]
  end

  test "an event about another catalogue is skipped" do
    catalogue = catalogue_source!()
    catalogue_item!(catalogue, "Red Vase")

    assert :ok = perform(%{"catalogue_uuid" => Ecto.UUID.generate()})

    assert titles() == []
  end

  test "a rebuild that cannot resolve the shop catalogue is cancelled and keeps the rows" do
    catalogue = catalogue_source!()
    catalogue_item!(catalogue, "Red Vase")
    assert :ok = perform(%{})
    assert titles() == ["Red Vase"]

    # The shop finds its catalogue by name; renaming it makes it unresolvable.
    {:ok, _} = Catalogue.update_catalogue(catalogue, %{name: "somebody else"})

    assert {:cancel, _reason} = perform(%{})
    assert titles() == ["Red Vase"]
  end
end
