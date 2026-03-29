defmodule Mix.Tasks.PhoenixKitEcommerce.Install do
  @moduledoc """
  Installs PhoenixKit E-commerce module into parent application.

  Adds the required `@source` directive to your CSS file so Tailwind CSS
  can discover classes used by the e-commerce module's templates.

  ## Usage

      mix phoenix_kit_ecommerce.install

  ## What it does

  1. Finds your `assets/css/app.css` file
  2. Adds `@source "../../deps/phoenix_kit_ecommerce";` after existing `@source` lines
  3. Prints next steps for configuration

  This task is idempotent — safe to run multiple times.
  """

  use Mix.Task

  @shortdoc "Install PhoenixKit E-commerce module"

  @source_directive ~s(@source "../../deps/phoenix_kit_ecommerce";)
  @source_pattern ~r/@source\s+["'][^"']*phoenix_kit_ecommerce["']/

  @impl Mix.Task
  def run(_argv) do
    Mix.shell().info("Installing PhoenixKit E-commerce...")

    css_paths = [
      "assets/css/app.css",
      "priv/static/assets/app.css",
      "assets/app.css"
    ]

    case find_app_css(css_paths) do
      {:ok, css_path} ->
        add_css_source(css_path)

      {:error, :not_found} ->
        print_manual_instructions()
    end

    print_next_steps()
  end

  defp find_app_css(paths) do
    case Enum.find(paths, &File.exists?/1) do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  defp add_css_source(css_path) do
    content = File.read!(css_path)

    if String.match?(content, @source_pattern) do
      Mix.shell().info("  ✓ CSS source already configured in #{css_path}")
    else
      updated = insert_source_directive(content)
      File.write!(css_path, updated)
      Mix.shell().info("  ✓ Added @source directive to #{css_path}")
    end
  end

  defp insert_source_directive(content) do
    lines = String.split(content, "\n")

    # Find the last @source line to insert after it
    last_source_index =
      lines
      |> Enum.with_index()
      |> Enum.reverse()
      |> Enum.find(fn {line, _index} ->
        String.match?(line, ~r/^@source\s+/)
      end)

    case last_source_index do
      {_line, index} ->
        {before, after_lines} = Enum.split(lines, index + 1)
        Enum.join(before ++ [@source_directive] ++ after_lines, "\n")

      nil ->
        # No @source lines — insert after @import "tailwindcss"
        import_index =
          lines
          |> Enum.with_index()
          |> Enum.find(fn {line, _} -> String.match?(line, ~r/^@import\s+/) end)

        case import_index do
          {_line, index} ->
            {before, after_lines} = Enum.split(lines, index + 1)
            Enum.join(before ++ [@source_directive] ++ after_lines, "\n")

          nil ->
            @source_directive <> "\n" <> content
        end
    end
  end

  defp print_manual_instructions do
    Mix.shell().info("""

      ⚠  Could not find app.css. Please manually add this line:

         #{@source_directive}

      Common locations: assets/css/app.css
    """)
  end

  defp print_next_steps do
    Mix.shell().info("""

    PhoenixKit E-commerce installed successfully!

    Next steps:
    1. Run `mix deps.get` if you haven't already
    2. Add Oban queues to config/config.exs:
       queues: [shop_import: 5, shop_images: 5]
    3. Run `mix phoenix_kit.update` to apply shop migrations
    4. Enable the Shop module in Admin → Modules
    5. Configure shop settings in Admin → E-Commerce → Settings
    """)
  end
end
