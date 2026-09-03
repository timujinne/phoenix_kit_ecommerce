import Config

# Integration tests run against a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_ecommerce_test
config :phoenix_kit_ecommerce, ecto_repos: [PhoenixKitEcommerce.Test.Repo]

# `PGDATABASE` lets this suite point at a database the test role isn't
# allowed to CREATE (e.g. a shared instance) instead of the name Hex CI
# provisions for itself. Same mechanism as core phoenix_kit's
# config/test.exs — see there for the full rationale. Left unset (CI's
# case), this falls back to the previous hardcoded name, so publishing
# and CI are unaffected.
pg_test_db =
  case System.get_env("PGDATABASE") do
    value when is_binary(value) and value != "" -> String.trim(value)
    _ -> "phoenix_kit_ecommerce_test#{System.get_env("MIX_TEST_PARTITION")}"
  end

# `PGPOOL` bounds the connection pool the same way core does — the default
# (`schedulers_online() * 2`) opens dozens of connections on a many-core
# box, which is fine against a private local Postgres but not against a
# shared instance already near its connection ceiling.
pg_test_pool =
  case System.get_env("PGPOOL") do
    value when is_binary(value) and value != "" ->
      case Integer.parse(String.trim(value)) do
        {size, ""} when size > 0 -> size
        _ -> raise "PGPOOL must be a positive integer, got: #{inspect(value)}"
      end

    _ ->
      System.schedulers_online() * 2
  end

config :phoenix_kit_ecommerce, PhoenixKitEcommerce.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: pg_test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: pg_test_pool

# Wire repo for PhoenixKit.RepoHelper — without this, context-layer DB calls crash.
config :phoenix_kit, repo: PhoenixKitEcommerce.Test.Repo

# `testing: :manual` (design §7's "Oban в тестах приложения — testing:
# :manual, задания не выполняются сами"): `Oban.insert/1` and
# `Oban.cancel_job/1` still hit the real `oban_jobs` table (needed by
# `TranslationSweepWorker`'s integration tests — design §4.3), but no
# queue/plugin/stager ever runs a job on its own; tests call `perform/1`
# directly. Not started here — only when the sandboxed test repo is up
# (see `test/test_helper.exs`), same guard every other DB-dependent
# piece of this test setup uses.
config :phoenix_kit_ecommerce, Oban,
  repo: PhoenixKitEcommerce.Test.Repo,
  testing: :manual

# Swoosh test adapter so flows that send mail (e.g. the guest-checkout
# confirmation email in `convert_cart_to_order/2`) don't crash with a
# missing-adapter error. Mail is captured in-process, never delivered.
config :phoenix_kit, PhoenixKit.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

# Test Endpoint for LiveView tests. `phoenix_kit_ecommerce` has no endpoint
# of its own in production — the host app provides one — so this
# endpoint only exists for `Phoenix.LiveViewTest`.
config :phoenix_kit_ecommerce, PhoenixKitEcommerce.Test.Endpoint,
  secret_key_base: String.duplicate("t", 64),
  live_view: [signing_salt: "ecommerce-test-salt"],
  server: false,
  url: [host: "localhost"],
  render_errors: [formats: [html: PhoenixKitEcommerce.Test.Layouts]]

config :phoenix, :json_library, Jason

config :logger, level: :warning
