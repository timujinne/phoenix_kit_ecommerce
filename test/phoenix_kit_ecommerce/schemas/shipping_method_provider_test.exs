defmodule PhoenixKitEcommerce.Schemas.ShippingMethodProviderTest do
  # Changes application env (the provider registry), so not async.
  use PhoenixKitEcommerce.DataCase, async: false

  import ExUnit.CaptureLog

  alias PhoenixKitEcommerce.Shipping.MethodConfig
  alias PhoenixKitEcommerce.ShippingMethod
  alias PhoenixKitEcommerce.Test.Shipping.StubProvider

  defmodule Plain do
    @moduledoc false
    @behaviour PhoenixKitEcommerce.Shipping.Provider

    alias PhoenixKitEcommerce.Shipping.Service

    @impl true
    def key, do: "plain"
    @impl true
    def label, do: "Plain"
    @impl true
    def services(ctx) do
      if pid = Process.whereis(:shipping_timeout_probe),
        do: send(pid, {:services_timeout, ctx.opts[:timeout]})

      [%Service{key: "home", label: "Home", destination: :address}]
    end

    @impl true
    def settings_fields, do: []
    @impl true
    def quote(_request, _ctx), do: {:error, :no_rates}
  end

  @valid %{"name" => "Carrier", "price" => "5.00"}
  @city %{"id" => "c1", "name" => "Poltava"}

  setup do
    previous = Application.get_env(:phoenix_kit_ecommerce, :shipping_providers)
    Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, [StubProvider, Plain])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:phoenix_kit_ecommerce, :shipping_providers, previous),
        else: Application.delete_env(:phoenix_kit_ecommerce, :shipping_providers)
    end)
  end

  defp changeset(provider, attrs \\ %{}, method \\ %ShippingMethod{}) do
    attrs = attrs |> Map.merge(@valid) |> Map.put("shipping_provider", provider)
    ShippingMethod.changeset(method, attrs)
  end

  defp stub(overrides \\ %{}) do
    Map.merge(
      %{"provider" => "stub", "service" => "branch", "settings" => %{"sender_city" => @city}},
      overrides
    )
  end

  defp block(changeset), do: get_field(changeset, :metadata)["shipping_provider"]

  describe "merging into metadata" do
    test "a valid block is stored under metadata[\"shipping_provider\"]" do
      cs = changeset(stub())

      assert cs.valid?

      assert block(cs) == %{
               "provider" => "stub",
               "service" => "branch",
               "settings" => %{"sender_city" => @city}
             }

      assert ShippingMethod.calculated?(apply_changes(cs))
    end

    test "atom keys work as well" do
      attrs = %{
        name: "Carrier",
        price: "5.00",
        shipping_provider: %{
          provider: "stub",
          service: "courier",
          settings: %{sender_city: %{id: "c1", name: "Poltava"}}
        }
      }

      cs = ShippingMethod.changeset(%ShippingMethod{}, attrs)

      assert cs.valid?
      assert %{"provider" => "stub", "service" => "courier"} = block(cs)
    end

    test "other metadata keys survive" do
      method = %ShippingMethod{metadata: %{"carrier" => "np", "pay_on_delivery" => true}}
      cs = changeset(stub(), %{}, method)

      assert get_field(cs, :metadata)["carrier"] == "np"
      assert get_field(cs, :metadata)["pay_on_delivery"] == true
      assert block(cs)["provider"] == "stub"
    end

    test "an absent param leaves the existing block alone" do
      method = %ShippingMethod{metadata: %{"shipping_provider" => stub()}}
      cs = ShippingMethod.changeset(method, @valid)

      assert cs.valid?
      refute Map.has_key?(cs.changes, :metadata)
      assert block(cs) == stub()
    end

    test "an empty provider removes the block and keeps the other keys" do
      method = %ShippingMethod{metadata: %{"carrier" => "np", "shipping_provider" => stub()}}
      cs = changeset(%{"provider" => ""}, %{}, method)

      assert cs.valid?
      assert get_field(cs, :metadata) == %{"carrier" => "np"}
      refute ShippingMethod.calculated?(apply_changes(cs))
    end

    test "fixed without settings removes the block" do
      method = %ShippingMethod{metadata: %{"shipping_provider" => stub()}}

      assert get_field(changeset(%{"provider" => "fixed"}, %{}, method), :metadata) == %{}
    end

    test "fixed with only its default settings and no service removes the block" do
      method = %ShippingMethod{metadata: %{"shipping_provider" => stub()}}

      for settings <- [%{"destination" => "none"}, %{"destination" => " none "}, %{}] do
        cs = changeset(%{"provider" => "fixed", "settings" => settings}, %{}, method)

        assert cs.valid?
        assert get_field(cs, :metadata) == %{}
      end
    end

    test "a param that is not a map is an error, not a silent removal" do
      method = %ShippingMethod{metadata: %{"shipping_provider" => stub()}}

      for param <- [nil, "stub", ["stub"], 1] do
        cs = changeset(param, %{}, method)

        refute cs.valid?, "expected #{inspect(param)} to be rejected"
        assert %{shipping_provider: [_]} = errors_on(cs)
      end
    end

    test "fixed with settings keeps the block" do
      cs =
        changeset(%{
          "provider" => "fixed",
          "service" => "default",
          "settings" => %{"destination" => "address"}
        })

      assert cs.valid?
      assert %{"provider" => "fixed", "settings" => %{"destination" => "address"}} = block(cs)
      refute ShippingMethod.calculated?(apply_changes(cs))
    end

    test "blank settings values are dropped" do
      cs = changeset(%{"provider" => "fixed", "settings" => %{"destination" => ""}})

      assert cs.valid?
      assert get_field(cs, :metadata) == %{}
    end
  end

  describe "provider validation" do
    test "an unknown provider is an error on :shipping_provider" do
      cs = changeset(stub(%{"provider" => "nope"}))

      refute cs.valid?
      assert %{shipping_provider: [message]} = errors_on(cs)
      assert message =~ "unknown provider"
      refute Map.has_key?(cs.changes, :metadata)
    end

    test "an unknown service of a provider without credentials is an error" do
      cs = changeset(%{"provider" => "plain", "service" => "teleport"})

      assert %{shipping_provider: [message]} = errors_on(cs)
      assert message =~ "unknown service"
      assert message =~ "teleport"
      assert changeset(%{"provider" => "plain", "service" => "home"}).valid?
    end

    test "user text stays out of the message and travels in the error bindings" do
      cs = changeset(%{"provider" => "plain", "service" => "te%{x}st"})

      assert [{message, opts}] = Keyword.get_values(cs.errors, :shipping_provider)
      assert message == "unknown service %{service}"
      assert opts[:service] == "te%{x}st"

      cs = changeset(stub(%{"provider" => "no%{y}pe"}))

      assert [{"unknown provider %{provider}", opts}] =
               Keyword.get_values(cs.errors, :shipping_provider)

      assert opts[:provider] == "no%{y}pe"
    end

    test "a service the credential-less list lacks is accepted for a provider with credentials" do
      cs = changeset(stub(%{"service" => "teleport"}))

      assert cs.valid?
      assert block(cs)["service"] == "teleport"
    end

    test "a provider that lists no services is accepted" do
      StubProvider.put(%{services: []})

      assert changeset(stub(%{"service" => "anything"})).valid?
    end

    test "services are asked for with a short timeout" do
      Process.register(self(), :shipping_timeout_probe)

      assert changeset(%{"provider" => "plain", "service" => "home"}).valid?
      assert_received {:services_timeout, 2_000}
    end

    test "a hanging provider does not block saving" do
      StubProvider.put(%{mode: :hang})

      capture_log(fn -> assert changeset(stub(%{"service" => "x"})).valid? end)
    end

    test "a missing service is an error when the provider offers services" do
      cs = changeset(stub(%{"service" => ""}))

      assert %{shipping_provider: ["service is required"]} = errors_on(cs)
    end

    test "services that cannot be listed do not block saving" do
      StubProvider.put(%{mode: :crash})

      log =
        capture_log(fn ->
          cs = changeset(stub(%{"service" => "anything"}))
          assert cs.valid?
          assert block(cs)["service"] == "anything"
        end)

      assert log =~ "failed"
    end

    test "a missing required setting is an error" do
      cs = changeset(stub(%{"settings" => %{}}))

      assert %{shipping_provider: [message]} = errors_on(cs)
      assert message =~ "sender_city"
    end

    test "a locality setting needs an id and a name" do
      for city <- [
            %{"id" => "c1"},
            %{"name" => "Poltava"},
            "Poltava",
            %{"id" => "", "name" => ""}
          ] do
        cs = changeset(stub(%{"settings" => %{"sender_city" => city}}))
        refute cs.valid?, "expected #{inspect(city)} to be rejected"
      end
    end

    test "a built-in provider validates its own required settings" do
      cs = changeset(%{"provider" => "table", "service" => "default", "settings" => %{}})
      assert %{shipping_provider: [message]} = errors_on(cs)
      assert message =~ "rates"

      cs =
        changeset(%{
          "provider" => "table",
          "service" => "default",
          "settings" => %{"rates" => "1 50"}
        })

      assert cs.valid?
    end
  end

  describe "pricing" do
    test "numbers are stored as normalised strings" do
      pricing = %{"markup_percent" => "10", "markup_fixed" => "2,50", "round_to" => "5"}
      cs = changeset(stub(%{"pricing" => pricing}))

      assert cs.valid?

      assert block(cs)["pricing"] == %{
               "markup_percent" => "10",
               "markup_fixed" => "2.5",
               "round_to" => "5"
             }

      config = ShippingMethod.shipping_config(apply_changes(cs))
      assert %MethodConfig{provider: "stub", service: "branch"} = config
      assert Decimal.equal?(config.pricing.markup_fixed, "2.5")
    end

    test "blank pricing inputs are left out" do
      cs = changeset(stub(%{"pricing" => %{"markup_percent" => "", "round_to" => " "}}))

      assert cs.valid?
      refute Map.has_key?(block(cs), "pricing")
    end

    test "zero markups are fine" do
      cs = changeset(stub(%{"pricing" => %{"markup_percent" => "0", "markup_fixed" => 0}}))
      assert cs.valid?
    end

    test "negative zero is stored as zero" do
      cs = changeset(stub(%{"pricing" => %{"markup_percent" => "-0", "markup_fixed" => "0.00"}}))

      assert cs.valid?
      assert block(cs)["pricing"] == %{"markup_percent" => "0", "markup_fixed" => "0"}
    end

    test "magnitudes are capped" do
      assert changeset(stub(%{"pricing" => %{"markup_fixed" => "1000000"}})).valid?

      for key <- ["markup_percent", "markup_fixed", "round_to"] do
        cs = changeset(stub(%{"pricing" => %{key => "1000001"}}))
        assert %{shipping_provider: [message]} = errors_on(cs)
        assert message =~ "at most"

        refute changeset(stub(%{"pricing" => %{key => "1e30"}})).valid?
      end
    end

    test "negative markups are errors" do
      for key <- ["markup_percent", "markup_fixed"] do
        cs = changeset(stub(%{"pricing" => %{key => "-1"}}))
        assert %{shipping_provider: [message]} = errors_on(cs)
        assert message =~ key
      end
    end

    test "round_to must be positive" do
      for value <- ["0", "-5"] do
        cs = changeset(stub(%{"pricing" => %{"round_to" => value}}))
        assert %{shipping_provider: [message]} = errors_on(cs)
        assert message =~ "round_to"
      end
    end

    test "garbage is not a number" do
      cs = changeset(stub(%{"pricing" => %{"markup_percent" => "ten"}}))
      assert %{shipping_provider: [message]} = errors_on(cs)
      assert message =~ "must be a number"
    end

    test "every problem is reported" do
      pricing = %{"markup_percent" => "-1", "markup_fixed" => "-2", "round_to" => "0"}
      cs = changeset(stub(%{"pricing" => pricing, "settings" => %{}}))

      assert %{shipping_provider: messages} = errors_on(cs)
      assert length(messages) == 4
    end
  end

  describe "pay on delivery with a calculated provider" do
    test "the shop still charges nothing" do
      cs =
        changeset(stub(), %{
          "pay_on_delivery" => "true",
          "price" => "9.00",
          "free_above_amount" => "100"
        })

      assert cs.valid?
      method = apply_changes(cs)

      assert Decimal.equal?(method.price, 0)
      assert method.free_above_amount == nil
      assert ShippingMethod.pay_on_delivery?(method)
      assert ShippingMethod.calculated?(method)

      assert %{"pay_on_delivery" => true, "shipping_provider" => %{"provider" => "stub"}} =
               method.metadata
    end

    test "dropping the flag keeps the provider, dropping the provider keeps the flag" do
      method = %ShippingMethod{
        price: Decimal.new(0),
        metadata: %{"pay_on_delivery" => true, "shipping_provider" => stub()}
      }

      cs = ShippingMethod.changeset(method, %{"pay_on_delivery" => "false", "price" => "4"})
      assert block(cs)["provider"] == "stub"
      refute ShippingMethod.pay_on_delivery?(apply_changes(cs))

      cs = changeset(%{"provider" => ""}, %{}, method)
      assert ShippingMethod.pay_on_delivery?(apply_changes(cs))
      refute ShippingMethod.calculated?(apply_changes(cs))
    end
  end

  describe "shipping_config/1 and calculated?/1" do
    test "a method without a block is fixed" do
      method = %ShippingMethod{}

      assert %MethodConfig{provider: "fixed"} = ShippingMethod.shipping_config(method)
      refute ShippingMethod.calculated?(method)
    end

    test "nil is fixed too" do
      assert %MethodConfig{provider: "fixed"} = ShippingMethod.shipping_config(nil)
      refute ShippingMethod.calculated?(nil)
    end
  end
end
