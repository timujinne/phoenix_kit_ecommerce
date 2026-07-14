# Code Review: PR #8 — Add storefront product search (name, SKU, tags)

**Reviewed:** 2026-07-11
**Reviewer:** Claude (claude-sonnet-5)
**PR:** https://github.com/BeamLabEU/phoenix_kit_ecommerce/pull/8
**Author:** Tymofii Shapovalov (timujinne)
**Head SHA:** f0fb185a42ff398eee7546adb7ee4acca42e063b
**Merge SHA:** da6846a7b55765ebb1815cf40447f5ddf59477e4
**Status:** Merged

## Summary

Adds a built-in `search` storefront filter type: a sidebar search box on the
main catalog and category pages (`?search=` URL param), extends
`list_products/1 :search` to also match `metadata->>'sku'` and `tags` (not
just localized title/description), and fixes a real pre-existing bug where
the `:search` SQL fragment's unqualified `title`/`description` columns went
ambiguous once `:exclude_hidden_categories` joins the categories table.
Rollout for existing installs goes through a new
`merge_missing_builtin_filters/1` that adds the new filter to a saved
config as disabled, so admins opt in explicitly.

## Issues Found

### 1. [BUG - MEDIUM] `merge_missing_builtin_filters/1` position collides with existing filters — FIXED
**File:** `lib/phoenix_kit_ecommerce.ex` (`merge_missing_builtin_filters/1`)
**Confidence:** 95/100

The original implementation appended missing built-ins to the *end* of the
saved filter list, keeping their `default_storefront_filters/0` position
value as-is:

```elixir
missing =
  default_storefront_filters()
  |> Enum.reject(&MapSet.member?(existing_keys, &1["key"]))
  |> Enum.map(&Map.put(&1, "enabled", false))

filters ++ missing
```

For a **pre-existing install**, the saved config already has `"price"` at
`"position" => 0` (the pre-PR numbering). The merged-in `"search"` filter
also gets `"position" => 0` (its position in the *new* numbering). Once the
admin enables it, `get_enabled_storefront_filters/0` sorts by `"position"`
with `Enum.sort_by/2`, which is a **stable** sort — so the tie falls back to
list order, and since `search` was appended last, it renders *after*
`price`, not first as the PR's own description promises ("Sidebar search
box … rendered as the first filter section").

Verified directly:
```elixir
Enum.sort_by(
  [%{"key" => "price", "position" => 0}, %{"key" => "search", "position" => 0}],
  & &1["position"]
)
# => [price, search]  — search loses the tie
```

This only affects upgraded installs (fresh installs get the correct order
from `default_storefront_filters/0` directly, no ties). It's a UX/ordering
bug, not data loss — search still works, it just doesn't lead the sidebar.
Untested by the PR's own `settings_filters_test.exs`, which only asserts
the filter becomes `enabled`, not where it sorts.

**Fix applied:** `merge_missing_builtin_filters/1` now positions missing
filters *below* the minimum position of the saved filters (preserving their
relative order from `default_storefront_filters/0` among themselves),
guaranteeing no tie:

```elixir
min_position = filters |> Enum.map(&(&1["position"] || 0)) |> Enum.min(fn -> 0 end)
missing = ... |> Enum.with_index() |> Enum.map(fn {filter, index} ->
  Map.put(filter, "position", min_position - missing_count + index)
end)
missing ++ filters
```
Also guards against a saved filter with no `"position"` key at all (treated
as `0`) — the existing `context_test.exs` fixture uses exactly that shape,
which would otherwise crash on `nil - 1`.

**Tests added/updated:**
- `test/phoenix_kit_ecommerce/integration/context_test.exs` — updated the
  "appends absent built-ins" test (its `List.first(merged) == List.first(saved)`
  assertion encoded the old append-at-end behavior) and added a new
  regression test asserting the merged-in filter sorts first once enabled.
- `test/phoenix_kit_ecommerce/web/settings_filters_test.exs` — added an
  end-to-end LiveView test that enables the merged-in search filter and
  asserts `get_enabled_storefront_filters/0` returns it first.

### 2. [OBSERVATION] Admin filters table doesn't reflect `"position"` order
**File:** `lib/phoenix_kit_ecommerce/web/settings.ex:364`
**Confidence:** 70/100

The Settings page filters table renders `@storefront_filters` in raw list
order (`<%= for filter <- @storefront_filters do %>`), not sorted by
`"position"`. This predates the PR (e.g. `add_metadata_filter` already
appends new filters to the end of the raw list) and isn't something #8
introduced — after the fix above, `search` now happens to render first in
this table too (since it's prepended), but that's incidental. Not fixing:
out of scope for this PR, and the table's raw order was already
inconsistent with the storefront's position-sorted order before this
change.

## What Was Done Well

- **The `ambiguous_column` fix is correct and well-tested.** Verified the
  SQL fragment's 14 `?` placeholders match the 14 bound args 1:1, and all
  columns (`title`, `description`, `metadata`, `tags`) are now bound
  through the `p` product binding rather than referenced bare. The
  regression test (`list_products/1 :search composes with
  :exclude_hidden_categories`) pins the exact combination that used to
  raise.
- **`tags` fragment matches the actual column type.** `tags` is declared
  `{:array, :string}` in the Ecto schema but is physically `JSONB` in
  Postgres (`priv` migration `v45.ex`); the fragment's
  `jsonb_array_elements_text(COALESCE(?, '[]'::jsonb))` treats `p.tags` as
  a raw column reference (not a cast Ecto value), which is correct for a
  JSONB column.
- **Rollout design (merge-as-disabled) is sound**, and the "leaves a
  complete config untouched" test guards the no-op case well.
- **Test coverage is thorough and well-layered**: pure filter-state unit
  tests, component render tests, LiveView end-to-end flow, settings-page
  merge behavior, and a targeted context-level regression test — matching
  the project's stated test tiers.
- Correctly used `PhoenixKit.Migration`-managed schema (no module-owned
  DDL) and didn't hardcode the `$` currency symbol or bypass `Decimal`.

## Validation

- `mix format --check-formatted` — clean
- `mix credo --strict` — clean, no issues
- `mix compile --warnings-as-errors` — clean
- `mix dialyzer` — clean (see note)
- `mix test` (unit tier; no local Postgres in this environment, so the
  163 `:integration`-tagged tests — including this PR's regression and
  LiveView tests — were excluded, matching the project's documented
  DB-unavailable behavior). All 50 runnable unit tests pass, including the
  12 new pure `search`-filter tests from this PR.
- `mix deps.unlock --check-unused` flags `:earmark` as unused — **pre-existing**,
  introduced by the unrelated `cc7a6c7 lib upgrades` commit on top of this
  PR, not by #8. Left untouched (out of scope).

## Verdict

**Approved with fixes.** The PR's core contribution — search filter type,
SKU/tag matching, and the ambiguous-column fix — is correct, well-tested,
and matches the codebase's conventions. Found and fixed one real ordering
bug in the upgrade-merge path that the PR's own tests didn't catch;
extended the relevant tests to lock in the fix.
