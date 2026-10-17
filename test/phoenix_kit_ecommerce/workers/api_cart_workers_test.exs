defmodule PhoenixKitEcommerce.Workers.ApiCartWorkersTest do
  @moduledoc """
  The cron jobs of the public cart API: they act on `api:`
  carts only, and on those only when idle (sweep), abandoned for long
  (prune), or when a claim is long dead (claim prune).
  """

  # async: false - settings are shared.
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.CartApiFixtures

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.CartItem
  alias PhoenixKitEcommerce.Workers.ApiCartPruneWorker
  alias PhoenixKitEcommerce.Workers.ApiCartSweepWorker
  alias PhoenixKitEcommerce.Workers.ApiClaimPruneWorker

  setup do
    ensure_currencies!()
    :ok
  end

  defp days_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400, :second) |> DateTime.truncate(:second)

  defp cart!(session_id, opts \\ []) do
    {:ok, cart} =
      Shop.create_cart(Keyword.merge([session_id: session_id], Keyword.take(opts, [:user_uuid])))

    set!(cart, opts)
  end

  # Backdates and re-statuses a cart without going through the changeset
  # (which would stamp updated_at).
  defp set!(cart, opts) do
    updates =
      [
        updated_at:
          Keyword.get(opts, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second)),
        status: Keyword.get(opts, :status, "active")
      ]

    Repo.update_all(from(c in Cart, where: c.uuid == ^cart.uuid), set: updates)
    Repo.get!(Cart, cart.uuid)
  end

  # Bulk insert of api carts, bypassing the changesets; returns their uuids.
  defp insert_carts!(count, attrs) do
    rows =
      for _ <- 1..count do
        Map.merge(
          %{
            uuid: UUIDv7.generate(),
            session_id: api_id(),
            status: "abandoned",
            subtotal: Decimal.new(0),
            shipping_amount: Decimal.new(0),
            tax_amount: Decimal.new(0),
            discount_amount: Decimal.new(0),
            total: Decimal.new(0),
            total_weight_grams: 0,
            items_count: 0,
            metadata: %{},
            inserted_at: attrs.updated_at,
            updated_at: attrs.updated_at
          },
          attrs
        )
      end

    rows |> Enum.chunk_every(300) |> Enum.each(&Repo.insert_all(Cart, &1))
    Enum.map(rows, & &1.uuid)
  end

  # Carts the prune would take, whatever else the shared database holds.
  defp expired_api_count do
    cutoff = days_ago(30)

    Repo.aggregate(
      from(c in Cart,
        where:
          c.status in ["abandoned", "merged"] and like(c.session_id, "api:%") and
            c.updated_at < ^cutoff
      ),
      :count
    )
  end

  # Carts the sweep would take, whatever else the shared database holds.
  defp idle_api_count do
    threshold = days_ago(7)

    Repo.aggregate(
      from(c in Cart,
        where: c.status == "active" and like(c.session_id, "api:%") and c.updated_at < ^threshold
      ),
      :count
    )
  end

  # How many UPDATE statements on the carts table `fun` makes.
  defp count_updates(fun) do
    test = self()
    id = "count-updates-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, %{query: query}, _config ->
        if String.starts_with?(query, ~s(UPDATE "phoenix_kit_shop_carts")),
          do: send(test, :update)
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain_updates(0)
  end

  defp drain_updates(count) do
    receive do
      :update -> drain_updates(count + 1)
    after
      0 -> count
    end
  end

  defp api_id, do: "api:" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp status(cart), do: Repo.get!(Cart, cart.uuid).status
  defp exists?(schema, uuid), do: Repo.get(schema, uuid) != nil

  describe "ApiCartSweepWorker.sweep/1" do
    test "abandons idle api carts and stamps the abandonment" do
      idle = cart!(api_id(), updated_at: days_ago(8))

      assert {:ok, 1} = ApiCartSweepWorker.sweep()

      assert status(idle) == "abandoned"
      assert DateTime.diff(DateTime.utc_now(), Repo.get!(Cart, idle.uuid).updated_at) < 60
    end

    test "leaves a recently used api cart alone" do
      fresh = cart!(api_id(), updated_at: days_ago(6))

      assert {:ok, 0} = ApiCartSweepWorker.sweep()
      assert status(fresh) == "active"
    end

    test "follows api_cart_idle_days, and falls back to 7 for junk" do
      cart = cart!(api_id(), updated_at: days_ago(4))

      put_setting!("api_cart_idle_days", 3)
      assert {:ok, 1} = ApiCartSweepWorker.sweep()
      assert status(cart) == "abandoned"

      other = cart!(api_id(), updated_at: days_ago(4))
      put_setting!("api_cart_idle_days", "never")
      assert {:ok, 0} = ApiCartSweepWorker.sweep()
      assert status(other) == "active"
    end

    test "never touches carts that are not idle api carts" do
      user = fixture_user()
      old = days_ago(400)

      lookalikes =
        for session <- ["apiary-1", "api", "xapi:foo", "API:foo", "api-foo", "browser-1"] do
          cart!(session, updated_at: old)
        end

      user_cart = cart!(nil, user_uuid: user.uuid, updated_at: old)
      converted = cart!(api_id(), updated_at: old, status: "converted")
      merged = cart!(api_id(), updated_at: old, status: "merged")
      expired = cart!(api_id(), updated_at: old, status: "expired")
      abandoned = cart!(api_id(), updated_at: old, status: "abandoned")

      assert {:ok, 0} = ApiCartSweepWorker.sweep()

      for cart <- lookalikes ++ [user_cart],
          do: assert(status(cart) == "active", inspect(cart.session_id))

      assert status(converted) == "converted"
      assert status(merged) == "merged"
      assert status(expired) == "expired"

      # An abandoned cart is not re-stamped: its 30 days before the prune count
      # from the day it was abandoned.
      assert status(abandoned) == "abandoned"
      assert Repo.get!(Cart, abandoned.uuid).updated_at == abandoned.updated_at
    end

    test "leaves an idle cart with a live checkout link alone, and sweeps it once the link is dead" do
      live_until = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.truncate(:second)

      linked = cart!(api_id(), updated_at: days_ago(8))
      claim!(linked, expires_at: live_until)

      dead =
        for opts <- [
              [expires_at: days_ago(1)],
              [expires_at: live_until, used_at: days_ago(0)],
              [expires_at: live_until, superseded_at: days_ago(0)]
            ] do
          cart = cart!(api_id(), updated_at: days_ago(8))
          claim!(cart, opts)
          cart
        end

      assert {:ok, 3} = ApiCartSweepWorker.sweep()

      assert status(linked) == "active"
      for cart <- dead, do: assert(status(cart) == "abandoned")

      # The link expires: the next sweep takes the cart.
      assert {:ok, 1} = ApiCartSweepWorker.sweep(DateTime.add(live_until, 60, :second))
      assert status(linked) == "abandoned"
    end

    test "abandons every idle cart when there are more than one batch of them, one statement per batch" do
      idle = insert_carts!(1003, %{status: "active", updated_at: days_ago(10)})
      young = cart!(api_id(), updated_at: days_ago(2))
      before = idle_api_count()
      assert before >= 1003

      updates = count_updates(fn -> assert {:ok, ^before} = ApiCartSweepWorker.sweep() end)

      assert idle_api_count() == 0

      assert Repo.aggregate(
               from(c in Cart, where: c.uuid in ^idle and c.status == "abandoned"),
               :count
             ) == 1003

      assert status(young) == "active"
      assert updates == div(before, 500) + 1
    end

    # The subquery that picks a batch must itself select idle carts only: a
    # batch of the first 500 rows would be all young or converted carts here, the
    # UPDATE would skip every one of them and the run would stop at once.
    test "finds the idle carts behind more than one batch of carts that are not idle" do
      young = insert_carts!(300, %{status: "active", updated_at: days_ago(2)})
      converted = insert_carts!(300, %{status: "converted", updated_at: days_ago(100)})
      idle = insert_carts!(3, %{status: "active", updated_at: days_ago(10)})

      assert {:ok, swept} = ApiCartSweepWorker.sweep()
      assert swept >= 3

      assert Repo.aggregate(
               from(c in Cart, where: c.uuid in ^idle and c.status == "abandoned"),
               :count
             ) == 3

      assert Repo.aggregate(
               from(c in Cart, where: c.uuid in ^young and c.status == "active"),
               :count
             ) == 300

      assert Repo.aggregate(
               from(c in Cart, where: c.uuid in ^converted and c.status == "converted"),
               :count
             ) == 300
    end

    test "perform/1 sweeps while the shop is on and does nothing while it is off" do
      idle = cart!(api_id(), updated_at: days_ago(8))

      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")
      assert :ok = ApiCartSweepWorker.perform(%Oban.Job{})
      assert status(idle) == "active"

      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "true")
      assert :ok = ApiCartSweepWorker.perform(%Oban.Job{})
      assert status(idle) == "abandoned"
    end
  end

  describe "ApiCartPruneWorker.prune/1" do
    test "deletes empty abandoned api carts older than 30 days, with their claims" do
      old = cart!(api_id(), status: "abandoned", updated_at: days_ago(31))
      claim = claim!(old)

      assert {:ok, deleted} = ApiCartPruneWorker.prune()
      assert deleted >= 1

      refute exists?(Cart, old.uuid)
      refute exists?(CartClaim, claim.uuid)
    end

    # The "add these items" choice of the claim page merges the assistant's
    # cart away and keeps its lines and its `api:` session.
    test "deletes a merged api cart, and keeps a young one" do
      old = cart!(api_id(), status: "merged", updated_at: days_ago(31))
      young = cart!(api_id(), status: "merged", updated_at: days_ago(29))

      assert {:ok, deleted} = ApiCartPruneWorker.prune()
      assert deleted >= 1

      refute exists?(Cart, old.uuid)
      assert exists?(Cart, young.uuid)
    end

    test "deletes an abandoned api cart that has lines, with its lines" do
      with_lines = cart!(api_id(), updated_at: days_ago(100))
      {:ok, _} = Shop.add_to_cart(with_lines, product!(), 1)
      with_lines = set!(with_lines, status: "abandoned", updated_at: days_ago(100))

      assert Repo.aggregate(from(i in CartItem, where: i.cart_uuid == ^with_lines.uuid), :count) ==
               1

      assert {:ok, deleted} = ApiCartPruneWorker.prune()
      assert deleted >= 1

      refute exists?(Cart, with_lines.uuid)

      assert Repo.aggregate(from(i in CartItem, where: i.cart_uuid == ^with_lines.uuid), :count) ==
               0
    end

    test "keeps younger carts, active carts and carts that are not api carts, with or without lines" do
      young = cart!(api_id(), status: "abandoned", updated_at: days_ago(29))
      active = cart!(api_id(), status: "active", updated_at: days_ago(100))
      browser = cart!("browser-9", status: "abandoned", updated_at: days_ago(100))
      converted = cart!(api_id(), status: "converted", updated_at: days_ago(100))

      young_lines = cart!(api_id(), updated_at: days_ago(29))
      {:ok, _} = Shop.add_to_cart(young_lines, product!(), 1)
      young_lines = set!(young_lines, status: "abandoned", updated_at: days_ago(29))

      browser_lines = cart!("browser-10", updated_at: days_ago(100))
      {:ok, _} = Shop.add_to_cart(browser_lines, product!(), 1)
      browser_lines = set!(browser_lines, status: "abandoned", updated_at: days_ago(100))

      assert {:ok, _deleted} = ApiCartPruneWorker.prune()

      for cart <- [young, active, browser, converted, young_lines, browser_lines],
          do: assert(exists?(Cart, cart.uuid))
    end

    test "deletes every expired cart when there are more than one batch of them" do
      young = cart!(api_id(), status: "abandoned", updated_at: days_ago(2))
      expired = insert_carts!(1003, %{updated_at: days_ago(40)})
      before = expired_api_count()
      assert before >= 1003

      assert {:ok, ^before} = ApiCartPruneWorker.prune()

      assert expired_api_count() == 0
      assert Repo.aggregate(from(c in Cart, where: c.uuid in ^expired), :count) == 0
      assert exists?(Cart, young.uuid)
    end

    # The subquery that picks a batch must itself select expired carts only: a
    # batch of the first 500 rows would be all young or active carts here, the
    # DELETE would keep every one of them and the run would stop at once.
    test "finds the expired carts behind more than one batch of carts that are not expired" do
      young = insert_carts!(300, %{updated_at: days_ago(2)})
      active = insert_carts!(300, %{status: "active", updated_at: days_ago(100)})
      expired = insert_carts!(3, %{updated_at: days_ago(40)})

      assert {:ok, deleted} = ApiCartPruneWorker.prune()
      assert deleted >= 3

      assert Repo.aggregate(from(c in Cart, where: c.uuid in ^expired), :count) == 0
      assert Repo.aggregate(from(c in Cart, where: c.uuid in ^young), :count) == 300
      assert Repo.aggregate(from(c in Cart, where: c.uuid in ^active), :count) == 300
    end

    test "perform/1 does nothing while the shop is off" do
      old = cart!(api_id(), status: "abandoned", updated_at: days_ago(31))

      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")
      assert :ok = ApiCartPruneWorker.perform(%Oban.Job{})
      assert exists?(Cart, old.uuid)

      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "true")
      assert :ok = ApiCartPruneWorker.perform(%Oban.Job{})
      refute exists?(Cart, old.uuid)
    end
  end

  describe "ApiClaimPruneWorker.prune/1" do
    test "deletes claims used or expired more than 7 days ago and keeps the rest" do
      cart = cart!(api_id())
      # Used long ago but not expired by its own clock: only `used_at` can delete it.
      long_used =
        claim!(cart,
          used_at: days_ago(8),
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:second)
        )

      long_expired = claim!(cart, expires_at: days_ago(8))
      recently_used = claim!(cart, used_at: days_ago(6), expires_at: days_ago(0))
      recently_expired = claim!(cart, expires_at: days_ago(6))

      live =
        claim!(cart,
          expires_at: DateTime.add(DateTime.utc_now(), 600, :second) |> DateTime.truncate(:second)
        )

      assert {:ok, 2} = ApiClaimPruneWorker.prune()

      refute exists?(CartClaim, long_used.uuid)
      refute exists?(CartClaim, long_expired.uuid)

      for claim <- [recently_used, recently_expired, live],
          do: assert(exists?(CartClaim, claim.uuid))
    end

    test "perform/1 does nothing while the shop is off" do
      cart = cart!(api_id())
      old = claim!(cart, expires_at: days_ago(30))

      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "false")
      assert :ok = ApiClaimPruneWorker.perform(%Oban.Job{})
      assert exists?(CartClaim, old.uuid)

      {:ok, _} = PhoenixKit.Settings.update_setting("shop_enabled", "true")
      assert :ok = ApiClaimPruneWorker.perform(%Oban.Job{})
      refute exists?(CartClaim, old.uuid)
    end
  end

  describe "oban_crons/0" do
    test "declares the three workers next to the search rebuild, each with a schedule Oban accepts and a worker that runs" do
      crons = Shop.oban_crons()

      for entry <- [
            {"17 * * * *", ApiCartSweepWorker},
            {"40 4 * * *", ApiCartPruneWorker},
            {"50 4 * * *", ApiClaimPruneWorker}
          ] do
        assert entry in crons, inspect(entry)
      end

      assert crons == Enum.uniq(crons)
      assert Enum.uniq_by(crons, &elem(&1, 1)) == crons

      for {cron, worker} <- crons do
        assert {:ok, _expression} = Oban.Cron.parse(cron)
        assert Code.ensure_loaded?(worker) and function_exported?(worker, :perform, 1)
      end
    end
  end

  defp claim!(cart, opts \\ []) do
    {:ok, claim} =
      %CartClaim{}
      |> CartClaim.changeset(%{
        token_hash: "th-#{System.unique_integer([:positive])}",
        cart_uuid: cart.uuid,
        cart_token_hash: "ch-#{System.unique_integer([:positive])}",
        language: "en",
        expires_at: Keyword.get(opts, :expires_at, days_ago(0)),
        used_at: Keyword.get(opts, :used_at),
        superseded_at: Keyword.get(opts, :superseded_at)
      })
      |> Repo.insert()

    claim
  end
end
