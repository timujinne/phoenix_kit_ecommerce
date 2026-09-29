defmodule PhoenixKitEcommerce.CorePinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit` requirement against being re-narrowed to a single
  core MINOR, and against a local path override reaching a commit.

  The trap is the three-segment form: `~> 2.6.x` expands to
  `>= 2.6.x and < 2.7.0`, so no 2.7 or later core satisfies it. The breakage
  lands on CONSUMERS, never here — a host depending on both this module and a
  newer core minor gets an unsolvable dependency set and `mix deps.get` fails
  outright, with no degraded mode. Nothing else in this repo's own test run
  would notice, which is why the check is a test rather than a convention.

  What this does NOT forbid is raising the FLOOR. The floor tracks the
  oldest core that has every API this module calls. It is `>= 2.38.0 and
  < 3.0.0` now: the actor and the activity log come from `PhoenixKitWeb.Actor`
  and `Activity.log/3`, first shipped in core 2.38.0, and the module does not
  compile without them. That subsumes the earlier floors — `Slug.put_slug/3`
  (2.4.0), V171's shop slug projection pkeys (2.6.0) and V186's
  `base_currency`/`exchange_rate`/`base_unit_price` cart columns (2.16.0;
  below it every cart write raised `undefined_column`). Raise this alongside
  `mix.exs` whenever a newly-adopted core API sets a higher floor, keeping
  the compound form: patch-precise at the bottom, open through every later
  2.x minor at the top.

  Core 1.7 is deliberately excluded: core 2.0.0 squashed the migration chain to
  a V135 floor and this module is verified only against that baseline.
  """

  # Floor: core 2.38.0. Everything above it, forever, must stay admitted.
  # 2.37.5 is the last release without the toolkits; the older rejects
  # are the earlier floors' own boundaries, kept so a regression to any of
  # them is named.
  @must_admit ["2.38.0", "2.38.1", "2.39.0", "2.99.4"]
  @must_reject [
    "1.7.236",
    "2.0.0",
    "2.6.0",
    "2.15.1",
    "2.16.0",
    "2.22.15",
    "2.37.5",
    "3.0.0"
  ]

  test "the :phoenix_kit requirement admits every core >= 2.38.0 minor and nothing else" do
    requirement = core_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} rejects core #{version}. " <>
               "A pin that excludes a core minor at or above the floor breaks `mix deps.get` " <>
               "for every host running this module alongside that core. Keep it two-segment."
    end

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit` requirement #{inspect(requirement)} admits core #{version}, " <>
               "which is outside the range this module is verified against."
    end
  end

  # Resolution order matters. `Mix.Project.config()` is exact, but it reports the
  # dep as it resolved THIS run — and `pk_dep/3` rewrites it to a `path:` tuple
  # whenever PHOENIX_KIT_PATH is exported, which is the workspace's sanctioned way
  # to run this suite against unreleased core. Reading the committed literal from
  # mix.exs as a fallback keeps the check meaningful under that override instead
  # of failing the documented workflow — and it still fails when a path dep is
  # COMMITTED, because then there is no literal left to find.
  defp core_requirement do
    resolved_requirement() || committed_requirement() ||
      flunk("""
      No version requirement found for `:phoenix_kit`.

      Neither the resolved dep nor mix.exs carries one, which means a `path:`
      dep has been committed. That ships a broken package and breaks every
      other consumer's build — restore the published requirement.
      """)
  end

  defp resolved_requirement do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.find_value(fn
      {:phoenix_kit, requirement} when is_binary(requirement) -> requirement
      {:phoenix_kit, requirement, _opts} when is_binary(requirement) -> requirement
      _ -> nil
    end)
  end

  # First match wins, matching how every other tool in the workspace reads this
  # pin. Covers both the bare `{:phoenix_kit, "..."}` and the `pk_dep(:phoenix_kit,
  # "...")` forms, since the captured text is identical in each.
  defp committed_requirement do
    case Regex.run(~r/:phoenix_kit,\s*"([^"]+)"/, File.read!("mix.exs")) do
      [_full, requirement] -> requirement
      _ -> nil
    end
  end
end
