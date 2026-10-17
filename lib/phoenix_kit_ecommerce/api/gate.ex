defmodule PhoenixKitEcommerce.API.Gate do
  @moduledoc """
  The precondition of every admin e-commerce tool: the shop
  reads its products from a catalogue, and the catalogue is new enough to be
  written through the API. Anything else answers `unsupported_source` and
  touches nothing.

  The catalogue is an optional dependency this package does not declare, so
  every call into it is guarded here, in one place, by looking at what the
  loaded catalogue exports (a version number cannot be trusted: a fork branch
  carries the version of the release it started from).
  """

  @compile {:no_warn_undefined,
            [PhoenixKitCatalogue, PhoenixKitCatalogue.API, PhoenixKitCatalogue.Catalogue]}

  alias PhoenixKit.Users.Auth
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Auth.User
  alias PhoenixKitEcommerce.ProductSource
  alias PhoenixKitEcommerce.ProductSource.Catalogue.Query

  @type reason :: :catalogue_missing | :legacy_source | :catalogue_too_old | :no_shop_catalogue

  @type refusal :: {:error, :unsupported_source | :validation_failed, String.t(), map()}

  @doc """
  The write tools edit catalogue records, so the key owner needs the same
  catalogue permission as the admin editor, in addition to the shop capability
  enforced by core. Re-read the owner's roles without browser role narrowing;
  a key or confirmation issued before a revocation must not preserve access.
  """
  @spec authorize_catalogue(map()) :: :ok | {:error, :forbidden, String.t(), map()}
  def authorize_catalogue(ctx) do
    with %{kind: :key, user_uuid: uuid} when is_binary(uuid) <- Map.get(ctx, :actor),
         {:ok, uuid} <- Ecto.UUID.cast(uuid),
         %User{} = user <- uuid |> Auth.get_user() |> Auth.ensure_active_user(),
         true <- user |> Scope.for_user(narrow: false) |> Scope.can?("catalogue") do
      :ok
    else
      _ -> catalogue_forbidden()
    end
  rescue
    _ -> catalogue_forbidden()
  catch
    :exit, _ -> catalogue_forbidden()
  end

  defp catalogue_forbidden do
    {:error, :forbidden, "The key owner needs catalogue access to edit catalogue products.",
     %{required_permission: "catalogue"}}
  end

  @doc """
  `{:ok, catalogue_uuid}` (the catalogue the shop reads), or the handler-ready
  refusal. `input` is the tool input: a `"catalogue_id"` in it must be the
  shop's catalogue, because a product outside it is not in the shop.
  """
  @spec check(map()) :: {:ok, String.t()} | refusal()
  def check(input \\ %{}) do
    with {:ok, catalogue_uuid} <- source() do
      case Map.get(input, "catalogue_id") do
        nil -> {:ok, catalogue_uuid}
        given -> check_catalogue_id(given, catalogue_uuid)
      end
    end
  end

  defp check_catalogue_id(given, catalogue_uuid) do
    if Ecto.UUID.cast(given) == {:ok, catalogue_uuid} do
      {:ok, catalogue_uuid}
    else
      {:error, :validation_failed, "catalogue_id is not the catalogue the shop reads.",
       %{
         errors: [
           %{
             path: "catalogue_id",
             message: "must be the shop catalogue",
             limit: nil,
             allowed: [catalogue_uuid]
           }
         ]
       }}
    end
  end

  @doc "The same as `check/1` for callers that only need the verdict."
  @spec source() :: {:ok, String.t()} | refusal()
  def source do
    case reason() do
      nil -> shop_catalogue()
      reason -> refusal(reason)
    end
  end

  defp shop_catalogue do
    case Query.catalogue_uuid() do
      nil -> refusal(:no_shop_catalogue)
      uuid -> {:ok, uuid}
    end
  end

  defp reason do
    cond do
      not Code.ensure_loaded?(PhoenixKitCatalogue) -> :catalogue_missing
      ProductSource.current() != ProductSource.Catalogue -> :legacy_source
      not catalogue_api_ready?() -> :catalogue_too_old
      true -> nil
    end
  end

  @doc """
  Whether the loaded catalogue ships what the admin API writes through: the
  ref resolver and the batch update, `broadcast_item_batch_change/3` (a write
  inside the API's own transaction announces itself after the commit) and
  `preview_item_update/3`,
  which the catalogue adds together with the `:log_metadata`, `:logged_data_paths` and
  `:data_owned_paths` options of the writes. `preview_item_update/3` is the
  witness for those options: an update without `:data_owned_paths` would replace a product's
  whole `data` map, and nothing at run time would notice, so a build that
  exports the batch update but not the witness is refused. It also covers
  what `API.CatalogueWrites.with_locked_items/2` queries directly: the
  catalogue's `Item` and `Category` schemas and the columns it locks by.

  Judged by what the modules export, not by a version number: a fork
  branch of the catalogue keeps the version of its base.
  """
  @spec catalogue_api_ready?() :: boolean()
  def catalogue_api_ready? do
    Code.ensure_loaded?(PhoenixKitCatalogue.API) and
      function_exported?(PhoenixKitCatalogue.API, :resolve_refs, 2) and
      Code.ensure_loaded?(PhoenixKitCatalogue.Catalogue) and
      function_exported?(PhoenixKitCatalogue.Catalogue, :update_items, 2) and
      function_exported?(PhoenixKitCatalogue.Catalogue, :preview_item_update, 3) and
      function_exported?(PhoenixKitCatalogue.Catalogue, :broadcast_item_batch_change, 3) and
      lock_schemas_ready?()
  end

  defp lock_schemas_ready? do
    schema_fields?(PhoenixKitCatalogue.Schemas.Item, [:uuid, :category_uuid]) and
      schema_fields?(PhoenixKitCatalogue.Schemas.Category, [:uuid])
  end

  defp schema_fields?(schema, fields) do
    Code.ensure_loaded?(schema) and function_exported?(schema, :__schema__, 1) and
      Enum.all?(fields, &(&1 in schema.__schema__(:fields)))
  end

  defp refusal(reason) do
    {:error, :unsupported_source, detail(reason), %{reason: Atom.to_string(reason)}}
  end

  defp detail(:catalogue_missing),
    do: "The shop has no catalogue: phoenix_kit_catalogue is not installed."

  defp detail(:legacy_source),
    do:
      "The shop reads its products from the legacy tables; the admin API writes catalogue products only."

  defp detail(:catalogue_too_old),
    do: "The installed phoenix_kit_catalogue is too old for the admin API; update it."

  defp detail(:no_shop_catalogue),
    do: "The catalogue the shop reads does not exist yet."
end
