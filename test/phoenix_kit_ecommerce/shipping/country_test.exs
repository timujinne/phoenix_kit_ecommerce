defmodule PhoenixKitEcommerce.Shipping.CountryTest do
  @moduledoc """
  The destination country in the provider contract: `Context.country`,
  `RateRequest.country`, `Locality.country`, `Service.countries` and the
  optional `Provider.countries/0`, which the `Shipping` facade enforces.
  """

  # Changes the application env (provider registry) and starts the named cache.
  use ExUnit.Case, async: false

  alias PhoenixKitEcommerce.Shipping

  alias PhoenixKitEcommerce.Shipping.{
    Cache,
    Codec,
    Context,
    Destination,
    Locality,
    Parcel,
    Quote,
    RateRequest,
    Service
  }

  alias PhoenixKitEcommerce.Test.Shipping.{CountryProvider, StubProvider}

  defmodule BadCountries do
    @moduledoc false
    @behaviour PhoenixKitEcommerce.Shipping.Provider

    @impl true
    def key, do: "bad_countries"
    @impl true
    def label, do: "Bad countries"
    @impl true
    def services(_ctx), do: [%PhoenixKitEcommerce.Shipping.Service{key: "x"}]
    @impl true
    def settings_fields, do: []
    @impl true
    def countries, do: raise("countries blew up")

    @impl true
    def quote(_request, _ctx),
      do: {:ok, %PhoenixKitEcommerce.Shipping.Quote{amount: Decimal.new(1)}}
  end

  setup do
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
      CountryProvider,
      StubProvider,
      BadCountries
    ])

    Application.put_env(:phoenix_kit_ecommerce, :shipping_country_provider, ["UA", "PL"])

    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
      Application.delete_env(:phoenix_kit_ecommerce, :shipping_country_provider)
    end)

    start_supervised!(Cache)
    :ok
  end

  defp ctx(stub \\ %{}, opts \\ []) do
    Shipping.context(
      nil,
      [
        provider: "country_stub",
        credentials: nil,
        currency: "EUR",
        stub: Map.put_new(stub, :notify, self())
      ] ++
        opts
    )
  end

  defp request(attrs \\ []) do
    struct(
      %RateRequest{
        service: "branch",
        destination: %Destination{locality: %Locality{id: "city-1", name: "Warsaw"}},
        parcels: [%Parcel{weight_g: 1000}],
        declared_value: Decimal.new("100"),
        currency: "EUR"
      },
      attrs
    )
  end

  describe "Codec.country/1 and countries/1" do
    test "a country is two letters in upper case" do
      assert Codec.country("pl") == "PL"
      assert Codec.country(" ua ") == "UA"
      assert Codec.country("EE") == "EE"
    end

    test "anything else is not a country" do
      for value <- ["", "P", "POL", "P1", "ł", nil, :pl, 12, %{}] do
        assert Codec.country(value) == nil, inspect(value)
      end
    end

    test "a list is normalised, de-duplicated and cleaned" do
      assert Codec.countries(["pl", "UA", "PL", "nope", nil, 3]) == ["PL", "UA"]
      assert Codec.countries("PL") == []
      assert Codec.countries(nil) == []
    end
  end

  describe "structs" do
    test "the country of a context, a request and a locality is normalised on the way in" do
      assert %Context{country: "PL"} = Context.from_map(%{"country" => "pl"})
      assert %RateRequest{country: "EE"} = RateRequest.from_map(%{"country" => " ee "})
      assert %Locality{country: "LT"} = Locality.from_map(%{"id" => "1", "country" => "lt"})
      assert %Locality{country: nil} = Locality.from_map(%{"id" => "1", "country" => "Poland"})
    end

    test "a service lists the countries it serves" do
      assert %Service{countries: ["PL", "UA"]} =
               Service.from_map(%{"key" => "s", "countries" => ["pl", "UA", "bogus"]})

      assert %Service{countries: []} = Service.from_map(%{"key" => "s"})
      assert %Service{countries: []} = Service.from_map(%{"key" => "s", "countries" => "PL"})
    end

    test "the serialised context carries the country and still no credentials" do
      map = Context.to_map(%Context{country: "PL", credentials: %{"api_key" => "secret"}})

      assert map["country"] == "PL"
      refute inspect(map) =~ "secret"
    end
  end

  describe "context/2" do
    test "takes the country from the options, normalised" do
      assert Shipping.context(nil, country: "pl").country == "PL"
      assert Shipping.context(nil, country: "Poland").country == nil
      assert Shipping.context(nil).country == nil
    end

    test "the country is not passed on in ctx.opts" do
      refute Keyword.has_key?(Shipping.context(nil, country: "PL").opts, :country)
    end
  end

  describe "provider_countries/1, serves_country?/2 and providers_for_country/1" do
    test "a provider declares its countries" do
      assert Shipping.provider_countries(CountryProvider) == ["UA", "PL"]
    end

    test "a provider that declares none, or none known, serves any" do
      assert Shipping.provider_countries(StubProvider) == []
      assert Shipping.provider_countries(nil) == []
      assert Shipping.provider_countries(NotAModule) == []
    end

    test "a countries/0 that raises means any" do
      assert Shipping.provider_countries(BadCountries) == []
      assert Shipping.serves_country?(BadCountries, "PL")
    end

    test "a country that is unknown is never refused" do
      assert Shipping.serves_country?(CountryProvider, nil)
      assert Shipping.serves_country?(CountryProvider, "not a country")
    end

    test "a declared provider serves its countries only" do
      assert Shipping.serves_country?(CountryProvider, "PL")
      assert Shipping.serves_country?(CountryProvider, "pl")
      refute Shipping.serves_country?(CountryProvider, "EE")
      assert Shipping.serves_country?(StubProvider, "EE")
    end

    test "providers_for_country/1 filters the registry" do
      assert CountryProvider in Shipping.providers_for_country("PL")
      refute CountryProvider in Shipping.providers_for_country("EE")
      assert StubProvider in Shipping.providers_for_country("EE")
      assert Shipping.providers_for_country(nil) == Shipping.providers()

      # The built-in providers declare nothing, so they serve every country.
      assert PhoenixKitEcommerce.Shipping.Providers.Fixed in Shipping.providers_for_country("EE")
    end
  end

  describe "a country the provider does not deliver to" do
    test "services, lookups and quotes are refused without calling the provider" do
      ctx = ctx(%{localities: [%Locality{id: "1", name: "Tallinn"}]}, country: "EE")

      assert Shipping.services(ctx) == {:error, :unsupported_destination}
      assert Shipping.search_localities(ctx, "Tal") == {:error, :unsupported_destination}

      assert Shipping.list_pickup_points(ctx, %Locality{id: "1"}, nil) ==
               {:error, :unsupported_destination}

      assert Shipping.quote(ctx, request()) == {:error, :unsupported_destination}

      refute_received {:stub_called, _operation, _args}
    end

    test "the refusal is a business error, so the method is unavailable rather than priced" do
      assert Shipping.business_error?(:unsupported_destination)
    end

    test "the country of the request counts when the context has none" do
      assert Shipping.quote(ctx(), request(country: "EE")) == {:error, :unsupported_destination}
      refute_received {:stub_called, :quote, _}
    end

    test "and wins over the country of the context" do
      assert {:ok, %Quote{}} = Shipping.quote(ctx(%{}, country: "EE"), request(country: "PL"))
      assert_received {:stub_called, :quote, _}
    end

    test "a country that is not known yet is not refused" do
      assert {:ok, [_ | _]} = Shipping.services(ctx())
      assert {:ok, %Quote{}} = Shipping.quote(ctx(), request())
    end
  end

  describe "a country the provider delivers to" do
    test "reaches the provider as ctx.country" do
      quote_fun = fn _request, ctx ->
        {:ok, %Quote{amount: Decimal.new(1), currency: "EUR", note: ctx.country}}
      end

      assert {:ok, %Quote{note: "PL"}} =
               Shipping.quote(ctx(%{quote: quote_fun}, country: "PL"), request())

      assert {:ok, %Quote{note: "PL"}} =
               Shipping.quote(ctx(%{quote: quote_fun}), request(country: "PL"))
    end

    test "the lookups see it too" do
      seen = fn query -> {:ok, [%Locality{id: "1", name: query, country: "PL"}]} end

      assert {:ok, [%Locality{country: "PL"}]} =
               Shipping.search_localities(ctx(%{localities: seen}, country: "PL"), "War")
    end
  end

  describe "Service.countries" do
    @services [
      %Service{key: "everywhere", destination: :address},
      %Service{key: "poland", destination: :address, countries: ["PL"]},
      %Service{key: "ukraine", destination: :address, countries: ["UA"]}
    ]

    test "a context without a country lists every service" do
      assert {:ok, services} = Shipping.services(ctx(%{services: @services}))
      assert Enum.map(services, & &1.key) == ["everywhere", "poland", "ukraine"]
    end

    test "a country keeps the services that serve it, and those that name none" do
      assert {:ok, services} = Shipping.services(ctx(%{services: @services}, country: "PL"))
      assert Enum.map(services, & &1.key) == ["everywhere", "poland"]
    end

    test "no service for the country is a refusal, not an empty list" do
      only_ukraine = [%Service{key: "ukraine", destination: :address, countries: ["UA"]}]

      assert Shipping.services(ctx(%{services: only_ukraine}, country: "PL")) ==
               {:error, :unsupported_destination}
    end

    test "a provider with no services at all still has none" do
      assert Shipping.services(ctx(%{services: []}, country: "PL")) == {:ok, []}
    end
  end

  describe "caching" do
    test "the country is part of the cache key" do
      lookup = fn country ->
        Shipping.search_localities(
          ctx(%{localities: [%Locality{id: "1", name: "A"}]}, country: country),
          "Ab"
        )
      end

      assert {:ok, _} = lookup.("PL")
      assert {:ok, _} = lookup.("PL")
      assert {:ok, _} = lookup.("UA")

      assert_received {:stub_called, :search_localities, _}
      assert_received {:stub_called, :search_localities, _}
      refute_received {:stub_called, :search_localities, _}
    end
  end

  describe "request_hash/1" do
    test "a country changes the hash" do
      refute Shipping.request_hash(request(country: "PL")) ==
               Shipping.request_hash(request(country: "UA"))

      refute Shipping.request_hash(request(country: "PL")) == Shipping.request_hash(request())
    end

    test "a request without a country keeps the hash it had before countries existed" do
      assert Shipping.request_hash(request(country: nil)) == Shipping.request_hash(request())
    end
  end
end
