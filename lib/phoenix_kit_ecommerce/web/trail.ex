defmodule PhoenixKitEcommerce.Web.Trail do
  @moduledoc """
  The admin header trail of the shop's admin pages.

  Core's header bar draws `Admin Panel / page_section / crumb… / page_title`
  from four socket assigns; a page only says where it is. Every admin page
  below the E-Commerce landing page (`/admin/shop`) carries the module as its
  section, the list a record belongs to as a crumb, and itself alone as the
  title — `Edit`, `New product`, the record's name — never a trail of its own.

  `assign_shop_trail/3` sets the section and the crumbs for one page; the
  `*_crumb/0` helpers are the list pages a record or form sits under.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias PhoenixKit.Utils.Routes

  @doc """
  Assigns the header trail of a page under the E-Commerce landing page.

  `title` is the page alone; `crumbs` are every level between the module and
  the page, top down, as `%{label: _, path: _}` maps (see `crumb/2`).
  """
  @spec assign_shop_trail(Phoenix.LiveView.Socket.t(), String.t(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def assign_shop_trail(socket, title, crumbs \\ []) do
    socket
    |> assign(:page_section, gettext("E-Commerce"))
    |> assign(:page_section_path, Routes.path("/admin/shop"))
    |> assign(:page_crumbs, crumbs)
    |> assign(:page_title, title)
  end

  @doc """
  One crumb. Without a `path` it renders as text — only for a level that has
  no page of its own (a category or shipping method, whose list is their
  only page).
  """
  @spec crumb(String.t(), String.t() | nil) :: map()
  def crumb(label, path \\ nil), do: %{label: label, path: path}

  def products_crumb, do: crumb(gettext("Products"), Routes.path("/admin/shop/products"))
  def categories_crumb, do: crumb(gettext("Categories"), Routes.path("/admin/shop/categories"))
  def shipping_crumb, do: crumb(gettext("Shipping"), Routes.path("/admin/shop/shipping"))
  def imports_crumb, do: crumb(gettext("CSV Import"), Routes.path("/admin/shop/imports"))
  def settings_crumb, do: crumb(gettext("Settings"), Routes.path("/admin/shop/settings"))
end
