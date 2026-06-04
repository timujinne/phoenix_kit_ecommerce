import Config

# Integration tests run against a real PostgreSQL database. Create it with:
#   createdb phoenix_kit_ecommerce_test
config :phoenix_kit_ecommerce, ecto_repos: [PhoenixKitEcommerce.Test.Repo]

config :phoenix_kit_ecommerce, PhoenixKitEcommerce.Test.Repo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  database: "phoenix_kit_ecommerce_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Wire repo for PhoenixKit.RepoHelper — without this, context-layer DB calls crash.
config :phoenix_kit, repo: PhoenixKitEcommerce.Test.Repo

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
