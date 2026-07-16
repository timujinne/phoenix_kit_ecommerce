defmodule PhoenixKitEcommerce.MixProject do
  use Mix.Project

  @version "0.1.11"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_ecommerce"

  def project do
    [
      app: :phoenix_kit_ecommerce,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      # `compat/shop.ex` intentionally redefines the core
      # `PhoenixKit.Modules.Shop` namespace during the transition to the
      # `PhoenixKitEcommerce` namespace, which triggers a module-redefinition
      # warning that `--warnings-as-errors` would otherwise fail on.
      # Removal condition: drop this once core no longer ships the old
      # `PhoenixKit.Modules.Shop` namespace (then delete compat/shop.ex too).
      elixirc_options: [ignore_module_conflict: true],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      test_ignore_filters: [~r"/support/"],
      test_coverage: [
        ignore_modules: [
          ~r/^PhoenixKitEcommerce\.Test\./,
          PhoenixKitEcommerce.DataCase,
          PhoenixKitEcommerce.LiveCase,
          PhoenixKitEcommerce.ActivityLogAssertions
        ]
      ],

      # Hex
      description: "E-commerce module for PhoenixKit — products, categories, cart, checkout",
      package: package(),

      # Dialyzer
      dialyzer: [plt_add_apps: [:phoenix_kit, :phoenix_kit_billing, :mix]],

      # Docs
      name: "PhoenixKitEcommerce",
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger, :gettext]]
  end

  def cli do
    [preferred_envs: ["test.setup": :test, "test.reset": :test]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: [
        "compile --force --warnings-as-errors",
        "deps.unlock --check-unused",
        # Scan for retired Hex deps. Run via `cmd` so Hex bootstraps in a fresh
        # process — the hex.* archive tasks aren't resolvable via Mix.Task.run
        # inside an alias.
        "cmd mix hex.audit",
        "quality.ci"
      ],
      "test.setup": [
        "ecto.create --quiet -r PhoenixKitEcommerce.Test.Repo"
      ],
      "test.reset": [
        "ecto.drop --quiet -r PhoenixKitEcommerce.Test.Repo",
        "test.setup"
      ]
    ]
  end

  # phoenix_kit deps resolve from Hex by default. For cross-repo work against a
  # local checkout, export <APP>_PATH — e.g. PHOENIX_KIT_PATH=../phoenix_kit or
  # PHOENIX_KIT_AI_PATH=../phoenix_kit_ai. Unset => the published pin, so
  # mix hex.publish is unaffected.
  defp pk_dep(app, requirement, opts \\ []) do
    env_var = String.upcase(Atom.to_string(app)) <> "_PATH"

    # A set-but-blank value (`PHOENIX_KIT_PATH=`) reads as "" rather than nil;
    # treat it as unset so it falls back to the Hex pin instead of building a
    # broken `path: ""` dep.
    case System.get_env(env_var) do
      path when is_binary(path) and path != "" ->
        {app, [path: path, override: true] ++ opts}

      _unset when opts == [] ->
        {app, requirement}

      _unset ->
        {app, requirement, opts}
    end
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      pk_dep(:phoenix_kit, "~> 1.7.189"),

      # Gettext for per-module i18n of sidebar tab labels.
      {:gettext, "~> 1.0"},

      # Billing integration for checkout and order conversion.
      pk_dep(:phoenix_kit_billing, "~> 0.1"),

      # LiveView is needed for the admin and storefront pages.
      {:phoenix_live_view, "~> 1.1"},

      # Phoenix web framework (controllers, routing).
      {:phoenix, "~> 1.7"},

      # Ecto for database queries and schemas.
      {:ecto_sql, "~> 3.12"},

      # Background job processing (CSV imports, image migration).
      {:oban, "~> 2.20"},

      # UUIDv7 primary key generation.
      {:uuidv7, "~> 1.0"},

      # CSV parsing for product imports.
      {:nimble_csv, "~> 1.2"},

      # HTTP client for downloading product images.
      {:req, "~> 0.5"},

      # JSON encoding/decoding.
      {:jason, "~> 1.4"},

      # Documentation generation.
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},

      # Code quality.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},

      # `Phoenix.LiveViewTest` parses HTML via `lazy_html` for `element/2`,
      # `render(view) =~ "..."`, etc. Test-only.
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKitEcommerce",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
