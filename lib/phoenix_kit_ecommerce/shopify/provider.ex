defmodule PhoenixKitEcommerce.Shopify.Provider do
  @moduledoc """
  `PhoenixKit.Integrations` provider definition for Shopify.

  Registered via `PhoenixKitEcommerce.integration_providers/0`.

  ## Why a static access token instead of OAuth

  Core's generic OAuth callback (`PhoenixKit.Integrations.OAuth`, the
  `IntegrationForm` LiveView) does not verify Shopify's HMAC callback
  parameter, so wiring Shopify through it would inherit a real security gap.
  Shopify's own recommended path for a single-store integration avoids OAuth
  entirely: the store owner creates a Custom App directly in Shopify Admin
  (Settings → Apps and sales channels → Develop apps), grants it Admin API
  scopes, installs it, and gets a static Admin API access token — no
  handshake needed. This provider models that: `auth_type: :credentials`
  (the same shape "Universal SMTP" and AWS SES use) with two fields,
  `shop_domain` and `access_token`. The field must be named `access_token`
  (not e.g. `api_key`) because `PhoenixKit.Integrations.Encryption`
  auto-encrypts by a fixed field-name list.

  ## Known limitation: "Test Connection" is a no-op

  The generic integrations page's "Test Connection" button only checks a
  connection for providers that declare a `:validation` strategy — the
  strategy dispatch in `PhoenixKit.Integrations.do_validate/2` is hardcoded
  in core and not externally extensible. This provider deliberately omits
  `:validation`, so "Test Connection" always reports success without
  actually checking anything. The real connectivity check is the sync
  feature itself (`PhoenixKitEcommerce.Shopify.Sync.check/2`), which either
  fetches products successfully or surfaces a real error.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  @doc "The Shopify provider definition."
  @spec definition() :: map()
  def definition do
    %{
      key: "shopify",
      name: gettext("Shopify"),
      description: gettext("Sync product data from a Shopify store (read-only)"),
      icon: "hero-shopping-bag",
      auth_type: :credentials,
      oauth_config: nil,
      # System-wide only — one Shopify store connection per installation,
      # not a per-user credential.
      scopes: [:system],
      setup_fields: [
        %{
          key: "shop_domain",
          label: gettext("Shop domain"),
          type: :text,
          required: true,
          placeholder: "my-store.myshopify.com",
          help: gettext("Your Shopify store's *.myshopify.com domain"),
          options: nil
        },
        %{
          key: "access_token",
          label: gettext("Admin API access token"),
          type: :password,
          required: true,
          placeholder: "shpat_...",
          help:
            gettext(
              "From your store's Custom App (Settings → Apps and sales channels → Develop apps) — needs the read_products scope"
            ),
          options: nil
        }
      ],
      capabilities: [:shopify_products],
      instructions: [
        %{
          title: gettext("Create a Custom App in Shopify"),
          steps: [
            {gettext(
               "In your Shopify admin, go to **Settings → Apps and sales channels → Develop apps**"
             ), nil},
            {gettext(
               "Click **Allow custom app development** if prompted, then **Create an app**"
             ), nil},
            {gettext("Give it a name (e.g. \"PhoenixKit sync\")"), nil}
          ]
        },
        %{
          title: gettext("Configure Admin API scopes"),
          steps: [
            {gettext(
               "Open the app, go to **Configuration**, and click **Configure** under Admin API scopes"
             ), nil},
            {gettext("Enable **read_products** — no other scope is needed for this integration"),
             nil},
            {gettext("Click **Save**"), nil}
          ]
        },
        %{
          title: gettext("Install the app and copy the token"),
          steps: [
            {gettext("Go to **API credentials** and click **Install app**"), nil},
            {gettext(
               "Copy the **Admin API access token** (shown once) and paste it into the form above, along with your shop's `*.myshopify.com` domain"
             ), nil}
          ],
          note:
            gettext(
              "This is a static token, not OAuth — Shopify's own recommended path for a single-store custom app. \"Test Connection\" on this page is a no-op for Shopify (no validation strategy is registered); use the sync feature's own connectivity check instead."
            )
        }
      ]
    }
  end
end
