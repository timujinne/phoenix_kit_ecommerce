defmodule PhoenixKitEcommerce.API.ContextTest do
  @moduledoc """
  Language, currency and money of one public call. `async: false`: Billing's
  currency cache is node-global.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  import PhoenixKitEcommerce.SearchFixtures

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce, as: Shop
  alias PhoenixKitEcommerce.API.Context

  setup do
    disable_languages!()
    %{eur: eur} = currencies!()
    %{eur_row: eur}
  end

  defp handler_ctx(overrides \\ []) do
    Map.merge(
      %{
        language: "en",
        currency: nil,
        hosts: ["shop.test"],
        base_url: "https://shop.test",
        actor: nil,
        request_id: "req-1"
      },
      Map.new(overrides)
    )
  end

  defp build!(input \\ %{}, overrides \\ []) do
    assert {:ok, context} = Context.build(input, handler_ctx(overrides))
    context
  end

  test "defaults: the host's language and the shop's base currency" do
    context = build!()

    assert context.language == "en"
    assert context.currency.code == "USD"
    assert context.base.code == "USD"
    assert context.base_url == "https://shop.test"
    assert context.hosts == ["shop.test"]
    assert context.request_id == "req-1"
  end

  test "the host's currency is applied; an unusable one falls back to the base currency" do
    assert build!(%{}, currency: "EUR").currency.code == "EUR"
    assert build!(%{}, currency: "GBP").currency.code == "USD"
    assert build!(%{}, currency: "").currency.code == "USD"
  end

  test "an explicit currency wins over the host's, in any case" do
    assert build!(%{"currency" => "eur"}, currency: "USD").currency.code == "EUR"
    assert build!(%{"currency" => "USD"}, currency: "EUR").currency.code == "USD"
  end

  test "an explicit currency that is not enabled is refused with the allowed list" do
    assert {:error, :validation_failed, _message,
            %{errors: [%{path: "currency", allowed: ["EUR", "USD"]}]}} =
             Context.build(%{"currency" => "XXX"}, handler_ctx())
  end

  test "a disabled currency is not offered and not accepted", %{eur_row: eur} do
    {:ok, _} = PhoenixKitBilling.update_currency(eur, %{enabled: false})

    assert {:error, :validation_failed, _message, %{errors: [%{allowed: ["USD"]}]}} =
             Context.build(%{"currency" => "EUR"}, handler_ctx())

    assert build!(%{}, currency: "EUR").currency.code == "USD"
  end

  test "a host language resolves to the enabled dialect; an unknown one to the default" do
    enable_languages!(["en-US", "de-DE"])

    assert build!(%{}, language: "de").language == "de-DE"
    assert build!(%{}, language: "de-DE").language == "de-DE"
    assert build!(%{}, language: "DE-de").language == "de-DE"
    assert build!(%{}, language: "xx").language == "en-US"
    assert build!(%{}, language: nil).language == "en-US"
  end

  test "an explicit language that is not enabled is refused with the allowed list" do
    enable_languages!(["en-US", "de-DE"])

    assert build!(%{"language" => "de"}).language == "de-DE"

    assert {:error, :validation_failed, _message,
            %{errors: [%{path: "language", allowed: allowed}]}} =
             Context.build(%{"language" => "fr"}, handler_ctx())

    assert Enum.sort(allowed) == ["de-DE", "en-US"]
  end

  test "resolve_language/2 matches exactly, then ignoring case, then by base code" do
    enabled = ["en-US", "de-DE", "fr"]

    assert Context.resolve_language("fr", enabled) == "fr"
    assert Context.resolve_language("EN-us", enabled) == "en-US"
    assert Context.resolve_language("de", enabled) == "de-DE"
    assert Context.resolve_language("de-AT", enabled) == "de-DE"
    assert Context.resolve_language(nil, enabled) == "en"
  end

  test "money/2 writes the response currency with its decimals" do
    usd = build!()
    eur = build!(%{"currency" => "EUR"})

    assert Context.money(usd, Decimal.new("12.5")) == %{"amount" => "12.50", "currency" => "USD"}
    assert Context.money(usd, Decimal.new(10)) == %{"amount" => "10.00", "currency" => "USD"}
    assert Context.money(eur, Decimal.new(10)) == %{"amount" => "9.09", "currency" => "EUR"}
    assert Context.money(usd, nil) == nil
  end

  test "to_base/2 undoes the conversion" do
    usd = build!()
    eur = build!(%{"currency" => "EUR"})

    assert Decimal.equal?(Context.to_base(usd, Decimal.new("12.5")), Decimal.new("12.5"))

    back = eur |> Context.to_base(Decimal.new("9.09091")) |> Decimal.round(2)
    assert Decimal.equal?(back, Decimal.new("10.00"))
  end

  test "with_request_currency/2 sets the process currency for the call and restores the old one" do
    eur = build!(%{"currency" => "EUR"})
    Currency.put_request_currency("USD")

    assert Context.with_request_currency(eur, fn -> Currency.get_request_currency() end) == "EUR"
    assert Currency.get_request_currency() == "USD"

    assert_raise RuntimeError, "boom", fn ->
      Context.with_request_currency(eur, fn -> raise "boom" end)
    end

    assert Currency.get_request_currency() == "USD"
    Currency.put_request_currency(nil)
  end

  test "with_request_currency/2 makes links follow the domain's language, not the site default" do
    enable_languages!(["en-US", "de-DE"])
    {:ok, _} = Settings.update_boolean_setting("default_language_no_prefix", true)

    product =
      legacy_product!(%{"en-US" => "Red Vase", "de-DE" => "Rote Vase"}, %{})

    context = build!(%{}, language: "de")
    assert context.default_language == "de-DE"

    outside = Shop.product_url(product, "de-DE")
    assert String.starts_with?(outside, "/de/shop/product/")

    inside =
      Context.with_request_currency(context, fn ->
        {Shop.product_url(product, "de-DE"), Shop.product_url(product, "en-US")}
      end)

    assert {de_path, en_path} = inside
    assert String.starts_with?(de_path, "/shop/product/")
    refute de_path =~ "/de/"
    assert String.starts_with?(en_path, "/en/shop/product/")

    assert Languages.request_default_language() == nil
    assert Shop.product_url(product, "de-DE") == outside
  end

  test "with_request_currency/2 restores the previous default language, also when fun raises" do
    enable_languages!(["en-US", "de-DE"])
    Languages.put_request_default_language("en-US")
    context = build!(%{}, language: "de")

    assert Context.with_request_currency(context, fn -> Languages.request_default_language() end) ==
             "de-DE"

    assert Languages.request_default_language() == "en-US"

    assert_raise RuntimeError, "boom", fn ->
      Context.with_request_currency(context, fn -> raise "boom" end)
    end

    assert Languages.request_default_language() == "en-US"
    Languages.put_request_default_language(nil)
  end

  test "absolute/2 prefixes a path with the request's base URL and leaves a URL alone" do
    context = build!()

    assert Context.absolute(context, "/file/abc") == "https://shop.test/file/abc"
    assert Context.absolute(context, "https://cdn.example/x.jpg") == "https://cdn.example/x.jpg"
    assert Context.absolute(context, nil) == nil
    assert Context.absolute(context, "") == nil
  end

  describe "absolute/3, the link to a page of a language" do
    test "keeps the request's host and the path when no host app maps languages to domains" do
      context = build!()

      assert Context.absolute(context, "/de/shop/product/vase", "de-DE") ==
               "https://shop.test/de/shop/product/vase"

      assert Context.absolute(context, "/shop/product/vase", "en-US") ==
               "https://shop.test/shop/product/vase"

      assert Context.absolute(context, "https://cdn.example/x.jpg", "de-DE") ==
               "https://cdn.example/x.jpg"

      assert Context.absolute(context, nil, "de-DE") == nil
      assert Context.absolute(context, "", "de-DE") == nil
    end

    @tag :core_without_canonical_urls
    test "ignores the host resolver on a core that has no language-domain helpers" do
      put_canonical_host_resolver!()

      assert Context.absolute(build!(), "/de/shop/product/vase", "de-DE") ==
               "https://shop.test/de/shop/product/vase"
    end

    @tag :requires_core_canonical_urls
    test "puts a language that has a domain on it, without the language segment" do
      put_canonical_host_resolver!()
      context = build!()

      for language <- ["de", "de-DE", "de-AT"] do
        assert Context.absolute(context, "/de/shop/product/vase", language) ==
                 "https://shop.example.de/shop/product/vase"
      end

      assert Context.absolute(context, "/fr/shop/category/lampes", "fr-FR") ==
               "https://shop.example.fr/shop/category/lampes"
    end

    @tag :requires_core_canonical_urls
    test "a path that the request's own domain serves without a segment is left as it is" do
      put_canonical_host_resolver!()

      assert Context.absolute(build!(), "/shop/product/vase", "de-DE") ==
               "https://shop.example.de/shop/product/vase"
    end

    @tag :requires_core_canonical_urls
    test "a page named like the language is not mistaken for the language segment" do
      put_canonical_host_resolver!()

      assert Context.absolute(build!(), "/shop/product/de", "de-DE") ==
               "https://shop.example.de/shop/product/de"
    end

    @tag :requires_core_canonical_urls
    test "a language without a domain keeps the request's host and its segment" do
      put_canonical_host_resolver!()
      context = build!()

      assert Context.absolute(context, "/uk/shop/product/vase", "uk-UA") ==
               "https://shop.test/uk/shop/product/vase"

      assert Context.absolute(context, "/shop/product/vase", "en-US") ==
               "https://shop.test/shop/product/vase"
    end

    @tag :requires_core_canonical_urls
    test "the resolver is asked once per link, with a domain or without" do
      put_canonical_host_resolver!(:host_counted)
      context = build!()

      for {path, language} <- [
            {"/de/shop/product/vase", "de-DE"},
            {"/uk/shop/product/vase", "uk-UA"}
          ] do
        Process.put(:resolver_calls, 0)
        Context.absolute(context, path, language)
        assert Process.get(:resolver_calls) == 1
      end
    end

    @tag :requires_core_canonical_urls
    test "a URL and nil are left alone whatever the resolver says" do
      put_canonical_host_resolver!()
      context = build!()

      assert Context.absolute(context, "https://cdn.example/x.jpg", "de-DE") ==
               "https://cdn.example/x.jpg"

      assert Context.absolute(context, nil, "de-DE") == nil
      assert Context.absolute(context, "", "de-DE") == nil
    end
  end

  test "a shop with no currency at all is an internal error, not a crash" do
    Repo.delete_all(Currency)
    PhoenixKit.Cache.clear(:billing_currencies)

    assert {:error, :internal_error, message, %{}} = Context.build(%{}, handler_ctx())
    assert message =~ "base currency"
  end
end
