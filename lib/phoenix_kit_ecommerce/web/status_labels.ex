defmodule PhoenixKitEcommerce.Web.StatusLabels do
  @moduledoc """
  Translated labels for the status values this module stores and renders.

  A status is stored as its raw value (`"pending"`, `"active"`) and that value
  keys badge classes, filters and audit metadata — it is never what a person
  reads. Every page that shows one calls the function for its family here.

  Each value is its own `gettext/1` literal so the extractor sees it. A value
  no clause knows (a status added by a newer billing or AI package) is shown
  humanized rather than dropped; anything that is not a string renders as an
  empty label.
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  @doc """
  Label for a billing order status. Billing's own `Order.status_label/1`
  returns untranslated English, so the storefront keeps its own clauses.
  """
  @spec order(term()) :: String.t()
  def order("draft"), do: gettext("Draft")
  def order("pending"), do: gettext("Pending")
  def order("confirmed"), do: gettext("Confirmed")
  def order("paid"), do: gettext("Paid")
  def order("processing"), do: gettext("Processing")
  def order("shipped"), do: gettext("Shipped")
  def order("delivered"), do: gettext("Delivered")
  def order("completed"), do: gettext("Completed")
  def order("cancelled"), do: gettext("Cancelled")
  def order("refunded"), do: gettext("Refunded")
  def order(status), do: fallback(status)

  @doc "Label for a `Product` status."
  @spec product(term()) :: String.t()
  def product("draft"), do: gettext("Draft")
  def product("active"), do: gettext("Active")
  def product("archived"), do: gettext("Archived")
  def product(status), do: fallback(status)

  @doc "Label for a `Category` status. A category without one is active."
  @spec category(term()) :: String.t()
  def category(nil), do: gettext("Active")
  def category("active"), do: gettext("Active")
  def category("unlisted"), do: gettext("Unlisted")
  def category("hidden"), do: gettext("Hidden")
  def category(status), do: fallback(status)

  @doc "Label for a `Cart` status."
  @spec cart(term()) :: String.t()
  def cart("active"), do: gettext("Active")
  def cart("merged"), do: gettext("Merged")
  def cart("converted"), do: gettext("Converted")
  def cart("abandoned"), do: gettext("Abandoned")
  def cart("expired"), do: gettext("Expired")
  def cart(status), do: fallback(status)

  @doc "Label for an `ImportLog` status."
  @spec import(term()) :: String.t()
  def import("pending"), do: gettext("Pending")
  def import("processing"), do: gettext("Processing")
  def import("completed"), do: gettext("Completed")
  def import("failed"), do: gettext("Failed")
  def import(status), do: fallback(status)

  @doc "Label for the status of an AI request log entry on the translations page."
  @spec translation_entry(term()) :: String.t()
  def translation_entry("success"), do: gettext("Success")
  def translation_entry("error"), do: gettext("Error")
  def translation_entry("timeout"), do: gettext("Timeout")
  def translation_entry(status), do: fallback(status)

  defp fallback(status) when is_binary(status) do
    status |> String.replace("_", " ") |> String.capitalize()
  end

  defp fallback(_status), do: ""
end
