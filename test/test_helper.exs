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
  "data_case.ex",
  "live_case.ex"
]
|> Enum.each(&Code.require_file(&1, support_dir))

alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

db_name =
  Application.get_env(:phoenix_kit_ecommerce, TestRepo, [])[:database] ||
    "phoenix_kit_ecommerce_test"

db_check =
  try do
    case System.cmd("psql", ["-lqt"], stderr_to_stdout: true) do
      {output, 0} ->
        exists =
          output
          |> String.split("\n")
          |> Enum.any?(fn line ->
            line |> String.split("|") |> List.first("") |> String.trim() == db_name
          end)

        if exists, do: :exists, else: :not_found

      _ ->
        :try_connect
    end
  rescue
    # `psql` not on PATH (CI / minimal env). Fall through to the
    # connection attempt — if the repo can't start, integration tests
    # are excluded; otherwise the existing rescue prints a hint.
    ErlangError -> :try_connect
  end

repo_available =
  if db_check == :not_found do
    IO.puts("""

      Test database "#{db_name}" not found — integration tests excluded.
      Run: createdb #{db_name}
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

      Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
      true
    rescue
      e ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name}
          Error: #{Exception.message(e)}
        """)

        false
    catch
      :exit, reason ->
        IO.puts("""

          Could not connect to test database — integration tests excluded.
          Run: createdb #{db_name}
          Error: #{inspect(reason)}
        """)

        false
    end
  end

Application.put_env(:phoenix_kit_ecommerce, :test_repo_available, repo_available)

# Minimal PhoenixKit services needed by the context layer.
{:ok, _pid} = PhoenixKit.PubSub.Manager.start_link([])

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

# `phoenix_kit_catalogue` is an OPTIONAL dependency (see mix.exs's comment
# by the `pk_dep(:phoenix_kit_ai, ...)` line for the sibling case) — the
# `ProductSource.Catalogue` adapter's own tests need it loaded (a real
# `PhoenixKitCatalogue.Schemas.Item`/`Category` struct for the pure view
# tests, a live catalogue DB for the query tests) and are tagged
# `:catalogue` so they run automatically once a host declares the dep.
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

ExUnit.start(
  exclude: i18n_exclude ++ integration_exclude ++ transliteration_exclude ++ catalogue_exclude
)
