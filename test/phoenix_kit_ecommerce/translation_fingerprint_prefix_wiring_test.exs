defmodule PhoenixKitEcommerce.TranslationFingerprintPrefixWiringTest do
  use ExUnit.Case, async: true

  @moduledoc """
  Pins Fix E **at the defect site**.

  The bug was never in a helper — it was that the two raw-SQL sites in
  this package interpolated a *bare* table name, so a named-schema
  (`--prefix`) install queried `public` and raised "relation does not
  exist". Raw SQL text never goes through Ecto's query builder, so it
  picks up no prefix on its own; the only thing standing between a
  prefixed install and that crash is that each SQL builder is called
  with `qualify_table(table, @schema_prefix)` rather than `table`.

  That wiring cannot be pinned behaviourally: `@schema_prefix` comes
  from `Application.compile_env(:phoenix_kit, :prefix)` and is fixed at
  compile time (see `PhoenixKit.SchemaPrefix`), so a single test build
  cannot exercise both a prefixed and an unprefixed install. Asserting
  on the SQL that a builder returns for a table name the *test itself*
  qualified proves nothing about the call sites — revert both of them
  and such assertions stay green.

  So this guards the source, the same way
  `PhoenixKitEcommerce.SchemaPrefixConformanceTest` guards `use
  PhoenixKit.SchemaPrefix` on the Ecto schemas. It parses each file and
  resolves the first argument of every SQL-builder call back through
  local assignments: reverting either call site to the bare `table`
  fails this test.
  """

  @sites [
    {"lib/phoenix_kit_ecommerce/translation_fingerprint.ex", :candidates_sql},
    {"lib/phoenix_kit_ecommerce/mix_tasks/phoenix_kit_ecommerce.backfill_translation_fingerprints.ex",
     :build_sql}
  ]

  for {path, builder} <- @sites do
    test "#{path}: every #{builder}/2 call is given a @schema_prefix-qualified table" do
      path = unquote(path)
      builder = unquote(builder)

      ast = path |> File.read!() |> Code.string_to_quoted!()
      bindings = assignments(ast)
      calls = builder_calls(ast, builder)

      assert calls != [],
             "found no call to #{builder}/2 in #{path} — the guard has drifted from the code " <>
               "it is meant to protect; re-point it at the raw-SQL site."

      for arg <- calls do
        assert qualified?(resolve(arg, bindings)),
               """
               #{path}: #{builder}/2 is called with a table name that is not
               schema-qualified:

                   #{Macro.to_string(arg)}

               Raw SQL bypasses Ecto's query builder, so on a named-schema
               (`--prefix`) install this targets `public` and raises "relation
               does not exist". Wrap the table name:

                   PhoenixKitEcommerce.TranslationFingerprint.qualify_table(table, @schema_prefix)
               """
      end
    end
  end

  test "both raw-SQL modules carry the @schema_prefix attribute they interpolate" do
    for {path, _builder} <- @sites do
      assert uses_schema_prefix?(path),
             "#{path} interpolates a table name into raw SQL but has no " <>
               "`use PhoenixKit.SchemaPrefix` directive, so the @schema_prefix " <>
               "it passes to qualify_table/2 is an unbound attribute — silently " <>
               "nil, i.e. the bug again, on every install."
    end
  end

  # A real `use PhoenixKit.SchemaPrefix` *directive* — matched in the
  # AST, so the identical string appearing in a moduledoc cannot stand
  # in for the code that actually binds @schema_prefix.
  defp uses_schema_prefix?(path) do
    {_ast, found} =
      path
      |> File.read!()
      |> Code.string_to_quoted!()
      |> Macro.prewalk(false, fn
        {:use, _, [{:__aliases__, _, [:PhoenixKit, :SchemaPrefix]} | _]} = node, _acc ->
          {node, true}

        node, acc ->
          {node, acc}
      end)

    found
  end

  # ── AST helpers ───────────────────────────────────────────────────

  # First argument of every *call* to `builder`. Two things are pruned
  # from the walk so they are not mistaken for call sites: the
  # `def`/`defp` head that defines the builder (its parameter list looks
  # exactly like a call), and module attributes (`@spec build_sql(...)`,
  # `@dialyzer {:nowarn_function, build_sql: 2}`).
  defp builder_calls(ast, builder) do
    {_ast, calls} =
      Macro.prewalk(ast, [], fn
        {:@, _, _}, acc ->
          {nil, acc}

        {def_kind, _, [{^builder, _, _}, body]}, acc when def_kind in [:def, :defp] ->
          {body, acc}

        {^builder, _, [arg, _ | _]} = node, acc ->
          {node, [arg | acc]}

        node, acc ->
          {node, acc}
      end)

    calls
  end

  # `var = rhs` assignments, as a var-name => rhs map.
  defp assignments(ast) do
    {_ast, pairs} =
      Macro.prewalk(ast, [], fn
        {:=, _, [{name, _, ctx}, rhs]} = node, acc when is_atom(name) and is_atom(ctx) ->
          {node, [{name, rhs} | acc]}

        node, acc ->
          {node, acc}
      end)

    Map.new(pairs)
  end

  # Follow a bare variable back to what it was assigned (one hop is all
  # either site needs; the `seen` list keeps a rebinding cycle total).
  defp resolve(expr, bindings, seen \\ [])

  defp resolve({name, _, ctx} = expr, bindings, seen) when is_atom(name) and is_atom(ctx) do
    case Map.fetch(bindings, name) do
      {:ok, rhs} ->
        if name in seen, do: expr, else: resolve(rhs, bindings, [name | seen])

      :error ->
        expr
    end
  end

  defp resolve(expr, _bindings, _seen), do: expr

  # `qualify_table(_, @schema_prefix)`, local or remote-qualified.
  defp qualified?({:qualify_table, _, [_table, prefix]}), do: schema_prefix?(prefix)

  defp qualified?({{:., _, [_mod, :qualify_table]}, _, [_table, prefix]}),
    do: schema_prefix?(prefix)

  defp qualified?(_), do: false

  defp schema_prefix?({:@, _, [{:schema_prefix, _, _}]}), do: true
  defp schema_prefix?(_), do: false
end
