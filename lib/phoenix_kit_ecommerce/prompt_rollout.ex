defmodule PhoenixKitEcommerce.PromptRollout do
  @moduledoc """
  Shared rollout mechanism for the `PhoenixKitAI.Prompt` rows this app
  manages as code (design doc §5.2).

  A translation prompt lives as a row in `phoenix_kit_ai_prompts`, keyed by
  slug. A prompt module (`AITranslatable`, and the category adapter that
  mirrors it) ships its *desired* content as an Elixir string; getting a
  code change to actually reach the stand means writing that string over
  the stored row — but only when doing so is safe.

  There is no version number. The content itself is the version: a second
  counter would be a second source of truth for "which prompt is this",
  free to disagree with the thing it's supposed to describe. Instead every
  row this module writes carries `metadata`:

      %{"managed_by" => "phoenix_kit_ecommerce", "content_sha" => sha256(content)}

  The invariant that makes unattended rollout safe: **stored `content_sha`
  matches the row's actual content ⇒ nobody has touched the row since we
  last wrote it ⇒ safe to overwrite in place.** The moment an operator
  hand-edits the content through the AI admin, `content_sha` stops
  matching and this module goes quiet — an edited prompt is never
  silently clobbered, on either an upgrade or a downgrade of the shipping
  template (the template is just "whatever `ensure/2` was called with
  this time," so rolling code back rolls the prompt back with it, via the
  exact same in-place-update path as rolling forward).

  ## Resolution

  `ensure/2` walks these cases, in order, every time it's called:

    1. No row at this slug — create it, with `metadata` already attached.
       A create race (two nodes booting together) resolves the same way
       the pre-existing adapter code always has: unique-violation, then
       re-read by slug.
    2. A row exists and its `content` already equals the template — the
       row is current. Metadata is backfilled if it's missing or stale
       (covers the race-loser path above, and a row `update_prompt/2`
       touched for an unrelated reason), otherwise nothing is written.
    3. A row exists with different content:
       - stored `content_sha` matches a fresh hash of that content — the
         row is exactly what THIS module wrote last time, so it's safe to
         update in place.
       - stored `content_sha` is absent (a row that predates this scheme
         entirely) — adopt it if its content hashes to one of
         `known_previous_shas`, the caller-supplied list of templates
         this code used to ship. A bootstrap row with unrecognized
         content was never ours; leave it alone (falls through to the
         next case).
       - anything else — an operator edited the content. Leave it
         untouched and report `:diverged` so a caller (the translations
         management page) can surface the mismatch; the row's uuid is
         still returned because the prompt is still perfectly usable for
         translation, just not code-managed until someone resolves the
         divergence by hand.

  Two nodes racing case 3 concurrently is fine without extra locking:
  both compute the same target content from the same deployed code, so
  both writes converge on identical bytes — idempotent by construction.

  This module never checks whether `phoenix_kit_ai` is installed; the
  optional-dependency guard belongs to each adapter's own `ensure_prompt/0`
  (mirroring how `AITranslatable` already gates on
  `Code.ensure_loaded?/1`), so this module can assume `PhoenixKitAI` is
  callable.
  """

  # phoenix_kit_ai is an optional dependency; see the moduledoc above for
  # why the availability guard lives in the caller, not here.
  @compile {:no_warn_undefined, PhoenixKitAI}

  @managed_by "phoenix_kit_ecommerce"

  @type sync_status :: :created | :unchanged | :updated | :adopted | :diverged

  @type attrs :: %{
          required(:slug) => String.t(),
          required(:name) => String.t(),
          required(:content) => String.t(),
          optional(:description) => String.t()
        }

  @doc """
  Sha256 hex digest of prompt content — the "version" this module tracks.
  Public so adapters can compute `known_previous_shas` entries without
  reimplementing the hash.
  """
  @spec content_sha(String.t()) :: String.t()
  def content_sha(content) when is_binary(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  @doc """
  Idempotently rolls `attrs` (a prompt's slug/name/description/content) out
  to the database, per the resolution order in the moduledoc.

  `known_previous_shas` is the list of `content_sha` values this code has
  ever shipped for this slug BEFORE the metadata scheme existed — used
  only to adopt a pre-existing unversioned row. Once a row carries
  `metadata`, this list is never consulted again for it.
  """
  @spec ensure(attrs(), [String.t()]) ::
          {:ok, String.t(), sync_status()} | {:error, term()}
  def ensure(%{slug: slug, content: content} = attrs, known_previous_shas \\ [])
      when is_binary(slug) and is_binary(content) and is_list(known_previous_shas) do
    target_sha = content_sha(content)

    case PhoenixKitAI.get_prompt_by_slug(slug) do
      nil -> create(attrs, target_sha, known_previous_shas)
      prompt -> reconcile(prompt, attrs, target_sha, known_previous_shas)
    end
  end

  # -- internals -----------------------------------------------------------

  defp create(attrs, target_sha, known_previous_shas) do
    case PhoenixKitAI.create_prompt(Map.put(attrs, :metadata, metadata(target_sha))) do
      {:ok, prompt} ->
        {:ok, prompt.uuid, :created}

      {:error, _changeset} ->
        # Lost a create race. The winner ran the same deployed code, so
        # its committed content should equal our own target — reconcile
        # takes the "already current" fast path below. known_previous_shas
        # is still threaded through for the rolling-deploy edge case where
        # the winner was on a different code version.
        case PhoenixKitAI.get_prompt_by_slug(attrs.slug) do
          nil -> {:error, :prompt_create_failed}
          prompt -> reconcile(prompt, attrs, target_sha, known_previous_shas)
        end
    end
  end

  defp reconcile(prompt, attrs, target_sha, known_previous_shas) do
    cond do
      prompt.content == attrs.content ->
        backfill_metadata(prompt, target_sha)

      safely_updatable?(prompt) ->
        update(prompt, attrs, target_sha, :updated)

      bootstrap_row?(prompt) and content_sha(prompt.content) in known_previous_shas ->
        update(prompt, attrs, target_sha, :adopted)

      true ->
        {:ok, prompt.uuid, :diverged}
    end
  end

  # content: unchanged, so this never touches the row's translated
  # content — only ever brings metadata up to what it should already say.
  defp backfill_metadata(prompt, target_sha) do
    canonical = metadata(target_sha)

    if prompt.metadata == canonical do
      {:ok, prompt.uuid, :unchanged}
    else
      case PhoenixKitAI.update_prompt(prompt, %{metadata: canonical}) do
        {:ok, updated} -> {:ok, updated.uuid, :unchanged}
        {:error, changeset} -> {:error, changeset}
      end
    end
  end

  # Deliberately omits :name/:description — Prompt.changeset/2 regenerates
  # :slug from a :name change (prompt.ex `maybe_generate_slug/1`), and this
  # module always looks its row up again by the caller's fixed slug. Nudging
  # the name here would silently move the row out from under that lookup.
  defp update(prompt, attrs, target_sha, status) do
    case PhoenixKitAI.update_prompt(prompt, %{
           content: attrs.content,
           metadata: metadata(target_sha)
         }) do
      {:ok, updated} -> {:ok, updated.uuid, status}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp safely_updatable?(prompt) do
    case stored_sha(prompt) do
      nil -> false
      stored -> stored == content_sha(prompt.content)
    end
  end

  defp bootstrap_row?(prompt), do: is_nil(stored_sha(prompt))

  defp stored_sha(%{metadata: metadata}), do: (metadata || %{})["content_sha"]

  defp metadata(content_sha) do
    %{"managed_by" => @managed_by, "content_sha" => content_sha}
  end
end
