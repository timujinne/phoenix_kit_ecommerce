require Logger

# Test helper for PhoenixKitEcommerce.
#
# Level 1: Unit tests (schemas, changesets, pure functions) always run.
# Level 2: Integration tests (tagged `:integration` via
#          PhoenixKitEcommerce.DataCase / LiveCase) require PostgreSQL —
#          by default a missing/broken database is a HARD FAILURE (see
#          the `allow_missing_db?` block below), not a silent exclusion.
#
# First-time setup:
#
#   createdb phoenix_kit_ecommerce_test
#
# After that, `mix test` boots the repo, runs core's versioned migrations
# via `PhoenixKit.Migration.ensure_current/2`, and lets the Ecto sandbox
# handle isolation. No module-owned DDL.

# --- MIX_ENV guard -------------------------------------------------------
#
# config/config.exs only loads config/test.exs (test DB credentials, the
# Ecto.Adapters.SQL.Sandbox pool, the test Endpoint, etc.) when
# `config_env() == :test`:
#
#   if config_env() == :test do
#     import_config "test.exs"
#   end
#
# `mix test` normally runs with `Mix.env() == :test` even when nothing
# sets MIX_ENV, because Mix applies each task's *preferred* environment —
# but only when MIX_ENV is unset. An explicit `MIX_ENV=dev` (or any other
# value) exported in the shell/container always overrides that
# preference, so `mix test` would silently run in `:dev`, config/test.exs
# would never load, and the repo would start on bare Ecto/Postgrex
# defaults (no Sandbox pool, no configured credentials/database). That
# makes every test look like a database problem when it is really a
# config problem — fail loudly here instead of leaving it to be
# rediscovered downstream (e.g. as `cannot invoke sandbox operation with
# pool DBConnection.ConnectionPool`).
if Mix.env() != :test do
  raise """
  mix test is running with MIX_ENV=#{Mix.env()}, not "test".

  config/config.exs only imports config/test.exs when config_env() == :test,
  so none of the test repo configuration (database, credentials, the
  Ecto.Adapters.SQL.Sandbox pool, the test Endpoint) was loaded and this
  suite cannot run correctly.

  This happens whenever MIX_ENV is exported in the environment: Mix only
  applies mix test's preferred environment (:test) when MIX_ENV is unset,
  and an explicit value always wins over that preference.

  Run instead:

      MIX_ENV=test mix test
  """
end

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

# --- Degraded "no database" mode (opt-in only) ---------------------------
#
# A broken or missing test database used to be swallowed here: the
# integration tests were quietly excluded and the run still reported
# "0 failures". That is exactly how a MIX_ENV misconfiguration (see the
# guard above) went unnoticed — a config bug that should have failed
# loudly instead looked like a healthy, if partial, green suite.
#
# By default this file now treats a broken/missing database as a hard
# failure: `mix test` raises instead of degrading. A contributor who
# genuinely has no PostgreSQL available and only wants the unit-level
# suite can opt in explicitly:
#
#   PK_ECOMMERCE_TEST_NO_DB=1 mix test
#
# which still prints exactly what happened and what got excluded, so the
# degraded run can never be mistaken for a full one.
allow_missing_db? = System.get_env("PK_ECOMMERCE_TEST_NO_DB") == "1"

no_db_hint = fn reason ->
  """

    Test database unavailable — integration tests excluded (PK_ECOMMERCE_TEST_NO_DB=1).
    Database: #{db_name}
    Reason: #{reason}
  """
end

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
    # connection attempt — the repo start-up below is the real check;
    # this is just an optional early, friendlier diagnostic.
    ErlangError -> :try_connect
  end

repo_available =
  cond do
    db_check == :not_found and allow_missing_db? ->
      IO.puts(no_db_hint.("database \"#{db_name}\" not found (checked via `psql -lqt`)"))
      false

    db_check == :not_found ->
      raise """
      Test database "#{db_name}" not found.

      Run:  createdb #{db_name}

      To run only the unit-level suite without a database, opt in explicitly:

          PK_ECOMMERCE_TEST_NO_DB=1 mix test
      """

    true ->
      try do
        {:ok, _} = TestRepo.start_link()

        # Build the schema directly from core's versioned migrations — same
        # call the host app makes in production. `ensure_current/2`
        # re-applies any newly-shipped Vxxx migrations on every boot.
        PhoenixKit.Migration.ensure_current(TestRepo, log: false)

        Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
        true
      rescue
        e ->
          if allow_missing_db? do
            IO.puts(no_db_hint.(Exception.message(e)))
            false
          else
            # Decorate and die — never swallow. A failure here (wrong
            # credentials, un-migratable schema, a genuine migration bug)
            # is a real defect, not an absent-database situation.
            reraise(
              Exception.message(e) <>
                "\n\nThe test database is required. Create it with: createdb #{db_name}\n" <>
                "To skip it deliberately, set PK_ECOMMERCE_TEST_NO_DB=1.",
              __STACKTRACE__
            )
          end
      catch
        :exit, reason ->
          if allow_missing_db? do
            IO.puts(no_db_hint.(inspect(reason)))
            false
          else
            raise """
            Could not connect to test database "#{db_name}".

            Error: #{inspect(reason)}

            Create it with: createdb #{db_name}
            To skip it deliberately, set PK_ECOMMERCE_TEST_NO_DB=1.
            """
          end
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

ExUnit.start(exclude: i18n_exclude ++ integration_exclude ++ transliteration_exclude)
