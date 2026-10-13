defmodule PhoenixKitEcommerce.Shipping.CredentialsTest do
  @moduledoc """
  Which Integrations connection a provider's credentials may come from: a
  system connection of the provider's own integration, nothing else.
  """

  # Changes the application env (provider registry).
  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKit.Integrations
  alias PhoenixKitEcommerce.Shipping

  defmodule AcmeProvider do
    @moduledoc false
    @behaviour PhoenixKitEcommerce.Shipping.Provider

    @impl true
    def key, do: "acme_post"
    @impl true
    def label, do: "Acme Post"
    @impl true
    def services(_ctx), do: []
    @impl true
    def settings_fields, do: []
    @impl true
    def quote(_request, _ctx), do: {:error, :not_supported}

    # Borrows a registered integration, so a real connection can be made.
    @impl true
    def integration do
      %{
        key: "shopify",
        name: "Acme",
        auth_type: :api_key,
        setup_fields: [],
        capabilities: [:shipping]
      }
    end
  end

  defmodule PersonalAcmeProvider do
    @moduledoc false
    @behaviour PhoenixKitEcommerce.Shipping.Provider

    @impl true
    def key, do: "personal_acme"
    @impl true
    def label, do: "Personal Acme"
    @impl true
    def services(_ctx), do: []
    @impl true
    def settings_fields, do: []
    @impl true
    def quote(_request, _ctx), do: {:error, :not_supported}

    # An integration that a user may connect personally.
    @impl true
    def integration do
      %{key: "openai", name: "Acme", auth_type: :api_key, setup_fields: [], capabilities: []}
    end
  end

  setup do
    # The connections borrow the Shopify integration, which is off by default.
    enable_shopify!()

    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)

    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
      AcmeProvider,
      PersonalAcmeProvider
    ])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)

    :ok
  end

  defp connection!(provider_key, opts \\ []) do
    {:ok, %{uuid: uuid}} =
      Integrations.add_connection(
        provider_key,
        "Conn #{System.unique_integer([:positive])}",
        nil,
        opts
      )

    {:ok, _} =
      Integrations.save_setup(
        uuid,
        %{"shop_domain" => "acme.example.com", "access_token" => "secret-token"},
        nil,
        opts
      )

    uuid
  end

  defp context(settings),
    do: Shipping.context(nil, provider: AcmeProvider, settings: settings)

  test "a system connection of the provider's integration is used" do
    uuid = connection!("shopify")

    assert %{"access_token" => "secret-token", "provider" => "shopify"} =
             context(%{"integration" => uuid}).credentials
  end

  test "without a chosen connection the first one of the integration is used" do
    connection!("shopify")

    assert %{"provider" => "shopify"} = context(%{}).credentials
  end

  test "a connection of another integration is refused, with a warning that names no secret" do
    foreign = connection!("openai")

    log =
      capture_log(fn ->
        assert context(%{"integration" => foreign}).credentials == nil
      end)

    assert log =~ "ignored"
    refute log =~ "secret-token"
    refute log =~ foreign
  end

  test "a connection that is not a system one is not lent out" do
    owned = connection!("openai", owner: {:user, Ecto.UUID.generate()})

    ctx =
      Shipping.context(nil, provider: PersonalAcmeProvider, settings: %{"integration" => owned})

    assert ctx.credentials == nil

    # The same connection as a system one would have been lent.
    system = connection!("openai")

    ctx =
      Shipping.context(nil, provider: PersonalAcmeProvider, settings: %{"integration" => system})

    assert %{"provider" => "openai"} = ctx.credentials
  end

  test "an unknown uuid leaves the credentials empty" do
    assert context(%{"integration" => Ecto.UUID.generate()}).credentials == nil
  end
end
