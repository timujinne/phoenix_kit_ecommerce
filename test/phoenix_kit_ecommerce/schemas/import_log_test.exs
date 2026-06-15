defmodule PhoenixKitEcommerce.Schemas.ImportLogTest do
  use PhoenixKitEcommerce.DataCase, async: true

  alias PhoenixKitEcommerce.ImportLog

  describe "create_changeset/2" do
    test "is valid with a filename" do
      assert ImportLog.create_changeset(%{filename: "products.csv"}).valid?
    end

    test "requires a filename" do
      cs = ImportLog.create_changeset(%{})
      assert "can't be blank" in errors_on(cs).filename
    end
  end

  describe "update_changeset/2" do
    test "accepts a valid status" do
      assert ImportLog.update_changeset(%ImportLog{}, %{status: "completed"}).valid?
    end

    test "rejects an invalid status" do
      cs = ImportLog.update_changeset(%ImportLog{}, %{status: "bogus"})
      assert %{status: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "start/complete/fail changesets" do
    test "start_changeset sets processing status and total_rows" do
      cs = ImportLog.start_changeset(%ImportLog{}, 50)
      assert get_change(cs, :status) == "processing"
      assert get_change(cs, :total_rows) == 50
      assert get_change(cs, :started_at)
    end

    test "complete_changeset marks completed and copies stats" do
      cs =
        ImportLog.complete_changeset(%ImportLog{total_rows: 10}, %{
          imported_count: 7,
          updated_count: 3
        })

      assert get_change(cs, :status) == "completed"
      assert get_change(cs, :imported_count) == 7
      assert get_change(cs, :processed_rows) == 10
    end

    test "fail_changeset marks failed with error details" do
      cs = ImportLog.fail_changeset(%ImportLog{}, "boom")
      assert get_change(cs, :status) == "failed"
      assert [%{"error" => detail}] = get_change(cs, :error_details)
      assert detail =~ "boom"
    end
  end

  describe "progress_percent/1 and predicates" do
    test "progress_percent/1" do
      assert ImportLog.progress_percent(%ImportLog{total_rows: 0}) == 0
      assert ImportLog.progress_percent(%ImportLog{total_rows: 100, processed_rows: 25}) == 25
    end

    test "in_progress?/1 and finished?/1" do
      assert ImportLog.in_progress?(%ImportLog{status: "processing"})
      assert ImportLog.finished?(%ImportLog{status: "completed"})
      assert ImportLog.finished?(%ImportLog{status: "failed"})
      refute ImportLog.finished?(%ImportLog{status: "processing"})
    end
  end
end
