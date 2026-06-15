defmodule PhoenixKitEcommerce.Errors do
  @moduledoc """
  Central mapping from the error atoms returned by the e-commerce module's
  context, importers, image services, and web layer to translated
  human-readable strings.

  Keeping the API layer locale-agnostic means callers and integration
  consumers can pattern-match on atoms and decide their own presentation.
  Anything user-facing (flash messages, error banners) goes through
  `message/1`, which wraps each mapping in `gettext/1` using the module's
  own `PhoenixKitEcommerce.Gettext` backend so the strings are extractable
  into `priv/gettext`.

  ## Supported reason shapes

    * plain atoms — `:not_found`, `:cart_empty`, `:product_not_found`, etc.
    * strings — passed through unchanged (legacy / interpolated messages)
    * anything else — rendered as `"Unexpected error: <inspect>"` so
      nothing silently surfaces a raw struct

  ## Example

      iex> PhoenixKitEcommerce.Errors.message(:cart_empty)
      "The cart is empty."
  """

  use Gettext, backend: PhoenixKitEcommerce.Gettext

  @type error ::
          :all_downloads_failed
          | :all_urls_invalid
          | :already_migrated
          | :cart_already_converting
          | :cart_empty
          | :cart_not_active
          | :email_already_registered
          | :email_exists_confirmed
          | :empty_file
          | :file_not_found
          | :forbidden
          | :import_log_not_found
          | :invalid_csv_format
          | :invalid_host
          | :invalid_scheme
          | :missing_content_type
          | :missing_slug
          | :missing_title
          | :no_images
          | :no_images_downloaded
          | :no_shipping_method
          | :not_found
          | :payment_option_not_found
          | :product_not_found
          | :rate_limited
          | :redirect_loop
          | :server_error
          | :temp_file_missing
          | :timeout
          | :unknown_format

  @doc """
  Translates an error reason (atom, string, or any term) into a
  user-facing string via gettext.
  """
  @spec message(error() | term()) :: String.t()
  def message(:all_downloads_failed), do: gettext("Every image download failed.")
  def message(:all_urls_invalid), do: gettext("None of the image URLs are valid.")
  def message(:already_migrated), do: gettext("This has already been migrated.")

  def message(:cart_already_converting),
    do: gettext("This cart is already being converted to an order.")

  def message(:cart_empty), do: gettext("The cart is empty.")
  def message(:cart_not_active), do: gettext("This cart is no longer active.")
  def message(:email_already_registered), do: gettext("This email address is already registered.")

  def message(:email_exists_confirmed),
    do: gettext("An account with this email address already exists.")

  def message(:empty_file), do: gettext("The file is empty.")
  def message(:file_not_found), do: gettext("The file could not be found.")
  def message(:forbidden), do: gettext("You do not have permission to perform this action.")
  def message(:import_log_not_found), do: gettext("The import log could not be found.")
  def message(:invalid_csv_format), do: gettext("The CSV file format is invalid.")
  def message(:invalid_host), do: gettext("The URL host is not allowed.")
  def message(:invalid_scheme), do: gettext("The URL scheme is not allowed.")
  def message(:missing_content_type), do: gettext("The response is missing a content type.")
  def message(:missing_slug), do: gettext("A slug is required.")
  def message(:missing_title), do: gettext("A title is required.")
  def message(:no_images), do: gettext("There are no images to process.")
  def message(:no_images_downloaded), do: gettext("No images could be downloaded.")
  def message(:no_shipping_method), do: gettext("No shipping method is available.")
  def message(:not_found), do: gettext("The requested record was not found.")
  def message(:payment_option_not_found), do: gettext("The payment option could not be found.")
  def message(:product_not_found), do: gettext("The product could not be found.")
  def message(:rate_limited), do: gettext("Too many requests. Please try again later.")
  def message(:redirect_loop), do: gettext("The URL redirected too many times.")
  def message(:server_error), do: gettext("The server returned an error.")
  def message(:temp_file_missing), do: gettext("The temporary file is missing.")
  def message(:timeout), do: gettext("The operation timed out.")
  def message(:unknown_format), do: gettext("The file format is not recognized.")

  def message(reason) when is_binary(reason), do: reason

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end
end
