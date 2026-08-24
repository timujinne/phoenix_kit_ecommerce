defmodule PhoenixKitEcommerce.ModuleCallbacksTest do
  @moduledoc """
  Pins the `PhoenixKit.Module` callbacks this module contributes to its host.

  These exist because `css_sources/0` was documented in both README.md and
  AGENTS.md as implemented, and was not. The failure was invisible: core's
  `:phoenix_kit_css_sources` compiler collects the callback from every
  discovered module, and only warns when the TOTAL list is empty — so any
  other installed module masked the absence, while Tailwind quietly purged
  every class used only by this module's templates from the host build.

  A one-line assertion would have caught it, so here is the one line.
  """
  use ExUnit.Case, async: true

  test "css_sources/0 contributes this app to the host Tailwind build" do
    assert PhoenixKitEcommerce.css_sources() == [:phoenix_kit_ecommerce]
  end

  test "module_key/0 matches what the permission and tabs declare" do
    # Every tab guards either the base key or one of THIS module's declared
    # sub-permissions. If a tab's key drifts outside that set, the sidebar
    # and the actual gate disagree: the page hides but stays reachable, or
    # shows and then denies.
    assert PhoenixKitEcommerce.module_key() == "shop"

    valid = valid_permission_keys()

    for tab <- PhoenixKitEcommerce.admin_tabs() do
      assert tab.permission in valid,
             "tab #{inspect(tab.id)} guards #{inspect(tab.permission)}, " <>
               "which is neither the base key nor a declared sub-permission"
    end
  end

  test "every declared sub-permission is actually used by a tab or the Authz layer" do
    # A declared-but-unenforced capability is worse than none: it shows up
    # in the admin permission matrix, an operator grants or withholds it,
    # and nothing changes.
    %{sub_permissions: subs} = PhoenixKitEcommerce.permission_metadata()

    tab_keys = PhoenixKitEcommerce.admin_tabs() |> Enum.map(& &1.permission) |> MapSet.new()

    authz_sources =
      Path.wildcard("lib/phoenix_kit_ecommerce/web/*.ex")
      |> Enum.map_join("\n", &File.read!/1)

    for %{key: key} <- subs do
      full = "shop.#{key}"

      assert MapSet.member?(tab_keys, full) or authz_sources =~ ":#{key}",
             "sub-permission #{inspect(full)} is declared but never enforced"
    end
  end

  defp valid_permission_keys do
    meta = PhoenixKitEcommerce.permission_metadata()

    MapSet.new([meta.key | Enum.map(meta.sub_permissions, &"#{meta.key}.#{&1.key}")])
  end

  test "required_modules/0 names billing, which this module hard-depends on" do
    # Order and invoice creation route through PhoenixKitBilling; declaring it
    # is what stops a host enabling shop without it.
    assert "billing" in PhoenixKitEcommerce.required_modules()
  end

  test "version/0 reports the app version rather than a placeholder" do
    refute PhoenixKitEcommerce.version() == "0.0.0"
  end

  test "required_integrations/0 names shopify" do
    assert "shopify" in PhoenixKitEcommerce.required_integrations()
  end

  test "integration_providers/0 registers the Shopify provider with credentials auth" do
    assert [provider] = PhoenixKitEcommerce.integration_providers()

    assert provider.key == "shopify"
    assert provider.auth_type == :credentials

    field_keys = Enum.map(provider.setup_fields, & &1.key)
    assert "shop_domain" in field_keys
    assert "access_token" in field_keys

    access_token_field = Enum.find(provider.setup_fields, &(&1.key == "access_token"))
    assert access_token_field.required
    assert access_token_field.type == :password
  end
end
