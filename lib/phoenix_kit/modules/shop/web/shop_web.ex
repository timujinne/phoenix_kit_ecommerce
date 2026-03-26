defmodule PhoenixKit.Modules.Shop.Web do
  @moduledoc """
  Provides common imports and setup for Shop module LiveViews.

  Usage:
      use PhoenixKit.Modules.Shop.Web, :live_view
  """

  def live_view do
    quote do
      use Phoenix.LiveView
      use Gettext, backend: PhoenixKitWeb.Gettext

      import Phoenix.HTML
      import Phoenix.HTML.Form
      import Phoenix.LiveView.Helpers

      alias PhoenixKit.Utils.Routes
      import PhoenixKitWeb.LayoutHelpers, only: [dashboard_assigns: 1]

      import PhoenixKitWeb.Components.Core.Button
      import PhoenixKitWeb.Components.Core.Flash
      import PhoenixKitWeb.Components.Core.Header
      import PhoenixKitWeb.Components.Core.Icon
      import PhoenixKitWeb.Components.Core.FormFieldLabel
      import PhoenixKitWeb.Components.Core.FormFieldError
      import PhoenixKitWeb.Components.Core.Input
      import PhoenixKitWeb.Components.Core.Textarea
      import PhoenixKitWeb.Components.Core.Select
      import PhoenixKitWeb.Components.Core.Checkbox
      import PhoenixKitWeb.Components.Core.SimpleForm
      import PhoenixKitWeb.Components.Core.ThemeSwitcher
      import PhoenixKitWeb.Components.Core.Badge
      import PhoenixKitWeb.Components.Core.StatCard
      import PhoenixKitWeb.Components.Core.EmailStatusBadge
      import PhoenixKitWeb.Components.Core.TimeDisplay
      import PhoenixKitWeb.Components.Core.EventTimelineItem
      import PhoenixKitWeb.Components.Core.UserInfo
      import PhoenixKitWeb.Components.Core.Pagination
      import PhoenixKitWeb.Components.Core.FileDisplay
      import PhoenixKitWeb.Components.Core.NumberFormatter
      import PhoenixKitWeb.Components.Core.TableDefault
      import PhoenixKitWeb.Components.Core.TableRowMenu
      import PhoenixKitWeb.Components.Core.Accordion
      import PhoenixKitWeb.Components.Core.FileUpload
      import PhoenixKitWeb.Components.Core.MarkdownContent
      import PhoenixKitWeb.Components.Core.PkLink
      import PhoenixKitWeb.Components.Core.Modal
      import PhoenixKitWeb.Components.Core.MediaThumbnail
      import PhoenixKitWeb.Components.Core.AdminPageHeader
      import PhoenixKitWeb.Components.Core.DraggableList
      import PhoenixKitWeb.Components.Core.Markdown
    end
  end

  def live_component do
    quote do
      use Phoenix.LiveComponent
      use Gettext, backend: PhoenixKitWeb.Gettext

      import Phoenix.HTML
      import Phoenix.HTML.Form

      alias PhoenixKit.Utils.Routes

      import PhoenixKitWeb.Components.Core.Button
      import PhoenixKitWeb.Components.Core.Flash
      import PhoenixKitWeb.Components.Core.Icon
      import PhoenixKitWeb.Components.Core.Input
      import PhoenixKitWeb.Components.Core.Select
      import PhoenixKitWeb.Components.Core.SimpleForm
      import PhoenixKitWeb.Components.Core.Badge
      import PhoenixKitWeb.Components.Core.Modal
      import PhoenixKitWeb.Components.Core.PkLink
    end
  end

  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
