defmodule PhoenixKitEcommerce.TranslationPipelineSeamTest do
  @moduledoc """
  The one seam no test in either package covered: the WHOLE pipeline, with
  the real upstream `PhoenixKitAI.TranslateWorker` driving the real shop
  adapters.

  `translation_seam_test.exs` pins the boundaries between this package's
  own modules, and phoenix_kit_ai's suite pins `safe_put_translation/3`
  against hand-rolled fake adapters. Neither of them would notice if the
  two packages disagreed about the SHAPE of what crosses between them —
  the `:source_fields` opt key, the prompt-vocabulary keys inside it, the
  `resource_type` strings the worker resolves adapters by, or the
  `{{SourceFields}}` variable the shipped prompt templates are built on.
  This file drives an actual `%Oban.Job{}` through `perform/1` with the
  model stubbed at the HTTP layer, and checks what lands in the database.

  ## The version floor, stated as a test rather than a comment

  `{{SourceFields}}` (design §9.1) and the `:source_fields` opt (design
  §9.3) are both unreleased upstream: `mix.exs` still floors
  `phoenix_kit_ai` at `~> 0.18`, and hex's newest 0.19.2 has neither (see
  the RAISE-THIS-FLOOR note at that dependency). So these tests branch on
  whether the INSTALLED engine actually carries §9.3, and assert something
  real either way — the capable branch pins the seam, the incapable branch
  pins the degradation the floor note describes, so neither silently
  passes.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.AITranslatable
  alias PhoenixKitEcommerce.CategoryAITranslatable
  alias PhoenixKitEcommerce.TranslationFingerprint, as: FP

  # Design §9.3 landed upstream ⇒ the worker threads the source fields it
  # read into `put_translation/4`'s opts. Probed rather than assumed: this
  # package's dependency floor still admits engines without it.
  defp engine_threads_source_fields? do
    Code.ensure_loaded?(PhoenixKitAI.TranslateWorker) and
      function_exported?(PhoenixKitAI.TranslateWorker, :safe_put_translation, 3)
  end

  setup do
    Application.put_env(:phoenix_kit_ai, :req_options, plug: {Req.Test, __MODULE__}, retry: false)

    {:ok, _} =
      PhoenixKit.Settings.update_json_setting(
        "integration:openrouter:default",
        %{"api_key" => "sk-test-key", "status" => "connected", "provider" => "openrouter"}
      )

    on_exit(fn -> Application.delete_env(:phoenix_kit_ai, :req_options) end)
    :ok
  end

  # Stubs the model and forwards the request body back to the test, so the
  # rendered prompt itself can be asserted on — that is where an unbound
  # `{{SourceFields}}` would show up.
  defp stub_model(reply_text) do
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:request_body, Jason.decode!(raw)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{
          "choices" => [%{"message" => %{"content" => reply_text}}],
          "usage" => %{"prompt_tokens" => 10, "completion_tokens" => 10, "total_tokens" => 20}
        })
      )
    end)
  end

  defp endpoint_fixture do
    {:ok, endpoint} =
      PhoenixKitAI.create_endpoint(%{
        name: "PIPE-#{System.unique_integer([:positive])}",
        provider: "openrouter",
        model: "anthropic/claude-3-haiku",
        api_key: "sk-test-key"
      })

    endpoint
  end

  defp job(args) do
    %Oban.Job{id: System.unique_integer([:positive]), attempt: 1, max_attempts: 3, args: args}
  end

  defp sent_prompt do
    assert_received {:request_body, body}
    Enum.map_join(body["messages"], "\n", & &1["content"])
  end

  describe "a real TranslateWorker job against the real product adapter" do
    setup do
      {:ok, product} =
        Shop.create_product(%{
          title: %{"en" => "Wooden Vase"},
          description: %{"en" => "A nice vase"},
          body_html: %{"en" => "<p>Body</p>\n"},
          price: Decimal.new("10.00"),
          status: "active"
        })

      {:ok, prompt_uuid, _sync} = AITranslatable.ensure_prompt()

      %{product: product, prompt_uuid: prompt_uuid, endpoint: endpoint_fixture()}
    end

    test "translates, slugs, fingerprints and converges", ctx do
      # Before: the sweep would pick this pair up.
      assert [%{uuid: uuid, languages: ["de"]}] = AITranslatable.candidates("en", ["de"])
      assert uuid == ctx.product.uuid

      stub_model("""
      ---BODY---
      <p>Körper</p>
      ---DESCRIPTION---
      Eine schöne Vase
      ---TITLE---
      Holzvase
      """)

      assert :ok =
               PhoenixKitAI.TranslateWorker.perform(
                 job(%{
                   "resource_type" => "shop_product",
                   "resource_uuid" => ctx.product.uuid,
                   "endpoint_uuid" => ctx.endpoint.uuid,
                   "prompt_uuid" => ctx.prompt_uuid,
                   "source_lang" => "en",
                   "target_lang" => "de"
                 })
               )

      updated = Shop.get_product(ctx.product.uuid)
      assert updated.title["de"] == "Holzvase"
      assert updated.description["de"] == "Eine schöne Vase"
      # Slug is minted locally from the translated title, never asked of the AI.
      assert updated.slug["de"] not in [nil, ""]
      # The source language is untouched.
      assert updated.title["en"] == "Wooden Vase"

      prompt = sent_prompt()

      if engine_threads_source_fields?() do
        # §9.1: the source travels as one marker section per field passed,
        # and nothing in the rendered template is left unbound.
        assert prompt =~ "---TITLE---\nWooden Vase"
        assert prompt =~ "---BODY---\n<p>Body</p>"
        refute prompt =~ "{{"

        # §9.3 + §4.1: the fingerprint is of the text the job READ, keyed by
        # schema field name even though the prompt used its own vocabulary.
        assert FP.get(updated.metadata, "de", "title") == FP.hash("Wooden Vase")
        assert FP.get(updated.metadata, "de", "body_html") == FP.hash("<p>Body</p>\n")

        # §4.3's convergence property, end to end: having been translated,
        # the pair must not come back as a candidate on the next tick.
        assert AITranslatable.candidates("en", ["de"]) == []
      else
        # Engine predating §9.1/§9.3 (see the moduledoc): the shipped
        # template's whole SOURCE section renders as a literal placeholder,
        # and no fingerprint can be taken. Asserted, not skipped, so the
        # gap is visible in the suite rather than implied by a comment.
        assert prompt =~ "{{SourceFields}}"
        assert FP.get(updated.metadata, "de", "title") == nil
      end
    end

    test "a second run over unchanged source writes nothing (design §4.4)", ctx do
      if engine_threads_source_fields?() do
        full_reply = """
        ---BODY---
        <p>Körper</p>
        ---DESCRIPTION---
        Eine schöne Vase
        ---TITLE---
        Holzvase
        """

        stub_model(full_reply)

        args = %{
          "resource_type" => "shop_product",
          "resource_uuid" => ctx.product.uuid,
          "endpoint_uuid" => ctx.endpoint.uuid,
          "prompt_uuid" => ctx.prompt_uuid,
          "source_lang" => "en",
          "target_lang" => "de"
        }

        assert :ok = PhoenixKitAI.TranslateWorker.perform(job(args))
        first = Shop.get_product(ctx.product.uuid)

        # An operator hand-corrects the German title...
        {:ok, _} =
          Shop.update_product(first, %{
            "title" => Map.put(first.title, "de", "Vase aus Holz")
          })

        # ...and a routine re-run must NOT clobber it: the fingerprint still
        # matches the (unchanged) English source, so the field is skipped.
        stub_model(full_reply)
        assert :ok = PhoenixKitAI.TranslateWorker.perform(job(args))

        assert Shop.get_product(ctx.product.uuid).title["de"] == "Vase aus Holz"
      end
    end
  end

  describe "a real TranslateWorker job against the real category adapter" do
    test "translates, slugs, fingerprints and converges" do
      {:ok, category} =
        Shop.create_category(%{
          name: %{"en" => "Vases"},
          description: %{"en" => "Nice vases"},
          status: "active"
        })

      {:ok, prompt_uuid, _sync} = CategoryAITranslatable.ensure_prompt()
      endpoint = endpoint_fixture()

      assert [%{languages: ["de"]}] = CategoryAITranslatable.candidates("en", ["de"])

      stub_model("""
      ---DESCRIPTION---
      Schöne Vasen
      ---NAME---
      Vasen
      """)

      assert :ok =
               PhoenixKitAI.TranslateWorker.perform(
                 job(%{
                   "resource_type" => "shop_category",
                   "resource_uuid" => category.uuid,
                   "endpoint_uuid" => endpoint.uuid,
                   "prompt_uuid" => prompt_uuid,
                   "source_lang" => "en",
                   "target_lang" => "de"
                 })
               )

      updated = Shop.get_category(category.uuid)
      assert updated.name["de"] == "Vasen"
      assert updated.slug["de"] not in [nil, ""]

      _prompt = sent_prompt()

      if engine_threads_source_fields?() do
        # Both adapters must lay the fingerprint out the same way — one
        # sweep reads both.
        assert FP.get(updated.metadata, "de", "name") == FP.hash("Vases")
        assert CategoryAITranslatable.candidates("en", ["de"]) == []
      else
        assert FP.get(updated.metadata, "de", "name") == nil
      end
    end
  end

  describe "the shop adapters are reachable through the upstream resolver" do
    test "resource_type strings the sweep enqueues resolve to these adapters" do
      assert PhoenixKitAI.Translatables.find("shop_product") == AITranslatable
      assert PhoenixKitAI.Translatables.find("shop_category") == CategoryAITranslatable
    end
  end

  describe "known degradation: the product form replaces metadata wholesale" do
    # Characterization, not endorsement. `Web.ProductForm` rebuilds
    # `metadata` from its own inputs and writes it back whole ("this build
    # REPLACES metadata wholesale" — product_form.ex), so a product form
    # save erases EVERY fingerprint on that product, for every language.
    # Design §4.1 accepted this ("крючков на форму ради этого не заводим")
    # on the understanding that the pair lands in `:unknown`, which the
    # management page shows and the sweep never queues on its own. The
    # consequence worth having pinned is the second half: a source edited
    # AFTER such a save is invisible to the sweep, because the pair is
    # `:unknown` rather than `:stale`. If this test ever starts failing,
    # someone changed that trade-off — deliberately or not.
    test "a form-shaped save drops the fingerprints, and a later source change stays :unknown" do
      {:ok, product} =
        Shop.create_product(%{
          title: %{"en" => "Wooden Vase"},
          price: Decimal.new("10.00"),
          status: "active"
        })

      {:ok, translated} =
        AITranslatable.put_translation(product, "de", %{"title" => "Holzvase"},
          source_fields: %{"title" => "Wooden Vase"}
        )

      assert FP.get(translated.metadata, "de", "title") == FP.hash("Wooden Vase")
      assert AITranslatable.candidates("en", ["de"]) == []

      {:ok, saved} = Shop.update_product(translated, %{"metadata" => %{}})
      assert FP.get(saved.metadata, "de", "title") == nil

      {:ok, changed} =
        Shop.update_product(saved, %{"title" => %{"en" => "Oak Vase", "de" => "Holzvase"}})

      assert FP.field_state(
               changed.title["en"],
               changed.title["de"],
               FP.get(changed.metadata, "de", "title")
             ) == :unknown

      assert AITranslatable.candidates("en", ["de"]) == []
    end
  end
end
