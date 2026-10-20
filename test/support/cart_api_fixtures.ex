defmodule PhoenixKitEcommerce.CartApiFixtures do
  @moduledoc """
  Fixtures for the public cart API tests: a signing secret, currencies,
  products, handler contexts and a way to run a tool through core's real
  executor. Imported explicitly by the tests that need it.
  """

  alias PhoenixKit.API.Auth
  alias PhoenixKit.API.Executor
  alias PhoenixKit.API.MCP
  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.CartToken
  alias PhoenixKitEcommerce.API.CartView
  alias PhoenixKitEcommerce.API.Claims
  alias PhoenixKitEcommerce.Cart
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.SearchFixtures

  # This module is loaded by `test_helper.exs` on every run, also against a core
  # that does not have the shop API (the tests that need it carry
  # `@moduletag :requires_core_api` and are excluded then). Core's API modules are
  # therefore only named at run time here: no struct literal, no compile-time
  # reference.
  @compile {:no_warn_undefined,
            [
              PhoenixKit.API.Actor,
              PhoenixKit.API.Auth,
              PhoenixKit.API.Executor,
              PhoenixKit.API.MCP
            ]}

  @secret String.duplicate("s", 64)

  @doc """
  The revision of the cart a claim link is about, as the claim page would carry
  it (`""` for a link nobody issued). `Claims.redeem/3` requires it.
  """
  def claim_revision(raw) do
    repo = PhoenixKit.RepoHelper.repo()
    digest = CartToken.digest(raw)

    with %CartClaim{cart_uuid: cart_uuid} <-
           repo.get_by(CartClaim, token_hash: digest),
         %Cart{} = cart <- Shop.get_cart(cart_uuid) do
      CartView.revision(cart)
    else
      _no_such_claim_or_cart -> ""
    end
  end

  @doc """
  `Claims.redeem/3` for a decision that was made on the page as it stands: the
  decision gets the cart's current revision unless it names one.
  """
  def redeem_shown(raw, browser, decision) do
    Claims.redeem(
      raw,
      browser,
      Map.put_new(decision, :revision, claim_revision(raw))
    )
  end

  @doc "Gives `CartToken` a signing secret for the current test."
  def put_secret! do
    Application.put_env(:phoenix_kit, :secret_key_base, @secret)
    ExUnit.Callbacks.on_exit(fn -> Application.delete_env(:phoenix_kit, :secret_key_base) end)
    :ok
  end

  @doc "A default USD and a EUR currency, and no request currency left over from another test."
  def ensure_currencies! do
    PhoenixKitBilling.Currency.put_request_currency(nil)
    SearchFixtures.currencies!()
    PhoenixKit.Cache.clear(:billing_currencies)
    ExUnit.Callbacks.on_exit(fn -> PhoenixKitBilling.Currency.put_request_currency(nil) end)
    :ok
  end

  defp lang do
    PhoenixKitEcommerce.SlugResolver.normalize_language_public(
      PhoenixKitEcommerce.Translations.default_language()
    )
  end

  @doc "An active digital Legacy-source product (no shipping, no options)."
  def product!(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    attrs =
      Map.merge(
        %{
          "title" => %{"en" => "Widget #{n}", lang() => "Widget #{n}"},
          "slug" => %{lang() => "widget-#{n}"},
          "price" => Decimal.new("10.00"),
          "status" => "active",
          "currency" => "USD",
          "product_type" => "digital",
          "requires_shipping" => false,
          "weight_grams" => 0
        },
        overrides
      )

    {:ok, product} = Shop.create_product(attrs)
    product
  end

  @doc "An active physical product, 500 g, that needs shipping."
  def physical_product!(overrides \\ %{}) do
    product!(
      Map.merge(
        %{"product_type" => "physical", "requires_shipping" => true, "weight_grams" => 500},
        overrides
      )
    )
  end

  @doc """
  A product with discovered options: `options` is `%{"color" => ["Red", "Blue"]}`.
  Under the Legacy source an option value's key is its slugified label
  (`"red"`, `"blue"`).
  """
  def product_with_options!(options, overrides \\ %{}) when is_map(options) do
    product!(Map.merge(%{"metadata" => %{"_option_values" => options}}, overrides))
  end

  @doc """
  Whether the current transaction holds the advisory lock that
  `Shop.lock_cart_identity!/2` takes for `key` (`"shop_cart_session:" <> id` or
  `"shop_cart_user:" <> uuid`). The SQL sandbox runs a test in one transaction, so
  this is how a test sees a lock that a production transaction would hold until
  its commit.
  """
  def advisory_lock_held?(key) do
    %{rows: [[count]]} =
      PhoenixKit.RepoHelper.repo().query!(
        """
        SELECT count(*) FROM pg_locks
        WHERE locktype = 'advisory' AND granted AND pid = pg_backend_pid()
          AND objsubid = 1 AND objid::text::bigint = (hashtext($1)::bigint & 4294967295)
        """,
        [key]
      )

    count > 0
  end

  @doc """
  Whether the current transaction holds a row lock on the cart (`FOR UPDATE`
  stamps the locking transaction into the row's `xmax`; a row nobody has locked
  or deleted has 0 there).
  """
  def cart_row_locked?(cart_uuid) do
    %{rows: [[xmax]]} =
      PhoenixKit.RepoHelper.repo().query!(
        "SELECT xmax::text::bigint FROM phoenix_kit_shop_carts WHERE uuid = $1",
        [Ecto.UUID.dump!(cart_uuid)]
      )

    xmax != 0
  end

  @doc """
  Runs `fun` once, after the first `verb` (`"INSERT"`, `"SELECT"`) statement on
  `table`, inside the process that ran it: a way to change the world between two
  steps of the code under test.
  """
  def after_first_query(verb, table, fun) do
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.source == table and String.starts_with?(meta.query, verb) do
          :telemetry.detach(id)
          fun.()
        end
      end,
      nil
    )

    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc "The product ids of the cart-item INSERTs `fun` runs, in statement order."
  def inserted_item_products(products, fun) do
    id = {__MODULE__, make_ref()}
    test = self()

    :telemetry.attach(
      id,
      [:phoenix_kit_ecommerce, :test, :repo, :query],
      fn _event, _measurements, meta, _config ->
        if meta.source == "phoenix_kit_shop_cart_items" and
             String.starts_with?(meta.query, "INSERT"),
           do: send(test, {:item_insert, meta.params})
      end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    known = Map.new(products, &{Ecto.UUID.dump!(&1.uuid), &1.uuid})
    known = Map.merge(known, Map.new(products, &{&1.uuid, &1.uuid}))
    drain_item_inserts(known, [])
  end

  defp drain_item_inserts(known, acc) do
    receive do
      {:item_insert, params} ->
        found = Enum.find_value(params, &Map.get(known, &1))
        drain_item_inserts(known, [found | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  @doc """
  A host app's `:api_request_context` hook (`{CartApiFixtures, :pinned_hosts}`)
  that names the one domain the install serves.
  """
  def pinned_hosts(_conn), do: %{hosts: ["shop.test"]}

  @doc "A client address that no other test uses (one bucket per test)."
  def unique_ip do
    n = System.unique_integer([:positive])
    "198.51.#{rem(div(n, 250), 250)}.#{rem(n, 250) + 1}"
  end

  @doc "A token the server would believe."
  def new_token! do
    {:ok, token} = CartToken.mint()
    token
  end

  @doc "A handler context, the shape core's executor passes."
  def ctx(overrides \\ %{}) do
    Map.merge(
      %{
        actor: build_actor(unique_ip(), nil),
        scopes: [],
        audience: :public,
        language: "en",
        currency: nil,
        hosts: ["shop.test"],
        base_url: "https://shop.test",
        request_id: "req-test",
        dry_run?: false
      },
      overrides
    )
  end

  @doc "A context whose actor carries the hash of `token`."
  def ctx_for(token, overrides \\ %{}) do
    ctx(Map.put(overrides, :actor, build_actor(unique_ip(), CartToken.digest(token))))
  end

  @doc """
  A public caller, built without naming the struct at compile time. The hash
  lives in `client_token_hash` of a core with the module-neutral API and in
  `cart_token_hash` of an older one.
  """
  def build_actor(ip, token_hash) do
    struct!(PhoenixKit.API.Actor, [{:kind, :anonymous}, {:ip, ip}, {token_field(), token_hash}])
  end

  @doc "The same caller with another client token hash."
  def put_token_hash(actor, token_hash), do: Map.put(actor, token_field(), token_hash)

  defp token_field do
    if Map.has_key?(struct(PhoenixKit.API.Actor), :client_token_hash),
      do: :client_token_hash,
      else: :cart_token_hash
  end

  @doc "Writes a setting the way the admin pages do (string value)."
  def put_setting!(key, value) do
    {:ok, _} = Settings.update_setting(key, to_string(value))
    :ok
  end

  @doc "Switches the public API on."
  def enable_public_api!, do: put_setting!("api_public_enabled", "true")

  @doc """
  Runs a public tool through core's `Auth` and `Executor` on a `Plug.Test`
  connection and returns `{status, decoded_body, conn}`. Every call gets its own
  client address unless `ip:` is given; `headers:` adds request headers (for
  example an idempotency key); `host:` is the Host the request names.
  """
  def call_tool(name, input, opts \\ []) do
    enable_public_api!()
    ip = Keyword.get(opts, :ip, unique_ip())
    origin = if host = Keyword.get(opts, :host), do: "http://#{host}", else: ""

    conn =
      :post
      |> Plug.Test.conn(origin <> "/api/public/v1/#{name}", "")
      |> Plug.Conn.put_req_header("x-forwarded-for", ip)
      |> Plug.Conn.put_req_header("content-type", "application/json")

    conn =
      Enum.reduce(Keyword.get(opts, :headers, []), conn, fn {key, value}, acc ->
        Plug.Conn.put_req_header(acc, key, value)
      end)

    conn = Auth.call(conn, Auth.init(audience: :public))
    conn = if conn.halted, do: conn, else: Executor.call(conn, :public, name, input)

    {conn.status, decode(conn.resp_body), conn}
  end

  @doc """
  Sends one JSON-RPC request to core's MCP plug for the public audience
  (`POST /mcp/public`) and returns `{status, decoded_body, conn}`. Core's own
  `McpHarness` is core test support and is not available here, so the
  connection is built by hand the way that harness builds it: the parsed body as
  `body_params`, the client address through `X-Forwarded-For` (believed because
  the test peer is loopback), `Accept` and the protocol version header of a
  well-behaved client. Every call gets its own address unless `ip:` is given.
  """
  def mcp_request(method, params, opts \\ []) do
    enable_public_api!()
    ip = Keyword.get(opts, :ip, unique_ip())

    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => method}
    message = if params == nil, do: message, else: Map.put(message, "params", params)

    conn =
      :post
      |> Plug.Test.conn("/", message)
      |> Plug.Conn.put_req_header("x-forwarded-for", ip)
      |> Plug.Conn.put_req_header("accept", "application/json")
      |> Plug.Conn.put_req_header("mcp-protocol-version", "2025-06-18")

    conn = MCP.call(conn, MCP.init(audience: :public))
    {conn.status, decode(conn.resp_body), conn}
  end

  @doc "`tools/call` for `name` (dotted or underscored) with `arguments`."
  def call_mcp(name, arguments, opts \\ []) do
    mcp_request("tools/call", %{"name" => name, "arguments" => arguments}, opts)
  end

  defp decode(body) do
    case Jason.decode(to_string(body)) do
      {:ok, decoded} -> decoded
      _ -> body
    end
  end

  @doc """
  Clears the assistant-signal counters. Hammer's `set/3` takes a positive count,
  so a counter cannot be zeroed one by one: the whole table of the rate limiter is
  emptied instead.
  """
  def reset_signal_counters! do
    :ets.delete_all_objects(PhoenixKit.Users.RateLimiter.Backend)
    :ok
  end
end
