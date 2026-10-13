defmodule PhoenixKitEcommerce.Web.ImportsUploadNameTest do
  @moduledoc """
  The uploaded file's name is the browser's to choose. Whatever it is, the
  copy lands as one plain file inside the import directory.
  """

  use PhoenixKitEcommerce.LiveCase, async: false

  @page "/en/admin/shop/imports"
  @dir Path.join(System.tmp_dir!(), "shop_imports")

  setup %{conn: conn} do
    File.mkdir_p!(@dir)
    before = MapSet.new(File.ls!(@dir))

    on_exit(fn ->
      for name <- File.ls!(@dir), name not in before, do: File.rm(Path.join(@dir, name))
    end)

    {:ok, conn: put_test_scope(conn, fake_scope()), before: before}
  end

  defp upload(view, name) do
    csv = "Handle,Title,Variant Price\nwand,Wand,10.00\n"

    view
    |> file_input("#csv-upload-form", :csv_file, [%{name: name, content: csv, type: "text/csv"}])
    |> render_upload(name)

    view |> form("#csv-upload-form") |> render_submit()
  end

  for name <- ["nested/dir/shop.csv", "../../escape.csv", "we ird;name$(x).csv", ".csv"] do
    test "#{inspect(name)} is stored under a harmless name", %{conn: conn, before: before} do
      {:ok, view, _html} = live(conn, @page)

      upload(view, unquote(name))

      assert render(view) =~ "CSV"

      created = Enum.reject(File.ls!(@dir), &(&1 in before))
      assert [_file] = created
      assert Enum.all?(created, &(&1 =~ ~r/\A\d+_[A-Za-z0-9._-]+\z/))
      assert Enum.all?(created, &File.regular?(Path.join(@dir, &1)))
    end
  end
end
