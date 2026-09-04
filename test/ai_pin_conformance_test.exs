defmodule PhoenixKitEcommerce.AIPinConformanceTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Guards the `:phoenix_kit_ai` requirement's FLOOR, the way
  `CorePinConformanceTest` guards `:phoenix_kit`'s shape.

  The floor is the whole safety mechanism behind this module's translation
  feature, and it is the one thing in the package that no other test can
  notice. Both translation prompts this module rolls out (`AITranslatable`,
  `CategoryAITranslatable`) carry their entire source section as the
  `{{SourceFields}}` variable (design §9.1), and the fingerprint model of
  design §4.1 only works because the worker forwards `opts[:source_fields]`
  into `put_translation/4` (design §9.3). Both land in phoenix_kit_ai
  0.20.0; every engine published before it has neither.

  A host that resolves an older engine does not fail loudly. It renders
  every translation prompt with a literal, unbound `{{SourceFields}}` — the
  call costs money, comes back unparseable, and only a log line says why —
  and every write that does land arrives with no source to hash, so
  `TranslationFingerprint.apply_writes/3` erases the reference instead of
  stamping one and each pair falls back to `:unknown`. This suite would
  notice none of that: it runs against a path-pinned fork of the engine
  (PHOENIX_KIT_AI_PATH), so the committed requirement is never exercised
  here at all. Hence a test that reads the requirement itself.

  Two failure modes are covered:

    * the floor being lowered (or left) below 0.20.0, which admits a
      published engine lacking §9.1/§9.3 — the versions in `@must_reject`
      are the real hex releases, newest first, that predate it;
    * the fork's `path:` pin reaching a commit, which ships a package no
      host can resolve.

  Raising the floor further is fine and expected — add the new floor's
  predecessors to `@must_reject` when that happens. Narrowing it to a
  single minor (`~> 0.20.0`, three-segment) is not: it would reject every
  later engine and break `mix deps.get` for hosts, which is exactly the
  trap `CorePinConformanceTest` documents.
  """

  # Every phoenix_kit_ai release published before 0.20.0 (hex, checked
  # 2026-09-04), plus 1.0.0: a major this module has never been verified
  # against must not be admitted silently either.
  @must_reject [
    "0.12.2",
    "0.13.0",
    "0.14.1",
    "0.15.1",
    "0.16.0",
    "0.17.1",
    "0.18.0",
    "0.18.2",
    "0.19.0",
    "0.19.1",
    "0.19.2",
    "1.0.0"
  ]

  # 0.20.0 is the floor; everything above it in the 0.x line stays admitted
  # forever — the two-segment invariant.
  @must_admit ["0.20.0", "0.20.1", "0.21.0", "0.29.9"]

  test "the :phoenix_kit_ai requirement admits only engines carrying design §9.1 and §9.3" do
    requirement = ai_requirement()

    assert match?({:ok, _parsed}, Version.parse_requirement(requirement)),
           "`:phoenix_kit_ai` requirement #{inspect(requirement)} is not a valid requirement"

    for version <- @must_reject do
      refute Version.match?(version, requirement),
             "`:phoenix_kit_ai` requirement #{inspect(requirement)} admits engine #{version}, " <>
               "which predates 0.20.0 and therefore binds neither `{{SourceFields}}` (§9.1) " <>
               "nor `opts[:source_fields]` (§9.3). A host resolving it gets prompts sent with " <>
               "an empty source section and translations that never fingerprint — both silent."
    end

    for version <- @must_admit do
      assert Version.match?(version, requirement),
             "`:phoenix_kit_ai` requirement #{inspect(requirement)} rejects engine #{version}. " <>
               "A pin that excludes an engine minor at or above the floor breaks `mix deps.get` " <>
               "for every host running this module alongside that engine. Keep it two-segment."
    end
  end

  # Same resolution order and rationale as `CorePinConformanceTest`:
  # `Mix.Project.config()` is exact but reports the dep as it resolved THIS
  # run, and `pk_dep/3` rewrites it to a `path:` tuple whenever
  # PHOENIX_KIT_AI_PATH is exported — the sanctioned way to run this suite
  # against an unreleased engine, and the way it must run until 0.20.0 is on
  # hex. Falling back to the committed literal keeps the check meaningful
  # under that override, and still fails when a `path:` dep is COMMITTED,
  # because then no literal is left to find.
  defp ai_requirement do
    resolved_requirement() || committed_requirement() ||
      flunk("""
      No version requirement found for `:phoenix_kit_ai`.

      Neither the resolved dep nor mix.exs carries one, which means a `path:`
      dep has been committed. That ships a package no host can resolve —
      restore the published requirement before releasing.
      """)
  end

  defp resolved_requirement do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> Enum.find_value(fn
      {:phoenix_kit_ai, requirement} when is_binary(requirement) -> requirement
      {:phoenix_kit_ai, requirement, _opts} when is_binary(requirement) -> requirement
      _ -> nil
    end)
  end

  defp committed_requirement do
    case Regex.run(~r/:phoenix_kit_ai,\s*"([^"]+)"/, File.read!("mix.exs")) do
      [_full, requirement] -> requirement
      _ -> nil
    end
  end
end
