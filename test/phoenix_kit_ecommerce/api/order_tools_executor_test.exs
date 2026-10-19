defmodule PhoenixKitEcommerce.API.OrderToolsExecutorTest do
  @moduledoc """
  The order tools through core's real `Executor.call/4`: a real user with real
  role permissions, a real key, the real scope check. What `OrderToolsTest`
  leaves out is checked here: which scopes a key can be given, the refusal of a
  tool whose scope the key lacks, and the contacts of a buyer reaching only a
  key that holds `ecommerce.orders:customer`.

  `async: false`: it registers a key cache, flips settings and uses the
  shop-wide rate limiter.
  """

  use PhoenixKitEcommerce.DataCase, async: false

  @moduletag :core_confirm
  @moduletag :billing_order_sync

  @compile {:no_warn_undefined,
            [
              PhoenixKit.API.Auth,
              PhoenixKit.API.Executor,
              PhoenixKit.API.Keys,
              PhoenixKit.API.Keys.Cache,
              PhoenixKit.Cache,
              PhoenixKit.Cache.Registry,
              PhoenixKit.Users.Auth.Scope,
              PhoenixKit.Users.Permissions,
              PhoenixKit.Users.Roles
            ]}

  import PhoenixKitEcommerce.OrderFixtures
  import Plug.Conn

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.Keys
  alias PhoenixKit.Settings
  alias PhoenixKit.Users.Auth.Scope
  alias PhoenixKit.Users.Permissions
  alias PhoenixKit.Users.Roles
  alias PhoenixKitBilling.Order

  @read "ecommerce.orders:read"
  @sync "ecommerce.orders:sync"
  @customer "ecommerce.orders:customer"

  setup do
    start_supervised!({PhoenixKit.Cache.Registry, []})
    start_supervised!({PhoenixKit.Cache, name: :api_keys, ttl: :timer.seconds(60)})
    start_supervised!(PhoenixKit.API.Keys.Cache)

    shop = Settings.get_boolean_setting("shop_enabled", false)

    secret = Application.get_env(:phoenix_kit, :secret_key_base)
    Application.put_env(:phoenix_kit, :secret_key_base, String.duplicate("c", 64))

    on_exit(fn ->
      if secret,
        do: Application.put_env(:phoenix_kit, :secret_key_base, secret),
        else: Application.delete_env(:phoenix_kit, :secret_key_base)

      Settings.update_boolean_setting_with_module("shop_enabled", shop, "shop")
    end)

    {:ok, _} = Settings.update_boolean_setting("api_admin_enabled", true)
    {:ok, _} = Settings.update_boolean_setting_with_module("shop_enabled", true, "shop")

    %{owner: owner_with(["shop", "shop.manage_orders"])}
  end

  defp owner_with(permissions) do
    {:ok, role} = Roles.create_role(%{name: "OrderApi#{System.unique_integer([:positive])}"})
    for key <- ["api" | permissions], do: {:ok, _} = Permissions.grant_permission(role.uuid, key)
    user = fixture_user()

    for assigned <- Roles.get_user_role_records(user),
        do: {:ok, _} = Roles.remove_role(user, assigned.name)

    {:ok, user} =
      user
      |> Ecto.Changeset.change(confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.update()

    {:ok, _} = Roles.assign_role(user, role.name)
    user
  end

  defp token_for(owner, scopes) do
    scope = Scope.for_user(owner, narrow: false)
    {:ok, _key, token} = Keys.create_key(owner, scope, %{name: "orders", scopes: scopes})
    token
  end

  defp call(token, tool, input) do
    n = System.unique_integer([:positive])
    peer = {10, rem(n, 250) + 1, rem(div(n, 250), 250) + 1, rem(div(n, 62_500), 250) + 1}

    conn =
      :post
      |> Plug.Test.conn("/")
      |> Map.put(:remote_ip, peer)
      |> put_req_header("authorization", "Bearer " <> token)
      |> Auth.call(Auth.init(audience: :admin))

    if conn.halted, do: conn, else: Executor.call(conn, :admin, tool, input)
  end

  defp json(conn), do: Jason.decode!(conn.resp_body)

  describe "scopes" do
    test "an owner with the shop and order permissions can be given all three order scopes", %{
      owner: owner
    } do
      allowed = Keys.allowed_scopes_for(owner)

      for scope <- [@read, @sync, @customer], do: assert(scope in allowed, scope)
    end

    test "an owner without manage_orders can read orders but not mark them or see buyers" do
      reader = owner_with(["shop"])
      allowed = Keys.allowed_scopes_for(reader)

      assert @read in allowed
      refute @sync in allowed
      refute @customer in allowed

      scope = Scope.for_user(reader, narrow: false)

      assert {:error, :invalid_scopes} =
               Keys.create_key(reader, scope, %{name: "too much", scopes: [@read, @customer]})
    end
  end

  describe "through the executor" do
    test "list_orders answers 200 with the buyer's id and type only", %{owner: owner} do
      order = order!()
      token = token_for(owner, [@read])

      conn =
        call(token, "ecommerce.list_orders", %{
          "updated_since" => "2000-01-01T00:00:00Z",
          "limit" => 100
        })

      assert conn.status == 200
      row = Enum.find(json(conn)["orders"], &(&1["id"] == order.uuid))
      assert Map.keys(row["customer"]) |> Enum.sort() == ["id", "type"]
      refute conn.resp_body =~ "Petrenko"
    end

    test "a key with the customer scope as well gets the contacts", %{owner: owner} do
      order = order!()
      token = token_for(owner, [@read, @customer])

      conn = call(token, "ecommerce.get_orders", %{"refs" => [%{"id" => order.uuid}]})

      assert conn.status == 200

      assert %{"results" => [%{"order" => %{"customer" => %{"last_name" => "Petrenko"}}}]} =
               json(conn)
    end

    test "get_order_customers is refused to a key without the customer scope", %{owner: owner} do
      order = order!()
      token = token_for(owner, [@read])

      conn = call(token, "ecommerce.get_order_customers", %{"refs" => [%{"id" => order.uuid}]})

      assert conn.status == 403
      assert %{"code" => "forbidden", "context" => %{"required_scope" => @customer}} = json(conn)
    end

    test "set_order_sync is refused to a read key and works for a sync key", %{owner: owner} do
      order = order!()

      row = %{
        "ref" => %{"id" => order.uuid},
        "revision" => 1,
        "state" => "synced",
        "external_id" => "G"
      }

      conn = call(token_for(owner, [@read]), "ecommerce.set_order_sync", %{"orders" => [row]})
      assert conn.status == 403
      assert %{"context" => %{"required_scope" => @sync}} = json(conn)
      refute Map.has_key?(PhoenixKitBilling.get_order(order.uuid).metadata, "sync")

      conn = call(token_for(owner, [@sync]), "ecommerce.set_order_sync", %{"orders" => [row]})
      assert conn.status == 200
      assert %{"summary" => %{"marked" => 1}} = json(conn)
      assert Order.sync(PhoenixKitBilling.get_order(order.uuid))["external_id"] == "G"
    end

    test "a limit above 100 is 422, not a cut", %{owner: owner} do
      conn = call(token_for(owner, [@read]), "ecommerce.list_orders", %{"limit" => 101})

      assert conn.status == 422
      assert json(conn)["code"] == "validation_failed"
    end

    test "a cursor this tool did not issue is 422", %{owner: owner} do
      bad = Base.url_encode64(~s({"t":123,"u":"#{Ecto.UUID.generate()}"}), padding: false)

      conn = call(token_for(owner, [@read]), "ecommerce.list_orders", %{"cursor" => bad})

      assert conn.status == 422
      assert json(conn)["code"] == "validation_failed"
    end

    test "a stale revision is a row conflict inside a 200", %{owner: owner} do
      order = order!()
      {:ok, _} = PhoenixKitBilling.update_order(order, %{"notes" => "edited"})
      row = %{"ref" => %{"id" => order.uuid}, "revision" => 1, "state" => "synced"}

      conn = call(token_for(owner, [@sync]), "ecommerce.set_order_sync", %{"orders" => [row]})

      assert conn.status == 200

      assert %{
               "results" => [
                 %{
                   "error" => %{
                     "code" => "conflict",
                     "context" => %{"reason" => "stale_revision"}
                   }
                 }
               ]
             } =
               json(conn)
    end
  end
end
