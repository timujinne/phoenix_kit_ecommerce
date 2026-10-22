defmodule PhoenixKitEcommerce.APICase do
  @moduledoc """
  Runs an e-commerce tool the way core's executor does before it reaches the
  handler, minus authentication: the input goes through JSON (string keys, as
  over HTTP), is validated by core's own `PhoenixKit.API.Executor.validate_input/2`
  (the closed schema with the control fields of a write tool, and `max_items`),
  and only then reaches the handler with a context built by core's own
  `PhoenixKit.API.Executor.context_from/1` from the map the test gives.

      {:ok, answer} = APICase.call("ecommerce.set_prices", %{"items" => rows}, ctx)
      {:preview, preview, fingerprint} =
        APICase.call("ecommerce.set_prices", %{"items" => rows}, %{ctx | dry_run?: true})

  A handler test that goes through this helper therefore sees what a client
  sees: a malformed price or a `file://` URL is refused by the schema (the
  answer is `{:error, :validation_failed, message, %{errors: errors}}`) and
  never reaches the planner. A test of the planner's own second line of
  defence calls the handler directly and says so.

  This is NOT core's `Executor.call/4`: it never authenticates, rate-limits,
  checks a scope, confirms or claims an idempotency key. `executor_test.exs`
  runs the same tools through the real `Executor.call/4`.

  Needs core's tool registry: the tests that use it are tagged `:core_api`
  (the read tool) or `:core_confirm` (the write tools).
  """

  @compile {:no_warn_undefined, PhoenixKit.API.Executor}

  alias PhoenixKit.API.Executor

  @doc "The tool named `name` as `PhoenixKitEcommerce.api_tools/0` hands it to core."
  @spec tool!(String.t()) :: struct()
  def tool!(name) do
    Enum.find(PhoenixKitEcommerce.api_tools(), &(&1.name == name)) ||
      raise ArgumentError,
            "no e-commerce tool named #{inspect(name)}; core needs the tool registry and, " <>
              "for the write tools, the confirmation flow"
  end

  @doc "Calls tool `name` with `input` and the handler context `ctx`."
  @spec call(String.t(), map(), map()) :: term()
  def call(name, input, ctx) do
    tool = tool!(name)
    input = input |> Jason.encode!() |> Jason.decode!()

    case Executor.validate_input(tool, input) do
      {:ok, valid} ->
        {module, function} = tool.handler
        apply(module, function, [valid, Executor.context_from(ctx)])

      {:error, errors} ->
        {:error, :validation_failed, "The input does not match the schema of #{name}.",
         %{errors: errors}}
    end
  end
end
