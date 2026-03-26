defmodule PhoenixKitEcommerce.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/BeamLabEU/phoenix_kit_ecommerce"

  def project do
    [
      app: :phoenix_kit_ecommerce,
      name: "PhoenixKitEcommerce",
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs(),
      dialyzer: [plt_add_apps: [:phoenix_kit, :phoenix_kit_billing]],
      description: "E-commerce module for PhoenixKit — products, categories, cart, checkout"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:phoenix_kit, "~> 1.7", path: "/app", override: true},
      {:phoenix_kit_billing, "~> 0.1",
       path: "/root/projects/phoenix_kit_billing", override: true},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix, "~> 1.7"},
      {:ecto_sql, "~> 3.12"},
      {:oban, "~> 2.20"},
      {:uuidv7, "~> 1.0"},
      {:nimble_csv, "~> 1.2"},
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE)
    ]
  end

  defp docs do
    [
      main: "PhoenixKit.Modules.Shop",
      source_ref: "v#{@version}",
      source_url: @source_url
    ]
  end
end
