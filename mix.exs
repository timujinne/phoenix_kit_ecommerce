defmodule PhoenixKitEcommerce.MixProject do
  use Mix.Project

  @version "0.4.3"
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
      # 2.6 is a hard floor, not a preference. ShippingMethod.changeset/2
      # calls `Slug.put_slug/3` (added in 2.4.0), and Product/Category name
      # V171's projection pkeys (`phoenix_kit_shop_{product,category}_slugs_pkey`,
      # added in 2.6.0). Under the previous `~> 2.0` a host resolving 2.0–2.5
      # either raised UndefinedFunctionError on every shipping-method save
      # or turned slug collisions back into raw Postgrex errors. Two-segment
      # so every later 2.x still resolves.
      pk_dep(:phoenix_kit, "~> 2.6"),

      # Gettext for per-module i18n of sidebar tab labels.
      {:gettext, "~> 1.0"},

      # Billing integration for checkout and order conversion.
      # 0.5.2 is the floor: that release adds `payment_option_uuid` to
      # `PhoenixKitBilling.Order`, the column `maybe_put_payment_option/2`
      # writes once core is migrated to V162. Below it the attr is dropped
      # by `cast/3` and the order/payment-option linkage silently vanishes.
      # `~> 0.1` also admitted 0.1.0, which predates the `PhoenixKitBilling`
      # namespace entirely (it was `PhoenixKit.Modules.Billing`), and
      # 0.1.1/0.1.2, which have no tax API — both fail to compile here.
      pk_dep(:phoenix_kit_billing, "~> 0.7"),
      # Optional: only the AI-translate UI/adapter use it, and both compile out
      # when it's absent (see ProductForm's @ai_translate? flag). Version tracks
      # the actual API used (Translatable behaviour, AITranslate components).
      pk_dep(:phoenix_kit_ai, "~> 0.18", optional: true),
      # No declared dependency on `phoenix_kit_catalogue`: the catalogue
      # "extension slot" integration (`PhoenixKitEcommerce.Catalogue.Extension`)
      # is fully duck-typed — nothing here calls into `PhoenixKitCatalogue`
      # directly. No released version yet ships the extension slot
      # (`PhoenixKitCatalogue.Extension`) this integration targets, so a
      # `~>` floor here could only be inaccurate; add one once a real
      # release ships it.

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
      # Tags in this repo are bare version numbers, not v-prefixed — a "v" ref
      # points at a tag that does not exist and 404s every HexDocs source link.
      source_ref: @version,
      source_url: @source_url
    ]
  end
end
