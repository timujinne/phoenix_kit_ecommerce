defmodule PhoenixKitEcommerce.DataCase do
  @moduledoc """
  Test case for tests that hit the database.

  Uses `PhoenixKitEcommerce.Test.Repo` with SQL Sandbox for per-test
  isolation. Tests using this case are tagged `:integration` and are
  automatically excluded when the database is unavailable (see
  `test/test_helper.exs`).

  ## Usage

      defmodule PhoenixKitEcommerce.Integration.SomethingTest do
        use PhoenixKitEcommerce.DataCase, async: true

        test "creates a record" do
          # Repo is available here; transactions are isolated.
        end
      end
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @moduletag :integration

      alias PhoenixKitEcommerce.Test.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import PhoenixKitEcommerce.ActivityLogAssertions
      import PhoenixKitEcommerce.DataCase
    end
  end

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Users.Auth
  alias PhoenixKitEcommerce.Test.Repo, as: TestRepo

  setup tags do
    pid = Sandbox.start_owner!(TestRepo, shared: not tags[:async])

    on_exit(fn -> Sandbox.stop_owner(pid) end)

    :ok
  end

  @doc """
  Transforms changeset errors into a map of field → [message] for easy assertions.
  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  @doc """
  Creates and persists a real `PhoenixKit.Users.Auth.User` via the public
  registration flow so cross-package FK constraints (e.g. order / cart
  ownership referencing `phoenix_kit_users`) are satisfied.

  Returns the inserted user. Accepts an optional attrs map (string keys),
  e.g. `%{"email" => "x@y.z"}`.
  """
  def fixture_user(attrs \\ %{}) do
    email =
      Map.get(attrs, "email") || "ecommerce-#{System.unique_integer([:positive])}@example.com"

    {:ok, user} =
      Auth.register_user(%{
        "email" => email,
        "password" => "password1234567"
      })

    user
  end
end
