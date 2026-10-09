defmodule PhoenixKitEcommerce.Shipping.FacadeTest do
  # Changes application env and starts the named cache, so not async.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitEcommerce.Shipping

  alias PhoenixKitEcommerce.Shipping.{
    Address,
    Cache,
    Context,
    Destination,
    Locality,
    Parcel,
    PickupPoint,
    Quote,
    RateLimit,
    RateRequest,
    Service
  }

  alias PhoenixKitEcommerce.Shipping.Providers.{Fixed, Table}

  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  defmodule OtherFixed do
    @moduledoc false
    def key, do: "fixed"
  end

  defmodule BadCurrencies do
    @moduledoc false
    @behaviour PhoenixKitEcommerce.Shipping.Provider

    @impl true
    def key, do: "bad_currencies"
    @impl true
    def label, do: "Bad currencies"
    @impl true
    def services(_ctx), do: []
    @impl true
    def settings_fields, do: []
    @impl true
    def currencies, do: raise("currencies blew up")

    @impl true
    def quote(_request, _ctx),
      do: {:ok, %PhoenixKitEcommerce.Shipping.Quote{amount: Decimal.new(1)}}
  end

  defmodule NotAProvider do
    @moduledoc false
  end

  defmodule UahOnly do
    @moduledoc false
    @behaviour PhoenixKitEcommerce.Shipping.Provider

    @impl true
    def key, do: "uah_only"
    @impl true
    def label, do: "UAH only"
    @impl true
    def services(_ctx), do: []
    @impl true
    def settings_fields, do: []
    @impl true
    def currencies, do: ["UAH"]

    @impl true
    def quote(_request, ctx) do
      send(ctx.opts[:notify], :uah_only_quoted)
      {:ok, %PhoenixKitEcommerce.Shipping.Quote{amount: Decimal.new(1), currency: "UAH"}}
    end
  end

  setup do
    on_exit(fn ->
      Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
      Application.delete_env(:phoenix_kit_ecommerce, :shipping_provider_timeout)
    end)

    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider])
    :ok
  end

  defp stub_method(block \\ %{}) do
    %ShippingMethod{
      uuid: "00000000-0000-0000-0000-000000000001",
      price: Decimal.new("49"),
      currency: "UAH",
      metadata: %{
        "shipping_provider" =>
          Map.merge(
            %{"provider" => "stub", "service" => "branch", "settings" => %{"x" => 1}},
            block
          )
      }
    }
  end

  defp stub_ctx(stub \\ %{}, opts \\ []) do
    Shipping.context(
      stub_method(),
      [credentials: nil, stub: Map.put_new(stub, :notify, self())] ++ opts
    )
  end

  defp locality, do: %Locality{id: "city-1", name: "Springfield"}

  defp request(attrs \\ []) do
    struct(
      %RateRequest{
        service: "branch",
        destination: %Destination{locality: locality()},
        parcels: [%Parcel{weight_g: 1000}],
        declared_value: Decimal.new("100"),
        currency: "UAH"
      },
      attrs
    )
  end

  describe "providers/0 and provider/1" do
    test "lists the built-ins first, then the configured providers" do
      assert Shipping.providers() == [Fixed, Table, StubProvider]
    end

    test "only the built-ins without configuration" do
      Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
      assert Shipping.providers() == [Fixed, Table]
    end

    test "drops duplicates by key, the first module wins" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
        StubProvider,
        OtherFixed,
        StubProvider
      ])

      assert Shipping.providers() == [Fixed, Table, StubProvider]
    end

    test "skips modules that are not providers" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [
        NotAProvider,
        Does.Not.Exist,
        nil,
        "string",
        StubProvider
      ])

      assert Shipping.providers() == [Fixed, Table, StubProvider]
    end

    test "provider/1 finds by key" do
      assert Shipping.provider("fixed") == {:ok, Fixed}
      assert Shipping.provider("table") == {:ok, Table}
      assert Shipping.provider("stub") == {:ok, StubProvider}
      assert Shipping.provider("nope") == :error
      assert Shipping.provider(nil) == :error
    end
  end

  describe "context/2" do
    test "assembles a context from the method" do
      ctx = Shipping.context(stub_method(), credentials: %{"api_key" => "k"}, locale: "uk")

      assert %Context{
               provider: StubProvider,
               service: "branch",
               settings: %{"x" => 1},
               credentials: %{"api_key" => "k"},
               locale: "uk",
               currency: "UAH",
               opts: []
             } = ctx

      assert ctx.method.uuid == "00000000-0000-0000-0000-000000000001"
    end

    test "a method without the block uses the fixed provider" do
      ctx = Shipping.context(%ShippingMethod{price: Decimal.new(5)})

      assert ctx.provider == Fixed
      assert ctx.service == nil
      assert ctx.credentials == nil
    end

    test "an unknown provider key gives a context without a provider" do
      ctx = Shipping.context(stub_method(%{"provider" => "ghost"}))
      assert ctx.provider == nil

      assert Shipping.services(ctx) == {:error, :unknown_provider}
      assert Shipping.quote(ctx, request()) == {:error, :unknown_provider}
      assert Shipping.search_localities(ctx, "Pol") == {:error, :unknown_provider}
      assert Shipping.list_pickup_points(ctx, locality()) == {:error, :unknown_provider}
    end

    test "options override the method" do
      ctx =
        Shipping.context(nil,
          provider: "table",
          service: "default",
          settings: %{"rates" => "1 5"}
        )

      assert %Context{provider: Table, service: "default", settings: %{"rates" => "1 5"}} = ctx

      assert Shipping.context(nil, provider: StubProvider, credentials: nil).provider ==
               StubProvider

      assert Shipping.context(nil, provider: NotAProvider).provider == nil
    end

    test "unrelated options are passed through" do
      ctx =
        Shipping.context(stub_method(), credentials: nil, req_options: [retry: false], timeout: 5)

      assert ctx.opts == [req_options: [retry: false], timeout: 5]
    end

    test "a nil method works" do
      assert %Context{method: nil, provider: Fixed, currency: nil} = Shipping.context(nil)
    end

    test "credentials are not looked up for providers without integration/0" do
      # Fixed exports no integration/0; the override is ignored and nothing
      # touches the database.
      assert Shipping.context(nil, credentials: %{"api_key" => "k"}).credentials == nil
    end

    test "credentials override accepts an explicit nil" do
      assert Shipping.context(stub_method(), credentials: nil).credentials == nil
    end

    test "a failing credentials lookup leaves credentials nil" do
      # No override, so the facade asks PhoenixKit.Integrations. In this
      # sandbox-less process that raises; the result must still be nil.
      with_uuid =
        stub_method(%{"settings" => %{"integration" => "0190c0de-0000-7000-8000-000000000000"}})

      log =
        capture_log(fn ->
          assert Shipping.context(stub_method()).credentials == nil
          assert Shipping.context(with_uuid).credentials == nil
        end)

      refute log =~ "api_key"
    end
  end

  describe "services/1" do
    test "returns the provider services" do
      assert {:ok, [%Service{key: "branch"}, %Service{key: "courier"}]} =
               Shipping.services(stub_ctx())

      assert_received {:stub_called, :services, []}
    end

    test "works for the built-in providers" do
      assert {:ok, [%Service{key: "default"}]} = Shipping.services(Shipping.context(nil))
    end
  end

  describe "search_localities/2" do
    test "short queries do not reach the provider" do
      ctx = stub_ctx(%{localities: [locality()]})

      assert Shipping.search_localities(ctx, "") == {:ok, []}
      assert Shipping.search_localities(ctx, "P") == {:ok, []}
      assert Shipping.search_localities(ctx, "  P ") == {:ok, []}
      assert Shipping.search_localities(ctx, nil) == {:ok, []}
      refute_received {:stub_called, :search_localities, _}
    end

    test "delegates a trimmed query" do
      ctx = stub_ctx(%{localities: fn query -> {:ok, [%Locality{id: "1", name: query}]} end})

      assert {:ok, [%Locality{name: "Pol"}]} = Shipping.search_localities(ctx, "  Pol ")
      assert_received {:stub_called, :search_localities, ["Pol"]}
    end

    test "a provider without the callback is not supported" do
      assert Shipping.search_localities(Shipping.context(nil), "Springfield") ==
               {:error, :not_supported}
    end
  end

  describe "list_pickup_points/4" do
    test "passes locality, service and query to the provider" do
      ctx = stub_ctx(%{points: [StubProvider.point("p1")]})

      assert {:ok, [%PickupPoint{id: "p1"}]} =
               Shipping.list_pickup_points(ctx, locality(), " 12 ")

      assert_received {:stub_called, :list_pickup_points,
                       [%Locality{id: "city-1"}, "branch", "12"]}
    end

    test "a blank query means no narrowing" do
      ctx = stub_ctx(%{points: [StubProvider.point("p1")]})

      assert {:ok, _} = Shipping.list_pickup_points(ctx, locality(), "  ")
      assert_received {:stub_called, :list_pickup_points, [_, "branch", nil]}
    end

    test "a provider without the callback is not supported" do
      assert Shipping.list_pickup_points(Shipping.context(nil), locality()) ==
               {:error, :not_supported}
    end

    test "errors are passed on" do
      ctx = stub_ctx(%{points: {:error, :offline}})

      capture_log(fn ->
        assert Shipping.list_pickup_points(ctx, locality(), nil) == {:error, :offline}
      end)
    end

    test "filters by weight, dimensions and declared value" do
      points = [
        StubProvider.point("any"),
        StubProvider.point("light", %{max_weight_g: 500}),
        StubProvider.point("small", %{max_dims_mm: [300, 200, 100]}),
        StubProvider.point("cheap", %{max_declared: Decimal.new("50")})
      ]

      ctx = stub_ctx(%{points: points})
      ids = fn {:ok, found} -> Enum.map(found, & &1.id) end

      assert ids.(Shipping.list_pickup_points(ctx, locality(), nil)) ==
               ["any", "light", "small", "cheap"]

      parcels = [%Parcel{weight_g: 1000, length_mm: 400, width_mm: 100, height_mm: 50}]

      assert ids.(Shipping.list_pickup_points(ctx, locality(), nil, parcels: parcels)) ==
               ["any", "cheap"]

      assert ids.(
               Shipping.list_pickup_points(ctx, locality(), nil,
                 parcels: parcels,
                 declared_value: Decimal.new("100")
               )
             ) == ["any"]

      assert ids.(
               Shipping.list_pickup_points(ctx, locality(), nil,
                 declared_value: Decimal.new("100")
               )
             ) == ["any", "light", "small"]
    end
  end

  describe "quote/2" do
    test "returns the provider quote and fills service and currency" do
      ctx =
        stub_ctx(%{
          quote: fn request, _ctx ->
            {:ok,
             %Quote{amount: Decimal.new(77), currency: request.currency, note: request.service}}
          end
        })

      assert {:ok, %Quote{note: "branch", currency: "UAH"}} =
               Shipping.quote(ctx, request(service: nil, currency: nil))
    end

    test "a provider that returns something else is a bad return" do
      ctx = stub_ctx(%{mode: :bad_return})

      capture_log(fn ->
        assert {:error, {:bad_return, ":nonsense"}} = Shipping.quote(ctx, request())
      end)
    end

    test "a quote of the wrong shape is a bad return" do
      ctx = stub_ctx(%{quote: fn _request, _ctx -> {:ok, :not_a_quote} end})

      capture_log(fn ->
        assert {:error, {:bad_return, _}} = Shipping.quote(ctx, request())
      end)
    end

    test "works for the built-in table provider" do
      ctx = Shipping.context(nil, provider: "table", settings: %{"rates" => "2 100"})

      assert {:ok, %Quote{source: :table}} = Shipping.quote(ctx, request())
    end
  end

  describe "failures" do
    test "an exception becomes provider_crashed and is logged" do
      ctx = stub_ctx(%{mode: :crash})

      log =
        capture_log(fn ->
          assert {:error, {:provider_crashed, "stub quote crashed"}} =
                   Shipping.quote(ctx, request())
        end)

      assert log =~ "Shipping provider stub quote failed"
    end

    test "a throw and an exit become provider_crashed too" do
      thrower = stub_ctx(%{quote: fn _, _ -> throw(:oops) end})
      exiter = stub_ctx(%{quote: fn _, _ -> exit(:bye) end})

      capture_log(fn ->
        assert {:error, {:provider_crashed, thrown}} = Shipping.quote(thrower, request())
        assert thrown =~ "oops"
        assert {:error, {:provider_crashed, exited}} = Shipping.quote(exiter, request())
        assert exited =~ "bye"
      end)
    end

    test "a hanging provider times out" do
      ctx = stub_ctx(%{mode: :hang}, timeout: 50)

      log = capture_log(fn -> assert Shipping.quote(ctx, request()) == {:error, :timeout} end)

      assert log =~ "failed: :timeout"
    end

    test "the timeout comes from the application config" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_provider_timeout, 50)

      capture_log(fn ->
        assert Shipping.services(stub_ctx(%{mode: :hang})) == {:error, :timeout}
      end)
    end

    test "an operation can fail while the others work" do
      ctx = stub_ctx(%{modes: %{quote: :crash}})

      assert {:ok, [_ | _]} = Shipping.services(ctx)

      capture_log(fn ->
        assert {:error, {:provider_crashed, _}} = Shipping.quote(ctx, request())
      end)
    end

    test "transient provider errors are logged as warnings and passed on" do
      ctx = stub_ctx(%{quote: {:error, :offline}})

      log = capture_log(fn -> assert Shipping.quote(ctx, request()) == {:error, :offline} end)

      assert log =~ "[warning]"
      assert log =~ ":offline"
    end

    test "business errors are passed on and logged at info level" do
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)

      ctx = stub_ctx(%{quote: {:error, :too_heavy}})

      log =
        capture_log([level: :info], fn ->
          assert Shipping.quote(ctx, request()) == {:error, :too_heavy}
        end)

      assert log =~ "[info]"
      assert log =~ ":too_heavy"
      refute log =~ "[warning]"
    end
  end

  describe "worker isolation" do
    test "a provider that kills itself does not kill the caller" do
      ctx = stub_ctx(%{quote: fn _request, _ctx -> Process.exit(self(), :kill) end})

      capture_log(fn ->
        assert {:error, {:provider_crashed, message}} = Shipping.quote(ctx, request())
        assert message =~ "killed"
      end)

      assert Process.alive?(self())
    end

    test "a crash of a process linked to the provider does not kill the caller" do
      ctx =
        stub_ctx(%{
          quote: fn _request, _ctx ->
            spawn_link(fn -> exit(:boom) end)
            Process.sleep(:infinity)
          end
        })

      capture_log(fn ->
        assert {:error, {:provider_crashed, message}} = Shipping.quote(ctx, request())
        assert message =~ "boom"
      end)

      assert Process.alive?(self())
    end

    test "a timeout leaves no live worker, nor its linked processes" do
      test_pid = self()

      ctx =
        stub_ctx(
          %{
            quote: fn _request, _ctx ->
              linked = spawn_link(fn -> Process.sleep(:infinity) end)
              send(test_pid, {:pids, self(), linked})
              Process.sleep(:infinity)
            end
          },
          timeout: 50
        )

      capture_log(fn -> assert Shipping.quote(ctx, request()) == {:error, :timeout} end)

      assert_received {:pids, worker, linked}

      for pid <- [worker, linked] do
        ref = Process.monitor(pid)
        assert_receive {:DOWN, ^ref, :process, ^pid, _reason}
      end
    end

    test "the worker is already gone when the timeout is reported" do
      test_pid = self()

      ctx =
        stub_ctx(
          %{
            quote: fn _request, _ctx ->
              send(test_pid, {:worker, self()})
              Process.sleep(:infinity)
            end
          },
          timeout: 50
        )

      capture_log(fn -> assert Shipping.quote(ctx, request()) == {:error, :timeout} end)

      assert_received {:worker, worker}
      assert Process.info(worker) == nil
    end

    test "no stray messages are left in the caller mailbox" do
      ctx = stub_ctx(%{mode: :hang}, timeout: 20)
      capture_log(fn -> Shipping.quote(ctx, request()) end)
      capture_log(fn -> Shipping.quote(stub_ctx(%{mode: :crash}), request()) end)
      assert {:ok, _} = Shipping.quote(stub_ctx(), request())

      {:messages, messages} = Process.info(self(), :messages)
      refute Enum.any?(messages, &match?({:DOWN, _, _, _, _}, &1))
      refute Enum.any?(messages, &match?({ref, _} when is_reference(ref), &1))
    end

    test "the worker inherits the callers" do
      test_pid = self()

      ctx =
        stub_ctx(%{
          quote: fn _request, _ctx ->
            send(test_pid, {:callers, Process.get(:"$callers")})
            {:ok, %Quote{amount: Decimal.new(1)}}
          end
        })

      assert {:ok, _} = Shipping.quote(ctx, request())
      assert_received {:callers, callers}
      assert test_pid in callers
    end

    test "the worker gets the Gettext locale of the context" do
      test_pid = self()

      ctx =
        stub_ctx(
          %{
            quote: fn _request, _ctx ->
              locale = {
                Gettext.get_locale(PhoenixKitEcommerce.Gettext),
                Gettext.get_locale()
              }

              send(test_pid, {:locale, locale})
              {:ok, %Quote{amount: Decimal.new(1)}}
            end
          },
          locale: "uk"
        )

      assert {:ok, _} = Shipping.quote(ctx, request())
      assert_received {:locale, {"uk", "uk"}}
    end

    test "without a context locale the callers locale is used" do
      Gettext.put_locale(PhoenixKitEcommerce.Gettext, "ru")
      on_exit(fn -> Gettext.put_locale(PhoenixKitEcommerce.Gettext, "en") end)
      test_pid = self()

      ctx =
        stub_ctx(%{
          quote: fn _request, _ctx ->
            send(test_pid, {:locale, Gettext.get_locale(PhoenixKitEcommerce.Gettext)})
            {:ok, %Quote{amount: Decimal.new(1)}}
          end
        })

      ctx = %{ctx | locale: nil}
      assert {:ok, _} = Shipping.quote(ctx, request())
      assert_received {:locale, "ru"}
    end
  end

  describe "quote validation" do
    test "a missing, negative or non-decimal amount is a bad return" do
      for bad <- [nil, Decimal.new("-1"), 5, "5", Decimal.new("NaN")] do
        ctx = stub_ctx(%{quote: fn _request, _ctx -> {:ok, %Quote{amount: bad}} end})

        capture_log(fn ->
          assert {:error, {:bad_return, _}} = Shipping.quote(ctx, request())
        end)
      end
    end

    test "a zero amount is fine" do
      ctx = stub_ctx(%{quote: fn _request, _ctx -> {:ok, %Quote{amount: Decimal.new(0)}} end})
      assert {:ok, %Quote{}} = Shipping.quote(ctx, request())
    end
  end

  describe "bogus providers" do
    test "never raise" do
      for provider <- [NotAProvider, Does.Not.Exist, :nope, "string", 42] do
        ctx = %Context{provider: provider, service: "s"}

        assert Shipping.services(ctx) == {:error, :unknown_provider}
        assert Shipping.quote(ctx, request()) == {:error, :unknown_provider}
        assert Shipping.search_localities(ctx, "Springfield") == {:error, :unknown_provider}
        assert Shipping.list_pickup_points(ctx, locality()) == {:error, :unknown_provider}
      end
    end
  end

  describe "business_error?/1" do
    test "recognises the business vocabulary" do
      for reason <- [
            :too_heavy,
            :too_large,
            :service_unavailable,
            :unsupported_destination,
            :invalid_destination,
            :unsupported_currency,
            :no_rates,
            {:too_heavy, 30_000}
          ] do
        assert Shipping.business_error?(reason)
      end
    end

    test "everything else is transient" do
      for reason <- [
            :timeout,
            {:provider_crashed, "x"},
            {:bad_return, "x"},
            {:http, 500},
            :nxdomain,
            "text",
            nil
          ] do
        refute Shipping.business_error?(reason)
      end
    end
  end

  describe "currencies/0" do
    setup do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [UahOnly, StubProvider])
      :ok
    end

    test "a currency outside the list is rejected without calling the provider" do
      ctx = Shipping.context(nil, provider: "uah_only", notify: self())

      assert Shipping.quote(ctx, request(currency: "USD")) == {:error, :unsupported_currency}
      refute_received :uah_only_quoted
    end

    test "a listed currency is quoted" do
      ctx = Shipping.context(nil, provider: "uah_only", notify: self())

      assert {:ok, %Quote{}} = Shipping.quote(ctx, request(currency: "UAH"))
      assert_received :uah_only_quoted
    end

    test "the currency of the context fills a missing request currency" do
      ctx = Shipping.context(nil, provider: "uah_only", notify: self(), currency: "EUR")

      assert Shipping.quote(ctx, request(currency: nil)) == {:error, :unsupported_currency}
    end

    test "a currencies/0 that raises does not escape the facade" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [BadCurrencies])
      ctx = Shipping.context(nil, provider: "bad_currencies")

      capture_log(fn ->
        assert {:error, {:provider_crashed, message}} = Shipping.quote(ctx, request())
        assert message =~ "currencies blew up"
      end)
    end

    test "providers without currencies/0 accept any currency" do
      assert {:ok, _} = Shipping.quote(stub_ctx(), request(currency: "JPY"))
    end
  end

  describe "request_hash/1 format" do
    test "negative zero and scale do not matter" do
      one = request(declared_value: Decimal.new("-0"), cod_amount: Decimal.new("0.00"))
      two = request(declared_value: Decimal.new("0"), cod_amount: Decimal.new("0"))

      assert Shipping.request_hash(one) == Shipping.request_hash(two)
    end

    test "key order at any depth does not matter" do
      one = request(origin: %{"a" => %{"x" => 1, "y" => 2}, "b" => [%{"p" => 1, "q" => 2}]})
      two = request(origin: %{"b" => [%{"q" => 2, "p" => 1}], "a" => %{"y" => 2, "x" => 1}})

      assert Shipping.request_hash(one) == Shipping.request_hash(two)
    end

    test "never raises, whatever the origin holds" do
      for origin <- [
            %{"bytes" => <<255, 254, 0>>},
            %{{:tuple, :key} => 1},
            %{"pid" => self(), "tuple" => {1, :two, "3"}, "fun" => &is_atom/1},
            %{"nested" => [<<0xC3, 0x28>>, {:a, <<255>>}]},
            %{<<255>> => 1}
          ] do
        assert hash = Shipping.request_hash(request(origin: origin))
        assert hash =~ ~r/\A[0-9a-f]{32}\z/
        assert hash == Shipping.request_hash(request(origin: origin))
      end
    end

    test "different non-UTF-8 bytes hash differently" do
      one = request(origin: %{"b" => <<255>>})
      two = request(origin: %{"b" => <<254>>})

      refute Shipping.request_hash(one) == Shipping.request_hash(two)
    end

    test "is pinned to the canonical JSON, since carts store it" do
      request = %RateRequest{
        service: "s",
        origin: %{"b" => 1, "a" => 2},
        destination: %Destination{locality: %Locality{id: "c1"}},
        parcels: [%Parcel{weight_g: 100}],
        declared_value: Decimal.new("10.50"),
        cod_amount: nil,
        currency: "UAH"
      }

      json =
        ~s({"cod_amount":null,"currency":"UAH","declared_value":"10.5",) <>
          ~s("destination":{"address":null,"locality":"c1","pickup_point":null},) <>
          ~s("origin":{"a":2,"b":1},) <>
          ~s("parcels":[{"height_mm":null,"length_mm":null,"weight_g":100,"width_mm":null}],) <>
          ~s("service":"s"})

      expected =
        :sha256 |> :crypto.hash(json) |> binary_part(0, 16) |> Base.encode16(case: :lower)

      assert Shipping.request_hash(request) == expected
    end
  end

  describe "telemetry" do
    test "emits start and stop events with the provider and operation" do
      ref = make_ref()
      test_pid = self()
      handler = "shipping-test-#{inspect(ref)}"

      :telemetry.attach_many(
        handler,
        [
          [:phoenix_kit_ecommerce, :shipping, :provider, :start],
          [:phoenix_kit_ecommerce, :shipping, :provider, :stop]
        ],
        fn event, _measurements, metadata, _config -> send(test_pid, {ref, event, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      assert {:ok, _} = Shipping.quote(stub_ctx(), request())

      assert_receive {^ref, [:phoenix_kit_ecommerce, :shipping, :provider, :start],
                      %{provider: "stub", operation: :quote}}

      assert_receive {^ref, [:phoenix_kit_ecommerce, :shipping, :provider, :stop],
                      %{provider: "stub", operation: :quote, status: :ok}}
    end

    test "marks failures" do
      ref = make_ref()
      test_pid = self()
      handler = "shipping-test-#{inspect(ref)}"

      :telemetry.attach(
        handler,
        [:phoenix_kit_ecommerce, :shipping, :provider, :stop],
        fn _event, _measurements, metadata, _config -> send(test_pid, {ref, metadata}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      capture_log(fn -> Shipping.quote(stub_ctx(%{mode: :crash}), request()) end)

      assert_receive {^ref, %{status: :error, operation: :quote}}
    end
  end

  describe "bounded lookups" do
    @cache_table :phoenix_kit_ecommerce_shipping_cache

    setup do
      start_supervised!(Cache)

      on_exit(fn ->
        for key <- [
              :shipping_cache_max_lookup_entries,
              :shipping_cache_max_list_size,
              :shipping_lookup_rate
            ],
            do: Application.delete_env(:phoenix_kit_ecommerce, key)
      end)

      :ok
    end

    defp cities(count), do: for(n <- 1..count, do: %Locality{id: "c#{n}", name: "City #{n}"})

    defp query_entries,
      do: :ets.select_count(@cache_table, [{{:_, :_, :_, :query}, [], [true]}])

    defp search_calls(count \\ 0) do
      receive do
        {:stub_called, :search_localities, _} -> search_calls(count + 1)
      after
        0 -> count
      end
    end

    test "a list longer than the limit is returned but not cached" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_list_size, 3)

      long = stub_ctx(%{localities: cities(5)})
      assert {:ok, [_, _, _, _, _]} = Shipping.search_localities(long, "spr")
      assert {:ok, [_, _, _, _, _]} = Shipping.search_localities(long, "spr")
      assert search_calls() == 2

      short = stub_ctx(%{localities: cities(3)})
      assert {:ok, [_, _, _]} = Shipping.search_localities(short, "short")
      assert {:ok, [_, _, _]} = Shipping.search_localities(short, "short")
      assert search_calls() == 1
    end

    test "a pickup point list longer than the limit is not cached either" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_list_size, 2)
      points = for n <- 1..4, do: %PickupPoint{id: "p#{n}"}
      ctx = stub_ctx(%{points: points}, service: "branch")

      assert {:ok, [_, _, _, _]} = Shipping.list_pickup_points(ctx, locality(), nil)
      assert {:ok, [_, _, _, _]} = Shipping.list_pickup_points(ctx, locality(), nil)

      assert_received {:stub_called, :list_pickup_points, _}
      assert_received {:stub_called, :list_pickup_points, _}
    end

    test "lookups with a shopper query have a bound of their own" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_lookup_entries, 5)
      ctx = stub_ctx(%{localities: cities(1)})

      # An entry of another kind, in the shared part of the table.
      assert {:ok, quote} = Shipping.quote(ctx, request())

      for n <- 1..30, do: Shipping.search_localities(ctx, "query #{n}")

      assert query_entries() <= 5
      assert query_entries() > 0

      assert {:ok, ^quote} = Shipping.quote(ctx, request())
      assert_received {:stub_called, :quote, _}
      refute_received {:stub_called, :quote, _}
    end

    test "the point filter of a shopper counts among the query lookups, the whole list does not" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_max_lookup_entries, 3)
      ctx = stub_ctx(%{points: [%PickupPoint{id: "p1"}]}, service: "branch")

      for n <- 1..10, do: Shipping.list_pickup_points(ctx, locality(), "filter #{n}")
      assert query_entries() <= 3

      Shipping.list_pickup_points(ctx, locality(), nil)
      assert query_entries() <= 3
      assert :ets.info(@cache_table, :size) >= 1
    end

    test "provider lookups are limited per provider and the limit is transient" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 3)
      ctx = stub_ctx(%{localities: cities(1)})

      answers = for n <- 1..6, do: Shipping.search_localities(ctx, "limited #{n}")

      assert Enum.count(answers, &match?({:ok, _}, &1)) == 3
      assert Enum.count(answers, &(&1 == {:error, :rate_limited})) == 3
      assert Shipping.business_error?(:rate_limited) == false
      assert search_calls() == 3

      # Not cached: once the bucket has room again the same query is asked.
      RateLimit.reset()
      assert {:ok, [_]} = Shipping.search_localities(ctx, "limited 6")

      # A cached answer costs nothing.
      RateLimit.reset()
      for _ <- 1..10, do: assert({:ok, [_]} = Shipping.search_localities(ctx, "limited 6"))
    end

    test "pickup point lists share the provider's limit; quotes and services are not limited" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 2)
      ctx = stub_ctx(%{points: [%PickupPoint{id: "p1"}]}, service: "branch")

      answers = for n <- 1..4, do: Shipping.list_pickup_points(ctx, locality(), "f#{n}")
      assert Enum.count(answers, &(&1 == {:error, :rate_limited})) == 2

      assert {:ok, _} = Shipping.quote(ctx, request())
      assert {:ok, [_ | _]} = Shipping.services(ctx)
    end

    test "the limit is not shared between providers" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 1)
      Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider, UahOnly])

      ctx = stub_ctx(%{localities: cities(1)})
      assert {:ok, _} = Shipping.search_localities(ctx, "first")
      assert {:error, :rate_limited} = Shipping.search_localities(ctx, "second")

      other = Shipping.context(nil, provider: "uah_only")
      assert Shipping.search_localities(other, "first") != {:error, :rate_limited}
    end

    test "the limited error is not logged as a warning" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_lookup_rate, 1)
      ctx = stub_ctx(%{localities: cities(1)})
      Shipping.search_localities(ctx, "one")

      log =
        capture_log([level: :warning], fn ->
          assert {:error, :rate_limited} = Shipping.search_localities(ctx, "two")
        end)

      refute log =~ "rate_limited"
    end
  end

  describe "caching" do
    setup do
      start_supervised!(Cache)
      :ok
    end

    test "a repeated quote is served from the cache" do
      ctx = stub_ctx()

      assert {:ok, first} = Shipping.quote(ctx, request())
      assert {:ok, ^first} = Shipping.quote(ctx, request())

      assert_received {:stub_called, :quote, _}
      refute_received {:stub_called, :quote, _}
    end

    test "a different request is a different entry" do
      ctx = stub_ctx()

      Shipping.quote(ctx, request())
      Shipping.quote(ctx, request(parcels: [%Parcel{weight_g: 5000}]))

      assert_received {:stub_called, :quote, _}
      assert_received {:stub_called, :quote, _}
    end

    test "different settings do not share entries" do
      Shipping.quote(stub_ctx(), request())
      Shipping.quote(stub_ctx(%{}, settings: %{"x" => 2}), request())

      assert_received {:stub_called, :quote, _}
      assert_received {:stub_called, :quote, _}
    end

    test "a changed method price does not return the old fixed quote" do
      ctx = fn price ->
        Shipping.context(%ShippingMethod{uuid: "m1", price: Decimal.new(price), currency: "UAH"})
      end

      assert {:ok, %Quote{amount: first}} = Shipping.quote(ctx.("10"), request())
      assert {:ok, %Quote{amount: second}} = Shipping.quote(ctx.("20"), request())

      assert Decimal.equal?(first, 10)
      assert Decimal.equal?(second, 20)
    end

    test "transient errors are cached briefly" do
      ctx = stub_ctx(%{quote: {:error, :offline}})

      capture_log(fn ->
        assert {:error, :offline} = Shipping.quote(ctx, request())
        assert {:error, :offline} = Shipping.quote(ctx, request())
      end)

      assert_received {:stub_called, :quote, _}
      refute_received {:stub_called, :quote, _}
    end

    test "a timeout of a caller-specific short timeout is not cached" do
      ctx = stub_ctx(%{mode: :hang}, timeout: 30)

      capture_log(fn ->
        assert {:error, :timeout} = Shipping.quote(ctx, request())
        assert {:error, :timeout} = Shipping.quote(ctx, request())
      end)

      assert_received {:stub_called, :quote, _}
      assert_received {:stub_called, :quote, _}
    end

    test "a timeout of the default timeout is cached" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_provider_timeout, 30)
      ctx = stub_ctx(%{mode: :hang})

      capture_log(fn ->
        assert {:error, :timeout} = Shipping.quote(ctx, request())
        assert {:error, :timeout} = Shipping.quote(ctx, request())
      end)

      assert_received {:stub_called, :quote, _}
      refute_received {:stub_called, :quote, _}
    end

    test "a negative cache hit does not log the failure again" do
      ctx = stub_ctx(%{quote: {:error, :offline}})

      first = capture_log(fn -> Shipping.quote(ctx, request()) end)
      second = capture_log(fn -> assert {:error, :offline} = Shipping.quote(ctx, request()) end)

      assert first =~ "failed: :offline"
      refute second =~ "failed"
    end

    test "the negative entry expires" do
      Application.put_env(:phoenix_kit_ecommerce, :shipping_cache_ttl, negative: 1)
      on_exit(fn -> Application.delete_env(:phoenix_kit_ecommerce, :shipping_cache_ttl) end)
      ctx = stub_ctx(%{quote: {:error, :offline}})

      capture_log(fn ->
        Shipping.quote(ctx, request())
        Process.sleep(5)
        Shipping.quote(ctx, request())
      end)

      assert_received {:stub_called, :quote, _}
      assert_received {:stub_called, :quote, _}
    end

    test "business errors are not cached" do
      ctx = stub_ctx(%{quote: {:error, :too_heavy}})

      assert {:error, :too_heavy} = Shipping.quote(ctx, request())
      assert {:error, :too_heavy} = Shipping.quote(ctx, request())

      assert_received {:stub_called, :quote, _}
      assert_received {:stub_called, :quote, _}
    end

    test "crashes and timeouts are cached as transient errors" do
      ctx = stub_ctx(%{mode: :crash})

      capture_log(fn ->
        assert {:error, {:provider_crashed, _}} = Shipping.quote(ctx, request())
        assert {:error, {:provider_crashed, _}} = Shipping.quote(ctx, request())
      end)

      assert_received {:stub_called, :quote, _}
      refute_received {:stub_called, :quote, _}
    end

    test "bad returns are not cached as quotes" do
      ctx = stub_ctx(%{quote: fn _request, _ctx -> {:ok, %Quote{amount: nil}} end})

      capture_log(fn ->
        assert {:error, {:bad_return, _}} = Shipping.quote(ctx, request())
      end)

      # Whatever is cached, it is not an {:ok, _} quote.
      capture_log(fn ->
        assert {:error, {:bad_return, _}} = Shipping.quote(ctx, request())
      end)
    end

    test "lookup queries are trimmed and case-insensitive in the cache" do
      ctx = stub_ctx(%{localities: [locality()]})

      Shipping.search_localities(ctx, "Pol")
      Shipping.search_localities(ctx, "  pOL ")

      assert_received {:stub_called, :search_localities, ["Pol"]}
      refute_received {:stub_called, :search_localities, _}
    end

    test "lookups are cached" do
      ctx = stub_ctx(%{localities: [locality()], points: [StubProvider.point("p1")]})

      Shipping.search_localities(ctx, "Pol")
      Shipping.search_localities(ctx, "Pol")
      Shipping.list_pickup_points(ctx, locality(), "1")
      Shipping.list_pickup_points(ctx, locality(), "1")

      assert_received {:stub_called, :search_localities, _}
      refute_received {:stub_called, :search_localities, _}
      assert_received {:stub_called, :list_pickup_points, _}
      refute_received {:stub_called, :list_pickup_points, _}
    end

    test "the point filter runs on cached lists" do
      ctx = stub_ctx(%{points: [StubProvider.point("light", %{max_weight_g: 500})]})
      heavy = [%Parcel{weight_g: 1000}]

      assert {:ok, [_]} = Shipping.list_pickup_points(ctx, locality(), nil)
      assert {:ok, []} = Shipping.list_pickup_points(ctx, locality(), nil, parcels: heavy)

      assert_received {:stub_called, :list_pickup_points, _}
      refute_received {:stub_called, :list_pickup_points, _}
    end
  end

  describe "fits_point?/3" do
    defp fits?(limits, parcels, declared \\ nil),
      do: Shipping.fits_point?(StubProvider.point("p", limits), parcels, declared)

    test "no limits fit anything" do
      assert fits?(
               %{},
               [%Parcel{weight_g: 999_999, length_mm: 9999, width_mm: 9999, height_mm: 9999}],
               Decimal.new(1_000_000)
             )
    end

    test "weight" do
      assert fits?(%{max_weight_g: 1000}, [%Parcel{weight_g: 1000}])
      refute fits?(%{max_weight_g: 1000}, [%Parcel{weight_g: 1001}])
      refute fits?(%{max_weight_g: 1000}, [%Parcel{weight_g: 100}, %Parcel{weight_g: 1001}])
    end

    test "dimensions compare sorted sides" do
      limits = %{max_dims_mm: [600, 400, 300]}

      assert fits?(limits, [%Parcel{length_mm: 300, width_mm: 600, height_mm: 400}])
      assert fits?(limits, [%Parcel{length_mm: 100, width_mm: 100, height_mm: 100}])
      refute fits?(limits, [%Parcel{length_mm: 601, width_mm: 10, height_mm: 10}])
      refute fits?(limits, [%Parcel{length_mm: 500, width_mm: 500, height_mm: 10}])
    end

    test "dimensions of a point are sorted too" do
      assert fits?(%{max_dims_mm: [300, 600, 400]}, [
               %Parcel{length_mm: 600, width_mm: 400, height_mm: 300}
             ])
    end

    test "unknown parcel dimensions never disqualify" do
      assert fits?(%{max_dims_mm: [10, 10, 10]}, [%Parcel{weight_g: 100}])

      assert fits?(%{max_dims_mm: [10, 10, 10]}, [
               %Parcel{length_mm: 500, width_mm: nil, height_mm: 5}
             ])
    end

    test "declared value" do
      limits = %{max_declared: Decimal.new("500")}

      assert fits?(limits, [], Decimal.new("500"))
      refute fits?(limits, [], Decimal.new("500.01"))
      assert fits?(limits, [], nil)
    end

    test "limits combine" do
      limits = %{max_weight_g: 1000, max_declared: Decimal.new("100")}

      assert fits?(limits, [%Parcel{weight_g: 500}], Decimal.new("100"))
      refute fits?(limits, [%Parcel{weight_g: 500}], Decimal.new("101"))
      refute fits?(limits, [%Parcel{weight_g: 5000}], Decimal.new("1"))
    end

    test "no parcels pass the weight and dimension limits" do
      assert fits?(%{max_weight_g: 1, max_dims_mm: [1, 1, 1]}, [])
    end

    test "something that is not a point fits" do
      assert Shipping.fits_point?(nil, [%Parcel{weight_g: 1}], nil)
      assert Shipping.fits_point?(%PickupPoint{limits: nil}, [%Parcel{weight_g: 1}], nil)
    end
  end

  describe "request_hash/1" do
    test "is a stable 32 character hex string" do
      hash = Shipping.request_hash(request())

      assert hash =~ ~r/\A[0-9a-f]{32}\z/
      assert hash == Shipping.request_hash(request())
    end

    test "equal requests built differently hash alike" do
      one =
        request(
          origin: %{"a" => 1, "b" => %{"c" => 2}},
          declared_value: Decimal.new("100.00"),
          cod_amount: Decimal.new("5.50")
        )

      two =
        request(
          origin: %{b: %{c: 2}, a: 1},
          declared_value: Decimal.new("100"),
          cod_amount: Decimal.new("5.5")
        )

      assert Shipping.request_hash(one) == Shipping.request_hash(two)
    end

    test "ignores everything about a locality or point but its id" do
      one = request(destination: %Destination{locality: %Locality{id: "c1", name: "Old name"}})
      two = request(destination: %Destination{locality: %Locality{id: "c1", name: "New name"}})

      assert Shipping.request_hash(one) == Shipping.request_hash(two)
    end

    test "is sensitive to every part of the request" do
      base = request()
      hash = Shipping.request_hash(base)

      variants = [
        request(service: "courier"),
        request(origin: %{"sender" => "x"}),
        request(destination: %Destination{locality: %Locality{id: "c2"}}),
        request(destination: %Destination{pickup_point: %PickupPoint{id: "p1"}}),
        request(destination: %Destination{address: %Address{street: "Main"}}),
        request(parcels: [%Parcel{weight_g: 1001}]),
        request(parcels: [%Parcel{weight_g: 1000, length_mm: 10, width_mm: 10, height_mm: 10}]),
        request(parcels: [%Parcel{weight_g: 1000}, %Parcel{weight_g: 1000}]),
        request(declared_value: Decimal.new("101")),
        request(cod_amount: Decimal.new("100")),
        request(currency: "USD")
      ]

      hashes = Enum.map(variants, &Shipping.request_hash/1)

      refute hash in hashes
      assert hashes == Enum.uniq(hashes)
    end
  end
end
