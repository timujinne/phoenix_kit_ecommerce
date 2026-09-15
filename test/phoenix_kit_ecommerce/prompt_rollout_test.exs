defmodule PhoenixKitEcommerce.PromptRolloutTest do
  use PhoenixKitEcommerce.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias PhoenixKit.Utils.Slug
  alias PhoenixKitEcommerce.PromptRollout

  # A unique slug/name per test avoids collisions with the real
  # phoenixkit-shop-product-translation row other suites in this file set
  # create, and with each other under async: false's shared connection.
  defp attrs(name, content, extra \\ %{}) do
    Map.merge(
      %{slug: Slug.slugify(name), name: name, description: "test prompt", content: content},
      extra
    )
  end

  test "no row at the slug: creates one with managed_by/content_sha metadata" do
    a = attrs("PR Test Create #{unique()}", "Hello {{Name}}")

    assert {:ok, uuid, :created} = PromptRollout.ensure(a)

    prompt = PhoenixKitAI.get_prompt(uuid)
    assert prompt.content == a.content
    assert prompt.metadata["managed_by"] == "phoenix_kit_ecommerce"
    assert prompt.metadata["content_sha"] == PromptRollout.content_sha(a.content)
  end

  test "idempotent: a second call with the same content returns the same uuid, :unchanged" do
    a = attrs("PR Test Idempotent #{unique()}", "Hello {{Name}}")

    assert {:ok, uuid, :created} = PromptRollout.ensure(a)
    assert {:ok, ^uuid, :unchanged} = PromptRollout.ensure(a)

    # content genuinely wasn't rewritten
    prompt = PhoenixKitAI.get_prompt(uuid)
    assert prompt.content == a.content
  end

  test "content differs but stored content_sha matches actual content: updates in place" do
    a = attrs("PR Test Update #{unique()}", "Version A {{Name}}")
    assert {:ok, uuid, :created} = PromptRollout.ensure(a)

    # The module's template "changed" — content_sha in metadata still
    # matches what's actually stored (nobody touched the row), so this is
    # safe to overwrite.
    b = %{a | content: "Version B {{Name}}"}
    assert {:ok, ^uuid, :updated} = PromptRollout.ensure(b)

    prompt = PhoenixKitAI.get_prompt(uuid)
    assert prompt.content == b.content
    assert prompt.metadata["content_sha"] == PromptRollout.content_sha(b.content)
  end

  test "a downgrade rolls the content back through the exact same update path" do
    a = attrs("PR Test Downgrade #{unique()}", "Version A {{Name}}")
    b = %{a | content: "Version B {{Name}}"}

    assert {:ok, uuid, :created} = PromptRollout.ensure(a)
    assert {:ok, ^uuid, :updated} = PromptRollout.ensure(b)

    # Code rolled back to the version-A template.
    assert {:ok, ^uuid, :updated} = PromptRollout.ensure(a)

    prompt = PhoenixKitAI.get_prompt(uuid)
    assert prompt.content == a.content
    assert prompt.metadata["content_sha"] == PromptRollout.content_sha(a.content)
  end

  test "an operator hand-edit is never overwritten; ensure/2 reports :diverged" do
    a = attrs("PR Test Diverge #{unique()}", "Version A {{Name}}")
    assert {:ok, uuid, :created} = PromptRollout.ensure(a)

    prompt = PhoenixKitAI.get_prompt(uuid)
    # Simulate an operator editing content through the AI admin: content
    # changes, metadata (still claiming the old sha) is left untouched —
    # exactly what a plain PhoenixKitAI.update_prompt/2 call from the admin
    # UI would do.
    {:ok, hand_edited} = PhoenixKitAI.update_prompt(prompt, %{content: "an operator wrote this"})
    assert hand_edited.metadata["content_sha"] == PromptRollout.content_sha(a.content)

    b = %{a | content: "Version B {{Name}}"}
    assert {:ok, ^uuid, :diverged} = PromptRollout.ensure(b)

    # untouched
    still = PhoenixKitAI.get_prompt(uuid)
    assert still.content == "an operator wrote this"
  end

  test "a bootstrap row (no metadata) whose content matches a known previous template is adopted" do
    name = "PR Test Bootstrap #{unique()}"
    old_content = "The old, unversioned template {{Name}}"

    # A row from before the metadata scheme existed: created directly,
    # bypassing PromptRollout entirely, so it carries the schema default
    # empty metadata.
    {:ok, bootstrap} =
      PhoenixKitAI.create_prompt(%{
        slug: Slug.slugify(name),
        name: name,
        content: old_content
      })

    assert bootstrap.metadata == %{}

    new_content = "The new template {{Name}}"
    a = attrs(name, new_content)
    known_previous_shas = [PromptRollout.content_sha(old_content)]

    assert {:ok, uuid, :adopted} = PromptRollout.ensure(a, known_previous_shas)
    assert uuid == bootstrap.uuid

    prompt = PhoenixKitAI.get_prompt(uuid)
    assert prompt.content == new_content
    assert prompt.metadata["managed_by"] == "phoenix_kit_ecommerce"
    assert prompt.metadata["content_sha"] == PromptRollout.content_sha(new_content)
  end

  test "a bootstrap row with unrecognized content is left alone, reported :diverged" do
    name = "PR Test Bootstrap Unknown #{unique()}"
    unrelated_content = "a completely custom prompt nobody's code ever shipped"

    {:ok, bootstrap} =
      PhoenixKitAI.create_prompt(%{
        slug: Slug.slugify(name),
        name: name,
        content: unrelated_content
      })

    a = attrs(name, "the current template {{Name}}")
    known_previous_shas = [PromptRollout.content_sha("some other old template")]

    assert {:ok, uuid, :diverged} = PromptRollout.ensure(a, known_previous_shas)
    assert uuid == bootstrap.uuid

    prompt = PhoenixKitAI.get_prompt(uuid)
    assert prompt.content == unrelated_content
  end

  test "metadata keys this module does not own survive a rollout" do
    a = attrs("PR Test Metadata Merge #{unique()}", "Version A {{Name}}")
    assert {:ok, uuid, :created} = PromptRollout.ensure(a)

    # Someone else stashes a key in the row's general-purpose metadata bag.
    created = PhoenixKitAI.get_prompt(uuid)

    {:ok, _} =
      PhoenixKitAI.update_prompt(created, %{
        metadata: Map.put(created.metadata, "host_note", "keep me")
      })

    # The unchanged-content path: nothing to write, nothing dropped.
    assert {:ok, ^uuid, :unchanged} = PromptRollout.ensure(a)
    assert PhoenixKitAI.get_prompt(uuid).metadata["host_note"] == "keep me"

    # The in-place-update path: our two keys are refreshed, the rest stays.
    b = %{a | content: "Version B {{Name}}"}
    assert {:ok, ^uuid, :updated} = PromptRollout.ensure(b)

    after_update = PhoenixKitAI.get_prompt(uuid)
    assert after_update.metadata["host_note"] == "keep me"
    assert after_update.metadata["content_sha"] == PromptRollout.content_sha(b.content)
    assert after_update.metadata["managed_by"] == "phoenix_kit_ecommerce"
  end

  test "a create race (unique violation on name) resolves to one row, not an error" do
    a = attrs("PR Test Race #{unique()}", "Hello {{Name}}")
    parent = self()

    tasks =
      for _ <- 1..2 do
        Task.async(fn ->
          Sandbox.allow(repo(), parent, self())
          PromptRollout.ensure(a)
        end)
      end

    results = Enum.map(tasks, &Task.await/1)

    assert Enum.all?(
             results,
             &match?({:ok, _uuid, status} when status in [:created, :unchanged], &1)
           )

    uuids = results |> Enum.map(fn {:ok, uuid, _} -> uuid end) |> Enum.uniq()
    assert [uuid] = uuids

    prompt = PhoenixKitAI.get_prompt(uuid)
    assert prompt.content == a.content
  end

  defp unique, do: System.unique_integer([:positive])

  defp repo, do: PhoenixKit.RepoHelper.repo()
end
