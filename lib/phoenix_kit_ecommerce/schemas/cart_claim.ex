defmodule PhoenixKitEcommerce.CartClaim do
  @moduledoc """
  A one-time checkout claim: the hand-off from an assistant-built cart to a
  browser.

  `token_hash` is the digest of a 32-byte random token that only ever lives
  in the claim URL; `cart_token_hash` is the digest of the cart token the
  claim was issued for, kept so that a cart that has moved to a browser
  session can still answer `cart_locked` to its old token. A new link
  supersedes every earlier unused claim of the same cart (`superseded_at`).
  A claim is consumed exactly once, by the CSRF POST of the claim page
  (`used_at`).

  Rows are deleted 7 days after use or expiry by
  `PhoenixKitEcommerce.Workers.ApiClaimPruneWorker`, and with their cart.
  """

  use Ecto.Schema
  use PhoenixKit.SchemaPrefix
  import Ecto.Changeset

  alias PhoenixKitEcommerce.Cart

  @primary_key {:uuid, UUIDv7, autogenerate: true}

  @typedoc "A checkout claim row."
  @type t :: %__MODULE__{}

  schema "phoenix_kit_shop_cart_claims" do
    field :token_hash, :string
    belongs_to :cart, Cart, foreign_key: :cart_uuid, references: :uuid, type: UUIDv7
    field :cart_token_hash, :string
    field :language, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime
    field :superseded_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for creating and updating a claim."
  def changeset(claim, attrs) do
    claim
    |> cast(attrs, [
      :token_hash,
      :cart_uuid,
      :cart_token_hash,
      :language,
      :expires_at,
      :used_at,
      :superseded_at
    ])
    |> validate_required([:token_hash, :cart_uuid, :cart_token_hash, :language, :expires_at])
    |> validate_length(:token_hash, max: 64)
    |> validate_length(:cart_token_hash, max: 64)
    |> validate_length(:language, max: 16)
    |> unique_constraint(:token_hash, name: :idx_shop_cart_claims_token_hash)
    |> foreign_key_constraint(:cart_uuid, name: :fk_shop_cart_claims_cart_uuid)
  end
end
