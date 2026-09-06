defmodule PhoenixKitEcommerce.LiveCase do
  @moduledoc """
  Test case for LiveView tests. Wires up the test Endpoint, imports
  `Phoenix.LiveViewTest` helpers, and sets up an Ecto SQL sandbox
  connection.

  Tests using this case are tagged `:integration` automatically and
  get excluded when the test DB isn't available, matching the rest of
  the suite.

  ## Example

      defmodule PhoenixKitEcommerce.Web.ProductsTest do
        use PhoenixKitEcommerce.LiveCase

        test "renders", %{conn: conn} do
          {:ok, _view, html} = live(conn, "/en/admin/shop/products")
          assert html =~ "Products"
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration
      @endpoint PhoenixKitEcommerce.Test.Endpoint

      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PhoenixKitEcommerce.ActivityLogAssertions
      import PhoenixKitEcommerce.NotificationAssertions
      import PhoenixKitEcommerce.CheckoutFixtures
      # Reuse the helpers defined on DataCase so LiveView tests don't
      # need their own duplicate copies.
      import PhoenixKitEcommerce.DataCase, only: [errors_on: 1]

      import PhoenixKitEcommerce.LiveCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])
    on_exit(fn -> Sandbox.stop_owner(pid) end)

    # Storefront mounts and purchase mutations are gated on the module being
    # enabled; the suite runs with the shop ON (see the same block in
    # DataCase). Tests covering the disabled behaviour flip it off themselves.
    PhoenixKit.Settings.update_setting("shop_enabled", "true")

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn}
  end

  @doc """
  Returns a real `PhoenixKit.Users.Auth.Scope` struct for testing.

  Shop LVs read `socket.assigns[:phoenix_kit_current_user]` to thread
  the user UUID into activity logging. They don't call `Scope.can_access_admin_area?/1`
  themselves — the production `live_session :phoenix_kit_admin`
  on_mount hook gates that — but per workspace AGENTS.md `cached_roles`
  must be a list of role-name strings if `admin?/1` ever gets called,
  so we follow the convention.

  ## Options

    * `:user_uuid` — defaults to a fresh UUIDv4
    * `:email` — defaults to a unique-suffix string
    * `:roles` — list of role-name strings; defaults to `["Owner"]`
    * `:permissions` — permission keys; defaults to the FULL shop key set
      (base + every sub-permission), i.e. an operator who can do everything.
      Pass a narrower list to express a denied capability:

          fake_scope(permissions: ["shop", "shop.manage_catalog"])
          fake_scope(permissions: ["shop"], roles: ["Employee"])

      ⚠️ `roles` matters as much as `permissions`: `can_access_admin_area?/1`
      consults ROLES, so a scope left at the `["Owner"]` default passes the
      admin gate no matter how empty its permission set is. A test that means
      to express "denied" must narrow both axes.
    * `:authenticated?` — defaults to `true`

  ## Example

      conn = put_test_scope(conn, fake_scope())
      {:ok, view, _} = live(conn, "/en/admin/shop/")
  """
  def fake_scope(opts \\ []) do
    user_uuid = Keyword.get(opts, :user_uuid, Ecto.UUID.generate())
    email = Keyword.get(opts, :email, "test-#{System.unique_integer([:positive])}@example.com")
    roles = Keyword.get(opts, :roles, ["Owner"])
    permissions = Keyword.get(opts, :permissions, shop_permissions())
    authenticated? = Keyword.get(opts, :authenticated?, true)

    user = %{uuid: user_uuid, email: email}

    %PhoenixKit.Users.Auth.Scope{
      user: user,
      authenticated?: authenticated?,
      cached_roles: roles,
      cached_permissions: MapSet.new(permissions)
    }
  end

  @doc """
  The base key plus every sub-permission this module declares — derived
  from `permission_metadata/0` so a newly declared capability is covered
  by the default fixture instead of silently failing every existing test.
  """
  def shop_permissions do
    meta = PhoenixKitEcommerce.permission_metadata()
    subs = Map.get(meta, :sub_permissions, [])

    [meta.key | Enum.map(subs, &"#{meta.key}.#{&1.key}")]
  end

  @doc """
  Plugs a fake scope into the test conn's session so the
  `:assign_scope` `on_mount` hook can put it on socket assigns at
  mount time. Pair with `fake_scope/1`.
  """
  def put_test_scope(conn, scope) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_scope" => scope})
  end

  @doc """
  Plugs a display-currency CODE into the test conn's session so the
  `:assign_currency` `on_mount` hook can set it as the request-scoped
  currency at mount time (Э1-E4) — the test double for a host's own
  domain-currency hook. Pass `nil` (or omit) for "no domain mapping",
  i.e. the storefront falls back to the base currency.

  ## Example

      conn = put_test_currency(conn, "EUR")
      {:ok, view, _html} = live(conn, "/shop/product/\#{slug}")
  """
  def put_test_currency(conn, code \\ nil) do
    Plug.Test.init_test_session(conn, %{"phoenix_kit_test_currency" => code})
  end
end
