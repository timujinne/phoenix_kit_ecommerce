defmodule PhoenixKitEcommerce.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_ecommerce"

  def project do
    [
      app: :phoenix_kit_ecommerce,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),

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
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      quality: ["format", "credo --strict", "dialyzer"],
      "quality.ci": ["format --check-formatted", "credo --strict", "dialyzer"],
      precommit: ["compile", "quality"]
    ]
  end

  defp deps do
    [
      # PhoenixKit provides the Module behaviour and Settings API.
      {:phoenix_kit, "~> 1.7"},

      # Billing integration for checkout and order conversion.
      {:phoenix_kit_billing, "~> 0.1"},

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
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md CHANGELOG.md LICENSE)
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
