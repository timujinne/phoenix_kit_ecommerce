defmodule PhoenixKitEcommerce.ErrorsTest do
  @moduledoc """
  One assertion per error atom guarding the EXACT user-facing string
  produced by `PhoenixKitEcommerce.Errors.message/1`. The default (English)
  locale is the source-of-truth msgid; if a clause is removed or its copy
  changes, the matching test breaks deliberately.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Errors

  describe "message/1 for known atoms" do
    test ":all_downloads_failed",
      do: assert(Errors.message(:all_downloads_failed) == "Every image download failed.")

    test ":all_urls_invalid",
      do: assert(Errors.message(:all_urls_invalid) == "None of the image URLs are valid.")

    test ":already_migrated",
      do: assert(Errors.message(:already_migrated) == "This has already been migrated.")

    test ":cart_already_converting",
      do:
        assert(
          Errors.message(:cart_already_converting) ==
            "This cart is already being converted to an order."
        )

    test ":cart_empty", do: assert(Errors.message(:cart_empty) == "The cart is empty.")

    test ":cart_not_active",
      do: assert(Errors.message(:cart_not_active) == "This cart is no longer active.")

    test ":email_already_registered",
      do:
        assert(
          Errors.message(:email_already_registered) ==
            "This email address is already registered."
        )

    test ":email_exists_confirmed",
      do:
        assert(
          Errors.message(:email_exists_confirmed) ==
            "An account with this email address already exists."
        )

    test ":empty_file", do: assert(Errors.message(:empty_file) == "The file is empty.")

    test ":file_not_found",
      do: assert(Errors.message(:file_not_found) == "The file could not be found.")

    test ":forbidden",
      do:
        assert(Errors.message(:forbidden) == "You do not have permission to perform this action.")

    test ":import_log_not_found",
      do: assert(Errors.message(:import_log_not_found) == "The import log could not be found.")

    test ":invalid_csv_format",
      do: assert(Errors.message(:invalid_csv_format) == "The CSV file format is invalid.")

    test ":invalid_host",
      do: assert(Errors.message(:invalid_host) == "The URL host is not allowed.")

    test ":invalid_scheme",
      do: assert(Errors.message(:invalid_scheme) == "The URL scheme is not allowed.")

    test ":missing_content_type",
      do:
        assert(Errors.message(:missing_content_type) == "The response is missing a content type.")

    test ":missing_slug", do: assert(Errors.message(:missing_slug) == "A slug is required.")

    test ":missing_title", do: assert(Errors.message(:missing_title) == "A title is required.")

    test ":no_images",
      do: assert(Errors.message(:no_images) == "There are no images to process.")

    test ":no_images_downloaded",
      do: assert(Errors.message(:no_images_downloaded) == "No images could be downloaded.")

    test ":no_shipping_method",
      do: assert(Errors.message(:no_shipping_method) == "No shipping method is available.")

    test ":not_found",
      do: assert(Errors.message(:not_found) == "The requested record was not found.")

    test ":payment_option_not_found",
      do:
        assert(
          Errors.message(:payment_option_not_found) == "The payment option could not be found."
        )

    test ":product_not_found",
      do: assert(Errors.message(:product_not_found) == "The product could not be found.")

    test ":rate_limited",
      do: assert(Errors.message(:rate_limited) == "Too many requests. Please try again later.")

    test ":redirect_loop",
      do: assert(Errors.message(:redirect_loop) == "The URL redirected too many times.")

    test ":server_error",
      do: assert(Errors.message(:server_error) == "The server returned an error.")

    test ":temp_file_missing",
      do: assert(Errors.message(:temp_file_missing) == "The temporary file is missing.")

    test ":timeout", do: assert(Errors.message(:timeout) == "The operation timed out.")

    test ":unknown_format",
      do: assert(Errors.message(:unknown_format) == "The file format is not recognized.")
  end

  describe "message/1 fallbacks" do
    test "passes strings through unchanged" do
      assert Errors.message("custom downstream message") == "custom downstream message"
    end

    test "renders unknown reasons via inspect" do
      assert Errors.message({:weird, 1}) == "Unexpected error: {:weird, 1}"
      assert Errors.message(:totally_unmapped) == "Unexpected error: :totally_unmapped"
    end
  end
end
