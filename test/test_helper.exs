require Logger

# Test helper for PhoenixKitEcommerce.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests (tagged `:integration` via
#          PhoenixKitEcommerce.DataCase / LiveCase) require PostgreSQL —
#          automatically excluded when the database is unavailable.
#
# First-time setup:
#
#   createdb phoenix_kit_ecommerce_test
#
# After that, `mix test` boots the repo, runs core's versioned migrations
# via `PhoenixKit.Migration.ensure_current/2`, applies this module's own
# chain (`PhoenixKitEcommerce.Migrations`) on top, and lets the Ecto
# sandbox handle isolation.

# Elixir 1.19's `mix test` no longer auto-loads modules from
# `:elixirc_paths` test directories at test-helper time — only files
# matching `:test_load_filters` get loaded by the test runner. Explicit
# `Code.require_file/2` is needed before `test_helper.exs` references
# the support modules.
support_dir = Path.expand("support", __DIR__)

[
  "test_repo.ex",
  "test_layouts.ex",
  "hooks.ex",
  "test_router.ex",
  "test_endpoint.ex",
  "activity_log_assertions.ex",
  "notification_assertions.ex",
  "checkout_fixtures.ex",
  "shopify_fixtures.ex",
  "search_fixtures.ex",
  "data_case.ex",
  "live_case.ex",
  "cart_api_fixtures.ex",
  "api_fixtures.ex",
  "api_case.ex",
  "order_fixtures.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

db_name =
  Application.get_env(:phoenix_kit_ecommerce, TestRepo, [])[:database] ||
    "phoenix_kit_ecommerce_test"

# The preflight ships in core, and older cores this helper has run against
# predate it — so it is used when the running core has it, and otherwise
# this falls through to exactly the previous behaviour.
db_check =
  if Code.ensure_loaded?(PhoenixKit.TestSupport.PostgresPreflight) do
    # One classified connection attempt, with the repo's OWN credentials and
    # transport, before anything starts the pool.
    #
    # This replaces a `psql -lqt` listing. That check asked the wrong question:
    # it ran as the shell's user over a unix socket, so it reported "the
    # database is there" and said nothing about whether the CONFIGURED role
    # could reach it over TCP. When it could not, the answer arrived minutes
    # later as a pool checkout timeout that reads like a flaky test.
    case PhoenixKit.TestSupport.PostgresPreflight.check(
           Application.get_env(:phoenix_kit_ecommerce, PhoenixKitEcommerce.Test.Repo, [])
         ) do
      :ok ->
        :exists

      {:error, _reason, message} ->
        IO.puts(:stderr, "\n" <> message)
        :not_found
    end
  else
    :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""

      Cannot reach test database "#{db_name}" — integration tests excluded.
       The reason is printed above.
    """)

    false
  else
    try do
      {:ok, _} = TestRepo.start_link()

      # Build the schema directly from core's versioned migrations — same
      # call the host app makes in production. `ensure_current/2`
      # re-applies any newly-shipped Vxxx migrations on every boot.
      PhoenixKit.Migration.ensure_current(TestRepo, log: false)

      # ...then the module-owned chain on top. V1 was purely adoptive over
      # core's baseline, so skipping it changed nothing; V2 is not — it
      # drops the `DEFAULT 'USD'` core declares on the four `currency`
      # columns, and a test database that never ran it would still hand
      # out "USD" behind the schemas' backs. `up/1` needs an
      # `Ecto.Migration` runner, so the statements are executed directly —
      # that is exactly what `up_statements/1` exists for, and every one of
      # them is idempotent.
      Enum.each(PhoenixKitEcommerce.Migrations.up_statements(), &TestRepo.query!/1)

      # ...and billing's own chain, because this module reads and writes
      # billing's schemas directly (checkout converts a cart through them).
      # `phoenix_kit_currencies` is created by CORE's migrations, but
      # billing (floor raised to "~> 0.11" for per-domain-currency) OWNS
      # extending it — `rounding_rule`, `rate_updated_at`, the partial
      # default-currency index — via its own versioned chain, never core's.
      # Without this, a freshly fetched billing (0.11+) raises
      # `undefined_column: rounding_rule` on every currency read, since
      # core's schema never grows that column itself.
      Enum.each(PhoenixKitBilling.Migrations.up_statements(), &TestRepo.query!/1)

      # ...and, when the test-only catalogue bridge is resolved (see
      # mix.exs's `catalogue_test_deps/0`), the entities and catalogue
      # chains — in that order, the same way catalogue's own test helper
      # runs them. Core's baseline creates the `phoenix_kit_cat_*` tables
      # in their V1 shape only; catalogue's V2 adds the per-language `slug`
      # column its `Item`/`Category` schemas insert, so a database built
      # without this chain fails every `:catalogue` test with
      # `undefined_column: slug` from inside `create_item/2`.
      if Code.ensure_loaded?(PhoenixKitCatalogue.Migrations) do
        Enum.each(PhoenixKitEntities.Migrations.up_statements("public"), &TestRepo.query!/1)
        Enum.each(PhoenixKitCatalogue.Migrations.up_statements("public"), &TestRepo.query!/1)
      end

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.          The reason is printed above.
          Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.          The reason is printed above.
          Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_ecommerce, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the context layer.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

# `PhoenixKitCatalogue.Catalogue.PubSub.broadcast/3` (fired on every
# catalogue mutation) needs a `Phoenix.PubSub` server registered as
# `PhoenixKit.PubSub` — the host app provides this in production, and
# `phoenix_kit_catalogue`'s own test suite starts it the same way. Only
# relevant when `phoenix_kit_catalogue` is actually resolved (the test-only
# path bridge in mix.exs's `catalogue_test_deps/0`, or transitively through
# the optional `phoenix_kit_warehouse`), so a run without it starts no extra
# process.
if Code.ensure_loaded?(PhoenixKitCatalogue) do
  case Phoenix.PubSub.Supervisor.start_link(name: PhoenixKit.PubSub) do
    {:ok, _} -> :ok
    {:error, {:already_started, _}} -> :ok
  end
end

# The permission layer resolves a sub-permission through the module
# registry: `Scope.can?/2` requires `feature_enabled?/1`, which asks the
# registry which module owns a key. Without the registry running, EVERY
# `can?/2` answers false and the authorization tests would pass for the
# wrong reason (denied because the registry is missing, not because the
# capability is). Starting it here mirrors production, where the host app
# boots it.
{:ok, _pid} = PhoenixKit.ModuleRegistry.start_link([])
:ok = PhoenixKit.ModuleRegistry.register(PhoenixKitEcommerce)

# Flows that register users go through the Hammer-backed rate limiter.
# Without this its ETS table is absent and registration crashes. Mirrors
# core's `phoenix_kit/test/test_helper.exs`.
{:ok, _pid} = PhoenixKit.Users.RateLimiter.Backend.start_link([])

# Force PhoenixKit's URL prefix cache to "/" for tests so `Routes.path/1`
# etc. produce paths the test router can match. Admin paths always get
# the default locale ("en") prefix, so our router scope is `/en/admin/shop`.
:persistent_term.put({PhoenixKit.Config, :url_prefix}, "/")

# Start the test Endpoint so Phoenix.LiveViewTest can drive our LiveViews
# via `live/2` with real URLs. Runs with `server: false`, so no port is
# opened. Only starts when the test DB is available — without DB,
# LiveView tests are excluded anyway.
if repo_available do
  {:ok, _} = PhoenixKitEcommerce.Test.Endpoint.start_link()
end

# `TranslationSweepWorker`'s self-rescheduling chain (design §4.3) needs a
# real, registered `Oban` instance to call `Oban.insert/1` /
# `Oban.cancel_job/1` against. `testing: :manual` (config/test.exs) means
# nothing it starts ever runs a job on its own — no queue, no plugins, no
# stager — every DB write it does still lands through the caller's own
# sandboxed connection, exactly like any other `Repo` call from within a
# test. Only started when the test DB is up; without it there's no
# `oban_jobs` table to point at.
if repo_available do
  {:ok, _} = Oban.start_link(Application.fetch_env!(:phoenix_kit_ecommerce, Oban))
end

# i18n tests require phoenix_kit with the `gettext_backend` API
# (see BeamLabEU/phoenix_kit#522). When building against an older
# published phoenix_kit lacking `PhoenixKit.Dashboard.Tab.localized_label/1`,
# exclude those tests — they run automatically once the dep resolves to a
# release that includes the API.
i18n_exclude =
  if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
       function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
    []
  else
    Logger.info(
      "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
        "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
        "upgraded to a release that ships the gettext_backend API."
    )

    [:requires_phoenix_kit_i18n_api]
  end

integration_exclude = if repo_available, do: [], else: [:integration]

# Cyrillic slug generation needs `PhoenixKit.Utils.Slug`'s `:transliterate`
# option. An older published phoenix_kit ignores the option and returns the
# ASCII-only result, which is exactly the behavior these tests assert is gone
# - so they run once the dep resolves to a release that ships it.
transliteration_exclude =
  if PhoenixKit.Utils.Slug.slugify("Кашпо", transliterate: true) == "" do
    Logger.info(
      "[test_helper] PhoenixKit.Utils.Slug transliteration not available - " <>
        "Cyrillic slug tests excluded. They will run automatically once " <>
        "`phoenix_kit` is upgraded to a release that ships it."
    )

    [:requires_core_transliteration]
  else
    []
  end

# A switched-off multi-language site is single-language only on a core that
# ships the URL language policy: its primary language is the stored default
# language (`Languages.set_primary_language/1` arrived with it). An older core
# answers "en" there, so the tests asserting the stored primary language wait
# for the release that has it. The storefront's own links do not depend on it
# (`Shop.url_locale/1`), and their tests run everywhere.
single_language_exclude =
  if Code.ensure_loaded?(PhoenixKit.Modules.Languages) and
       function_exported?(PhoenixKit.Modules.Languages, :set_primary_language, 1) do
    []
  else
    Logger.info(
      "[test_helper] Languages.set_primary_language/1 not available - " <>
        "single-language primary-language tests excluded. They will run " <>
        "automatically once `phoenix_kit` is upgraded to a release that ships it."
    )

    [:requires_core_single_language]
  end

# `phoenix_kit_catalogue` is an OPTIONAL dependency (see mix.exs's comment
# by the `pk_dep(:phoenix_kit_ai, ...)` line for the sibling case) — the
# `ProductSource.Catalogue` adapter's own tests need it loaded (a real
# `PhoenixKitCatalogue.Schemas.Item`/`Category` struct for the pure view
# tests, a live catalogue DB for the query tests) and are tagged
# `:catalogue` so they run automatically once the package is loaded, whether
# a host declares the dep, the path bridge is set, or the optional
# `phoenix_kit_warehouse` dependency brings it in transitively.
catalogue_exclude =
  if Code.ensure_loaded?(PhoenixKitCatalogue) do
    []
  else
    Logger.info(
      "[test_helper] phoenix_kit_catalogue not loaded — ProductSource.Catalogue " <>
        "tests excluded. They will run automatically once a host declares the " <>
        "optional dependency."
    )

    [:catalogue]
  end

# The admin API's tests need three things this repo does not declare as
# dependencies, so each family runs only against a build that has what it
# needs. Run the suite once per build and read the excluded count.
#
#   :catalogue_api     a catalogue with the API (resolve_refs/2, update_items/2)
#   :old_catalogue     a catalogue WITHOUT it
#   :no_catalogue      no phoenix_kit_catalogue at all
#   :core_api          a core with the tool registry (PhoenixKit.API.Tool)
#   :core_confirm      ... and the confirmation gate (Keys.active?/1 and Flow.gate/1)
#   :core_no_confirm   ... and not the confirmation flow
#   :warehouse         phoenix_kit_warehouse with SourceKinds
catalogue_loaded? = Code.ensure_loaded?(PhoenixKitCatalogue)
catalogue_api? = PhoenixKitEcommerce.API.Gate.catalogue_api_ready?()
core_api? = Code.ensure_loaded?(PhoenixKit.API.Tool)
core_confirm? = PhoenixKitEcommerce.API.confirmation_available?()

admin_api_exclude =
  [
    if(catalogue_api?, do: nil, else: :catalogue_api),
    if(catalogue_loaded? and not catalogue_api?, do: nil, else: :old_catalogue),
    if(catalogue_loaded?, do: :no_catalogue, else: nil),
    if(core_api?, do: nil, else: :core_api),
    if(core_confirm?, do: :core_no_confirm, else: :core_confirm),
    if(Code.ensure_loaded?(PhoenixKitWarehouse.SourceKinds), do: nil, else: :warehouse)
  ]
  |> Enum.reject(&is_nil/1)

IO.puts("[test_helper] admin API test families excluded: #{inspect(admin_api_exclude)}")

# The avatar-dropdown flag (`Tab` option `:user_menu`, read by
# `Tab.user_menu?/2`). An older core ignores the option, so the tests about
# it run once the dep resolves to a release that ships it.
user_menu_exclude =
  if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
       function_exported?(PhoenixKit.Dashboard.Tab, :user_menu?, 2) do
    []
  else
    Logger.info(
      "[test_helper] PhoenixKit.Dashboard.Tab.user_menu?/2 not available - avatar-dropdown " <>
        "tab tests excluded. They will run automatically once `phoenix_kit` is " <>
        "upgraded to a release that ships it."
    )

    [:requires_core_user_menu]
  end

# Billing's avatar-dropdown gate (`PhoenixKitBilling.user_menu_with_shop?/1`).
# Billing releases up to 0.21.0 do not define it, so the test that drives it
# runs once the dep resolves to a release that does.
billing_user_menu_exclude =
  if Code.ensure_loaded?(PhoenixKitBilling) and
       function_exported?(PhoenixKitBilling, :user_menu_with_shop?, 1) do
    []
  else
    Logger.info(
      "[test_helper] PhoenixKitBilling.user_menu_with_shop?/1 not available - billing " <>
        "avatar-dropdown gate test excluded. It will run automatically once " <>
        "`phoenix_kit_billing` is upgraded to a release that ships it."
    )

    [:requires_billing_user_menu]
  end

# The order tools read the revision and the external system's mark of an order,
# which billing keeps from the release that has `put_order_sync/2`. Tests of
# them are tagged :billing_order_sync and excluded on an older billing.
billing_order_sync_exclude =
  if Code.ensure_loaded?(PhoenixKitBilling) and
       function_exported?(PhoenixKitBilling, :put_order_sync, 2) do
    []
  else
    Logger.info(
      "[test_helper] PhoenixKitBilling.put_order_sync/2 not available - the order tool " <>
        "tests (:billing_order_sync) excluded. They run once `phoenix_kit_billing` is " <>
        "upgraded to a release that ships it."
    )

    [:billing_order_sync]
  end

# The shop API registers tools and cron entries through callbacks that exist only in
# a core with the shop API (`PhoenixKit.API.*`, `PhoenixKit.ObanCrons`). Tests of
# those are tagged :requires_core_api and are EXCLUDED AT RUN TIME on a core
# without the API. The tag does not stop a test file from being COMPILED, so
# those files must not use `%PhoenixKit.API.Actor{}` / `%PhoenixKit.API.Tool{}`
# struct literals (a CompileError aborts the whole `mix test` run on a released
# core); they build structs with `struct/2` and match on maps.
api_exclude =
  if Code.ensure_loaded?(PhoenixKit.API.Tool) and Code.ensure_loaded?(PhoenixKit.ObanCrons) do
    []
  else
    Logger.info(
      "[test_helper] PhoenixKit.API.Tool / PhoenixKit.ObanCrons not available - " <>
        "public API tests excluded. They run once `phoenix_kit` resolves to a core " <>
        "with the shop API."
    )

    [:requires_core_api]
  end

# The API links a page of a language that has a domain on that domain through
# core's `Routes.canonical_absolute_or_nil/2`. A core without it keeps the
# request's host; the tests of each side run on their own core.
canonical_urls? =
  Code.ensure_loaded?(PhoenixKit.Utils.Routes) and
    function_exported?(PhoenixKit.Utils.Routes, :canonical_absolute_or_nil, 2)

canonical_urls_exclude =
  if canonical_urls? do
    [:core_without_canonical_urls]
  else
    Logger.info(
      "[test_helper] PhoenixKit.Utils.Routes.canonical_absolute_or_nil/2 not available - " <>
        "language-domain API link tests excluded. They run once `phoenix_kit` resolves to a " <>
        "core with it."
    )

    [:requires_core_canonical_urls]
  end

# The typo fallback needs the pg_trgm extension. Without it those tests are
# excluded (and counted in the summary), never silently passed.
trigram_exclude =
  if repo_available do
    try do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(TestRepo, fn ->
        TestRepo.query("SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_trgm')", [])
      end)
      |> case do
        {:ok, %{rows: [[true]]}} -> []
        _other -> [:requires_pg_trgm]
      end
    rescue
      _error -> [:requires_pg_trgm]
    end
  else
    []
  end

# The claim-path exclusion test (`:analytics`) needs the optional analytics module.
analytics_exclude =
  if Code.ensure_loaded?(PhoenixKitWebAnalytics.Config) do
    []
  else
    Logger.info(
      "[test_helper] phoenix_kit_web_analytics not loaded - the claim-path exclusion " <>
        "test (:analytics) excluded."
    )

    [:analytics]
  end

# The MCP tests (tagged `:mcp`) need the MCP plug of the shop API as well.
mcp_exclude =
  if Code.ensure_loaded?(PhoenixKit.API.MCP) do
    []
  else
    Logger.info("[test_helper] PhoenixKit.API.MCP not loaded - the MCP tests (:mcp) excluded.")
    [:mcp]
  end

ExUnit.start(
  exclude:
    i18n_exclude ++
      integration_exclude ++
      transliteration_exclude ++
      single_language_exclude ++
      catalogue_exclude ++
      admin_api_exclude ++
      user_menu_exclude ++
      billing_user_menu_exclude ++
      billing_order_sync_exclude ++
      api_exclude ++
      canonical_urls_exclude ++ trigram_exclude ++ analytics_exclude ++ mcp_exclude
)
