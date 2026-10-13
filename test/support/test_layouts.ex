defmodule PhoenixKitEcommerce.Test.Layouts do
  @moduledoc """
  Minimal layouts for the LiveView test endpoint. Real layouts live in
  the host app and the phoenix_kit core — these just wrap LiveView
  content in an HTML shell so Phoenix.LiveViewTest can render it.

  `app/1` renders flash divs so smoke tests can assert flash content
  via `render(view) =~ "Saved."` after click events. Without these,
  Phoenix.Flash.get/2 returns the message but it never reaches the
  rendered HTML, and tests fall back to "process alive" tautologies.

  `root/1` renders the storefront's `og`, `canonical_url` and
  `hreflang_links` assigns into `<head>` the way a host layout has to, so
  a test can assert the page still supplies them.
  """

  use Phoenix.Component

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Test</title>
        <%!-- What a host's root layout does with the storefront's SEO assigns.
              Core's own root layout reads `og` only. --%>
        <%= if og = assigns[:og] do %>
          <meta :if={og[:type]} property="og:type" content={og[:type]} />
          <meta :if={og[:title]} property="og:title" content={og[:title]} />
          <meta :if={og[:url]} property="og:url" content={og[:url]} />
          <meta :if={og[:locale]} property="og:locale" content={og[:locale]} />
        <% end %>
        <link :if={assigns[:canonical_url]} rel="canonical" href={assigns[:canonical_url]} />
        <link
          :for={link <- assigns[:hreflang_links] || []}
          rel="alternate"
          hreflang={link.code}
          href={link.url}
        />
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  def app(assigns) do
    ~H"""
    <%!-- Ids are namespaced: core's LayoutWrapper renders the REAL flash inside
          the LiveView tree, and a bare `flash-error` here collides with it —
          LiveView aborts a test on a duplicate id. Same reason root.html.heex
          deliberately carries no flash. --%>
    <div id="test-flashes">
      <div :if={msg = Phoenix.Flash.get(@flash, :info)} id="test-flash-info" data-flash-kind="info">
        {msg}
      </div>
      <div :if={msg = Phoenix.Flash.get(@flash, :error)} id="test-flash-error" data-flash-kind="error">
        {msg}
      </div>
      <div
        :if={msg = Phoenix.Flash.get(@flash, :warning)}
        id="test-flash-warning"
        data-flash-kind="warning"
      >
        {msg}
      </div>
    </div>
    {@inner_content}
    """
  end

  # Phoenix's error pipeline will try to render "<status>.html" from the
  # layouts module if a LiveView raises during mount. Forward everything
  # to a single generic template so tests get a readable error instead
  # of a `no template defined` crash.
  def render(_template, assigns) do
    ~H"""
    <html>
      <body>
        <h1>Error</h1>
        <pre>{inspect(assigns[:reason] || assigns[:conn])}</pre>
      </body>
    </html>
    """
  end
end
