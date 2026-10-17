defmodule PhoenixKitEcommerce.CartClaimTest do
  @moduledoc """
  The claims table against a real database, and the analytics-exclusion step
  of V5 against a stubbed analytics table (DDL is transactional, so the stub
  disappears with the sandbox transaction).
  """

  use PhoenixKitEcommerce.DataCase, async: false

  import Ecto.Query

  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.CartClaim
  alias PhoenixKitEcommerce.Migrations

  @key "web_analytics_exclude_paths"

  defp cart! do
    {:ok, cart} = Shop.create_cart(session_id: "claim-test-#{System.unique_integer([:positive])}")
    cart
  end

  defp claim_attrs(cart, overrides \\ %{}) do
    Map.merge(
      %{
        token_hash: "th-#{System.unique_integer([:positive])}",
        cart_uuid: cart.uuid,
        cart_token_hash: "ch-#{System.unique_integer([:positive])}",
        language: "en",
        expires_at:
          DateTime.utc_now() |> DateTime.add(1800, :second) |> DateTime.truncate(:second)
      },
      overrides
    )
  end

  defp setting(key),
    do: Repo.one(from s in "phoenix_kit_settings", where: s.key == ^key, select: s.value)

  defp stub_analytics_table!,
    do: Repo.query!("CREATE TABLE IF NOT EXISTS phoenix_kit_web_analytics_events (id integer)")

  describe "the table" do
    test "stores a claim for a cart and enforces a unique token hash" do
      cart = cart!()
      attrs = claim_attrs(cart)

      assert {:ok, %CartClaim{used_at: nil, superseded_at: nil}} =
               %CartClaim{} |> CartClaim.changeset(attrs) |> Repo.insert()

      assert {:error, changeset} = %CartClaim{} |> CartClaim.changeset(attrs) |> Repo.insert()
      assert %{token_hash: [_ | _]} = errors_on(changeset)
    end

    test "deleting the cart deletes its claims" do
      cart = cart!()
      {:ok, claim} = %CartClaim{} |> CartClaim.changeset(claim_attrs(cart)) |> Repo.insert()

      Repo.delete!(cart)

      assert Repo.get(CartClaim, claim.uuid) == nil
    end

    test "requires a token hash, a cart, a cart token hash, a language and an expiry" do
      changeset = CartClaim.changeset(%CartClaim{}, %{})

      assert %{
               token_hash: ["can't be blank"],
               cart_uuid: ["can't be blank"],
               cart_token_hash: ["can't be blank"],
               language: ["can't be blank"],
               expires_at: ["can't be blank"]
             } = errors_on(changeset)
    end
  end

  describe "the analytics exclusion step" do
    test "does nothing while the analytics module is not installed" do
      Repo.delete_all(from s in "phoenix_kit_settings", where: s.key == ^@key)
      Repo.query!("DROP TABLE IF EXISTS phoenix_kit_web_analytics_events")

      [step] = Migrations.claim_analytics_statements("public")
      Repo.query!(step)

      assert setting(@key) == nil
    end

    test "appends the pattern once to an existing list" do
      stub_analytics_table!()
      {:ok, _} = PhoenixKit.Settings.update_setting(@key, "/admin*\n/live*")

      [step] = Migrations.claim_analytics_statements("public")
      Repo.query!(step)
      Repo.query!(step)

      assert setting(@key) == "/admin*\n/live*\n/checkout/claim/*"
    end

    test "a line that only contains the pattern is not the pattern" do
      stub_analytics_table!()
      {:ok, _} = PhoenixKit.Settings.update_setting(@key, "/admin*\n/shop/checkout/claim/*")

      [step] = Migrations.claim_analytics_statements("public")
      Repo.query!(step)

      assert setting(@key) == "/admin*\n/shop/checkout/claim/*\n/checkout/claim/*"
    end

    test "the pattern on a line of its own is left alone, whatever the line ends or padding" do
      stub_analytics_table!()
      value = "/admin*\r\n  /checkout/claim/*  \n/live*"
      {:ok, _} = PhoenixKit.Settings.update_setting(@key, value)

      [step] = Migrations.claim_analytics_statements("public")
      Repo.query!(step)

      assert setting(@key) == value
    end

    test "the pattern in a comma separated or tab padded value is left alone, like analytics reads it" do
      stub_analytics_table!()
      [step] = Migrations.claim_analytics_statements("public")

      for value <- ["/admin*,/checkout/claim/*", "/admin*\n\t/checkout/claim/*\t\n/live*"] do
        {:ok, _} = PhoenixKit.Settings.update_setting(@key, value)
        Repo.query!(step)
        assert setting(@key) == value
      end
    end

    test "a comma separated value without the pattern gets it once" do
      stub_analytics_table!()
      {:ok, _} = PhoenixKit.Settings.update_setting(@key, "/admin*,/shop/checkout/claim/*")

      [step] = Migrations.claim_analytics_statements("public")
      Repo.query!(step)
      Repo.query!(step)

      assert setting(@key) == "/admin*,/shop/checkout/claim/*\n/checkout/claim/*"
    end

    test "writes the analytics defaults plus the pattern when the setting has no row yet" do
      stub_analytics_table!()
      Repo.delete_all(from s in "phoenix_kit_settings", where: s.key == ^@key)

      [step] = Migrations.claim_analytics_statements("public")
      Repo.query!(step)

      value = setting(@key)
      assert String.ends_with?(value, "\n/checkout/claim/*")
      assert value =~ "/admin*"
    end

    # Needs the optional analytics module: `test_helper.exs` excludes `:analytics`
    # when it is not loaded, so a missing dependency shows up in the `excluded`
    # count instead of the test passing without asserting anything. What the
    # exclusion buys on a real install (no event is recorded for a claim path)
    # needs the running application.
    @tag :analytics
    test "the pattern matches a claim path and nothing outside it, by analytics' own rule" do
      assert PhoenixKitWebAnalytics.Config.excluded?("/checkout/claim/abc", ["/checkout/claim/*"])
      assert PhoenixKitWebAnalytics.Config.excluded?("/checkout/claim/", ["/checkout/claim/*"])
      refute PhoenixKitWebAnalytics.Config.excluded?("/checkout", ["/checkout/claim/*"])

      refute PhoenixKitWebAnalytics.Config.excluded?("/checkout/complete/abc", [
               "/checkout/claim/*"
             ])

      # the same pattern without the trailing `*` is an exact path and matches nothing real
      refute PhoenixKitWebAnalytics.Config.excluded?("/checkout/claim/abc", ["/checkout/claim/"])
    end
  end
end
