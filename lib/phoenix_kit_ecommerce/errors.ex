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
    * tagged tuples carrying a detail — `{:option_key_exists, key}`,
      `{:option_missing_keys, keys}`, etc.
    * strings — passed through unchanged (legacy / interpolated messages)
    * changesets — one generic "could not be saved" message
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
          | :cart_base_unavailable
          | :cart_empty
          | :cart_not_active
          | :currency_mismatch
          | :currency_unavailable
          | :email_already_registered
          | :email_exists_confirmed
          | :empty_file
          | :file_not_found
          | :forbidden
          | :import_log_not_found
          | :invalid_csv_format
          | :invalid_destination
          | :invalid_host
          | :invalid_quantity
          | :invalid_scheme
          | :missing_base_currency
          | :missing_content_type
          | :missing_slug
          | :missing_title
          | :no_images
          | :no_images_downloaded
          | :no_shipping_method
          | :not_found
          | :option_not_found
          | :option_not_a_map
          | :options_not_a_list
          | :option_key_invalid
          | :option_key_not_a_string
          | :option_localized_label_invalid
          | :option_label_invalid
          | :option_allow_multiple_slots_invalid
          | :option_values_invalid
          | :option_modifier_type_invalid
          | :option_price_modifiers_unsupported
          | :option_price_modifiers_invalid
          | :option_price_modifiers_not_a_map
          | :option_price_modifiers_required
          | :option_value_empty
          | :option_key_and_value_required
          | {:option_missing_keys, [String.t()]}
          | {:option_type_invalid, term()}
          | {:option_values_not_a_list, String.t()}
          | {:option_values_empty, String.t()}
          | {:option_values_required, String.t()}
          | {:option_price_modifiers_missing, [String.t()]}
          | {:option_key_exists, String.t()}
          | {:option_key_exists_in_category, String.t()}
          | {:option_value_exists, String.t()}
          | :payment_option_not_found
          | :product_not_found
          | :rate_limited
          | :redirect_loop
          | :server_error
          | :shipping_quote_required
          | :temp_file_missing
          | :timeout
          | :unknown_format
          | {:unsupported_product_source, module()}

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

  def message(:cart_base_unavailable),
    do:
      gettext(
        "The shop's base currency changed and this cart cannot be updated right now. Please try again later."
      )

  def message(:cart_empty), do: gettext("The cart is empty.")
  def message(:cart_not_active), do: gettext("This cart is no longer active.")

  def message(:currency_mismatch),
    do: gettext("This item is priced in a different currency and cannot be added right now.")

  def message(:currency_unavailable),
    do: gettext("This cart's currency is not available right now.")

  def message(:email_already_registered), do: gettext("This email address is already registered.")

  def message(:email_exists_confirmed),
    do: gettext("An account with this email address already exists.")

  def message(:empty_file), do: gettext("The file is empty.")
  def message(:file_not_found), do: gettext("The file could not be found.")
  def message(:forbidden), do: gettext("You do not have permission to perform this action.")
  def message(:import_log_not_found), do: gettext("The import log could not be found.")
  def message(:invalid_csv_format), do: gettext("The CSV file format is invalid.")
  def message(:invalid_destination), do: gettext("The delivery details are not valid.")
  def message(:invalid_host), do: gettext("The URL host is not allowed.")
  def message(:invalid_quantity), do: gettext("That quantity is not available.")
  def message(:invalid_scheme), do: gettext("The URL scheme is not allowed.")

  def message(:missing_base_currency),
    do:
      gettext(
        "This shop has no base currency yet, so prices from Shopify cannot be written. Set a base currency first."
      )

  def message(:missing_content_type), do: gettext("The response is missing a content type.")
  def message(:missing_slug), do: gettext("A slug is required.")
  def message(:missing_title), do: gettext("A title is required.")
  def message(:no_images), do: gettext("There are no images to process.")
  def message(:no_images_downloaded), do: gettext("No images could be downloaded.")
  def message(:no_shipping_method), do: gettext("No shipping method is available.")
  def message(:not_found), do: gettext("The requested record was not found.")
  def message(:option_not_found), do: gettext("That option no longer exists.")
  def message(:payment_option_not_found), do: gettext("The payment option could not be found.")
  def message(:product_not_found), do: gettext("The product could not be found.")
  def message(:rate_limited), do: gettext("Too many requests. Please try again later.")
  def message(:redirect_loop), do: gettext("The URL redirected too many times.")
  def message(:server_error), do: gettext("The server returned an error.")

  def message(:shipping_quote_required),
    do: gettext("The delivery price has to be calculated before the order can be placed.")

  def message(:temp_file_missing), do: gettext("The temporary file is missing.")
  def message(:timeout), do: gettext("The operation timed out.")
  def message(:unknown_format), do: gettext("The file format is not recognized.")

  # Option definitions (`OptionTypes.validate_option/1`, `Options`).
  def message(:option_not_a_map), do: gettext("An option must be a map.")
  def message(:options_not_a_list), do: gettext("Options must be a list.")

  def message({:option_missing_keys, keys}) when is_list(keys),
    do: gettext("Missing required keys: %{keys}", keys: Enum.join(keys, ", "))

  def message(:option_key_invalid),
    do:
      gettext(
        "The key must be lowercase letters, digits and underscores, starting with a letter."
      )

  def message(:option_key_not_a_string), do: gettext("The key must be text.")

  def message(:option_localized_label_invalid),
    do: gettext("A localized label must map language codes to text.")

  def message(:option_label_invalid),
    do: gettext("The label must be text or a localized map.")

  def message(:option_allow_multiple_slots_invalid),
    do: gettext("\"Allow multiple slots\" must be on or off.")

  def message({:option_type_invalid, type}),
    do:
      gettext("Invalid type \"%{type}\". Must be one of: %{types}",
        type: label(type),
        types: Enum.join(PhoenixKitEcommerce.OptionTypes.supported_types(), ", ")
      )

  def message({:option_values_not_a_list, type}),
    do: gettext("The values of a %{type} option must be a list.", type: label(type))

  def message({:option_values_empty, type}),
    do: gettext("A %{type} option needs at least one value.", type: label(type))

  def message({:option_values_required, type}),
    do: gettext("A %{type} option needs its values.", type: label(type))

  def message(:option_values_invalid),
    do: gettext("Option values must be text, or maps with a \"value\" key.")

  def message(:option_modifier_type_invalid),
    do:
      gettext("The modifier type must be one of: %{types}",
        types: Enum.join(PhoenixKitEcommerce.OptionTypes.modifier_types(), ", ")
      )

  def message(:option_price_modifiers_unsupported),
    do: gettext("Price modifiers are only supported for select and multiselect types.")

  def message({:option_price_modifiers_missing, values}) when is_list(values),
    do:
      gettext("Missing price modifiers for options: %{values}",
        values: Enum.map_join(values, ", ", &label/1)
      )

  def message(:option_price_modifiers_invalid),
    do: gettext("Price modifiers must be valid decimal numbers (e.g., \"5.00\").")

  def message(:option_price_modifiers_not_a_map),
    do: gettext("Price modifiers must be a map.")

  def message(:option_price_modifiers_required),
    do: gettext("Price modifiers are required when the option affects the price.")

  def message({:option_key_exists, key}),
    do: gettext("An option with the key \"%{key}\" already exists.", key: label(key))

  def message({:option_key_exists_in_category, key}),
    do:
      gettext("An option with the key \"%{key}\" already exists in this category.",
        key: label(key)
      )

  def message(:option_value_empty), do: gettext("The value cannot be empty.")

  def message({:option_value_exists, value}),
    do: gettext("The value \"%{value}\" already exists.", value: label(value))

  def message(:option_key_and_value_required),
    do: gettext("Option key and value are required")

  # `reprice_for_base_change/3`'s refusal: only the shop's own tables are
  # repriced, so the change is refused before any write.
  def message({:unsupported_product_source, _source}),
    do:
      gettext(
        "Catalogue-backed shops cannot change their base currency yet. Nothing was changed and every price is still in the current base currency."
      )

  def message(reason) when is_binary(reason), do: reason

  # Never the changeset itself: its errors quote the values that were typed.
  def message(%Ecto.Changeset{}),
    do: gettext("The data could not be saved. Check the values and try again.")

  def message(reason) do
    gettext("Unexpected error: %{reason}", reason: inspect(reason))
  end

  # A detail carried by a tagged reason is admin-typed and may be any term.
  defp label(value) when is_binary(value), do: value
  defp label(value), do: inspect(value)
end
