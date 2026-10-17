defmodule PhoenixKitEcommerce.API.BatchTest do
  @moduledoc """
  The pure steps of the batch tools on hand-built rows: danger, fingerprint,
  preview and the answer. Resolving references and writing are covered by the
  tool tests, which run against a real catalogue.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.{Batch, Rows}

  defp plan(attrs \\ %{}) do
    Map.merge(
      %{
        from: %{price: Decimal.new("10.00")},
        changes: %{"price" => %{"from" => "10.00", "to" => "11.00"}},
        changed?: true,
        dangerous?: false,
        warnings: [],
        attrs: %{},
        owned_paths: []
      },
      attrs
    )
  end

  defp row(index, plan, extra \\ %{}) do
    %{
      index: index,
      input: %{},
      ref: %{"sku" => "S#{index}"},
      item: %{uuid: "u#{index}"},
      plan: plan,
      error: nil,
      result: nil,
      extra: extra
    }
  end

  defp failed(index) do
    %{
      row(index, nil)
      | item: nil,
        error: Rows.error(:not_found, "No product matches this reference.")
    }
  end

  describe "dangerous?/1" do
    test "a dangerous row makes the batch dangerous; the size of the batch does not (core's rule)" do
      assert Batch.dangerous?([row(0, plan(%{dangerous?: true})), row(1, plan())])
      refute Batch.dangerous?(for(index <- 0..59, do: row(index, plan())))
    end

    test "a row that failed or was not planned is never dangerous" do
      refute Batch.dangerous?([failed(0), row(1, plan(%{changed?: false}))])
    end
  end

  describe "fingerprint/1" do
    test "covers the planned rows only, and moves with their current values" do
      one = Batch.fingerprint([row(0, plan()), failed(1)])
      assert one == Batch.fingerprint([row(0, plan())])
      refute one == Batch.fingerprint([row(0, plan(%{from: %{price: Decimal.new("10.01")}}))])
    end
  end

  describe "preview/2" do
    test "lists every row with its action and counts them" do
      rows = [row(0, plan()), row(1, plan(%{changed?: false, changes: %{}})), failed(2)]

      assert %{"rows" => preview_rows, "totals" => totals} = Batch.preview(rows, %{"extra" => 1})

      assert Enum.map(preview_rows, & &1["action"]) == ["update", "unchanged", "error"]
      assert List.first(preview_rows)["changes"]["price"]["to"] == "11.00"
      assert totals == %{"rows" => 3, "update" => 1, "unchanged" => 1, "error" => 1, "extra" => 1}
    end
  end

  describe "render/1" do
    test "answers one result per row, in order, with a summary" do
      updated = %{row(0, plan()) | result: {:ok, %{uuid: "u0"}}}
      refused = %{row(1, plan()) | result: {:error, Rows.error(:validation_failed, "no")}}
      same = row(2, plan(%{changed?: false, changes: %{}}))

      assert %{"results" => results, "summary" => summary} =
               Batch.render([updated, refused, same, failed(3)])

      assert Enum.map(results, & &1["action"]) == ["updated", "error", "unchanged", "error"]

      assert Enum.map(results, & &1["ref"]) == [
               %{"sku" => "S0"},
               %{"sku" => "S1"},
               %{"sku" => "S2"},
               %{"sku" => "S3"}
             ]

      assert summary == %{"updated" => 1, "error" => 2, "unchanged" => 1}
    end

    test "the summary always has the three actions, zero when none happened" do
      same = %{row(0, plan()) | result: {:unchanged, %{uuid: "u0"}}}

      assert %{"summary" => %{"updated" => 0, "unchanged" => 1, "error" => 0}} =
               Batch.render([same])

      assert %{"summary" => %{"updated" => 0, "unchanged" => 0, "error" => 1}} =
               Batch.render([failed(0)])

      assert %{"results" => [], "summary" => %{"updated" => 0, "unchanged" => 0, "error" => 0}} =
               Batch.render([])
    end

    test "a row the catalogue found already up to date is unchanged, not updated" do
      same = %{row(0, plan()) | result: {:unchanged, %{uuid: "u0"}}}

      assert %{
               "results" => [%{"action" => "unchanged", "id" => "u0"}],
               "summary" => %{"unchanged" => 1}
             } =
               Batch.render([same])
    end

    test "a row's extra answer fields are merged in" do
      updated = %{row(0, plan(), %{"attached" => 2}) | result: {:ok, %{uuid: "u0"}}}
      assert %{"results" => [%{"attached" => 2}]} = Batch.render([updated])
    end
  end

  describe "plan/2 and a product given twice" do
    test "a later row of a product whose earlier row planned fails as a duplicate, unplanned" do
      rows = [row(0, nil), %{row(1, nil) | item: %{uuid: "u0"}}]
      test_pid = self()

      planned =
        Batch.plan(rows, fn %{index: index} ->
          send(test_pid, {:planned, index})
          {:ok, plan()}
        end)

      assert [%{error: nil}, %{error: %{"code" => "duplicate_line"}, plan: nil}] = planned
      assert_received {:planned, 0}
      refute_received {:planned, 1}
    end

    test "a later row of a product whose earlier row failed is planned" do
      rows = [row(0, nil), %{row(1, nil) | item: %{uuid: "u0"}}]

      planned =
        Batch.plan(rows, fn
          %{index: 0} -> {:error, Rows.error(:validation_failed, "bad")}
          %{index: 1} -> {:ok, plan()}
        end)

      assert [%{error: %{"code" => "validation_failed"}}, %{error: nil, plan: %{changed?: true}}] =
               planned
    end
  end

  describe "plan/2" do
    test "plans resolved rows only, and a planner error fails just that row" do
      rows = [row(0, nil), row(1, nil), failed(2)]

      planned =
        Batch.plan(rows, fn
          %{index: 0} -> {:ok, plan()}
          %{index: 1} -> {:error, Rows.error(:validation_failed, "bad")}
        end)

      assert [
               %{plan: %{changed?: true}, error: nil},
               %{plan: nil, error: %{"code" => "validation_failed"}},
               %{error: %{"code" => "not_found"}}
             ] =
               planned
    end
  end
end
