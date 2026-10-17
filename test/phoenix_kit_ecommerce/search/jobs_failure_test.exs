defmodule PhoenixKitEcommerce.Search.JobsFailureTest do
  @moduledoc """
  Enqueueing when the database cannot be used.

  A plain `ExUnit.Case`: the test process owns no sandbox connection, so
  `Oban.insert/1` raises `DBConnection.OwnershipError`.
  """
  use ExUnit.Case, async: true

  @moduletag :integration

  import ExUnit.CaptureLog

  alias PhoenixKitEcommerce.Search.Jobs

  test "a failed insert is returned as the exception module and logged without the uuid" do
    uuid = Ecto.UUID.generate()

    log =
      capture_log(fn ->
        assert {:error, DBConnection.OwnershipError} = Jobs.enqueue_item(uuid)
      end)

    assert log =~ "could not enqueue a search job"
    assert log =~ "DBConnection.OwnershipError"
    refute log =~ uuid
  end

  test "the same holds for a category job and a rebuild request" do
    uuid = Ecto.UUID.generate()

    log =
      capture_log(fn ->
        assert {:error, DBConnection.OwnershipError} = Jobs.enqueue_category(uuid)
        assert {:error, DBConnection.OwnershipError} = Jobs.enqueue_rebuild(uuid)
      end)

    refute log =~ uuid
  end

  test "enqueue_items/1 stops at the first failed insert and returns the error" do
    uuids = for _ <- 1..450, do: Ecto.UUID.generate()

    log =
      capture_log(fn ->
        assert {:error, DBConnection.OwnershipError} = Jobs.enqueue_items(uuids)
      end)

    # Halted after the first chunk: one warning, not three.
    assert length(String.split(log, "could not enqueue a search job")) == 2
  end
end
