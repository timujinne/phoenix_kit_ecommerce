defmodule PhoenixKitEcommerce.FileReferences do
  @moduledoc """
  The places in this module's tables that point at a stored file, for the
  orphan-file check of core's storage (`PhoenixKit.Module.file_references/0`).

  A file one of these rows names is in use and must never be read as an orphan:
  core would queue it for `DeleteOrphanedFileJob`. Each pair is a table and the
  condition "this table does not reference the file"; core leaves the pair out
  when the table does not exist.

  Moved here verbatim from core's `PhoenixKit.Modules.Storage`, which keeps its
  own copy for module versions that predate the callback. A table of this
  module that holds a file reference belongs in this list: while this module
  supplies one, core's copy of its tables steps aside.
  """

  import Ecto.Query, only: [dynamic: 2]

  @spec pairs() :: [{String.t(), Ecto.Query.dynamic_expr()}]
  def pairs do
    [
      {"phoenix_kit_shop_products",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_products sp WHERE sp.featured_image_uuid = ?) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_products sp WHERE ? = ANY(sp.image_uuids)) AND NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_products sp WHERE sp.file_uuid = ?)",
           f.uuid,
           f.uuid,
           f.uuid
         )
       )},
      {"phoenix_kit_shop_categories",
       dynamic(
         [f],
         fragment(
           "NOT EXISTS (SELECT 1 FROM phoenix_kit_shop_categories sc WHERE sc.image_uuid = ?)",
           f.uuid
         )
       )}
    ]
  end
end
