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

    test ":cart_base_unavailable",
      do:
        assert(
          Errors.message(:cart_base_unavailable) ==
            "The shop's base currency changed and this cart cannot be updated right now. Please try again later."
        )

    test ":cart_empty", do: assert(Errors.message(:cart_empty) == "The cart is empty.")

    test ":currency_mismatch",
      do:
        assert(
          Errors.message(:currency_mismatch) ==
            "This item is priced in a different currency and cannot be added right now."
        )

    test ":currency_unavailable",
      do:
        assert(
          Errors.message(:currency_unavailable) ==
            "This cart's currency is not available right now."
        )

    test ":missing_base_currency",
      do:
        assert(
          Errors.message(:missing_base_currency) ==
            "This shop has no base currency yet, so prices from Shopify cannot be written. Set a base currency first."
        )

    test "{:unsupported_product_source, source} — the base-currency change refusal",
      do:
        assert(
          Errors.message(
            {:unsupported_product_source, PhoenixKitEcommerce.ProductSource.Catalogue}
          ) ==
            "Catalogue-backed shops cannot change their base currency yet. Nothing was changed and every price is still in the current base currency."
        )

    test ":invalid_quantity",
      do: assert(Errors.message(:invalid_quantity) == "That quantity is not available.")

    test ":option_not_found",
      do: assert(Errors.message(:option_not_found) == "That option no longer exists.")

    test "a changeset becomes one generic message and never quotes what was typed" do
      changeset =
        {%{}, %{email: :string}}
        |> Ecto.Changeset.cast(%{"email" => "private@example.com"}, [:email])
        |> Ecto.Changeset.add_error(:email, "is taken: private@example.com")

      message = Errors.message(changeset)

      assert message == "The data could not be saved. Check the values and try again."
      refute message =~ "private@example.com"
    end

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

    test ":invalid_destination",
      do: assert(Errors.message(:invalid_destination) == "The delivery details are not valid.")

    test ":shipping_quote_required",
      do:
        assert(
          Errors.message(:shipping_quote_required) ==
            "The delivery price has to be calculated before the order can be placed."
        )

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

  # `OptionTypes.validate_option/1` and `Options` answer reasons, never
  # prose: each one is produced by the real validation and its exact
  # message pinned here.
  describe "message/1 for option definition errors" do
    alias PhoenixKitEcommerce.OptionTypes
    alias PhoenixKitEcommerce.Web.OptionState

    defp refused(option) do
      assert {:error, reason} = OptionTypes.validate_option(option)
      {reason, Errors.message(reason)}
    end

    defp select(extra) do
      Map.merge(%{"key" => "size", "label" => "Size", "type" => "select"}, extra)
    end

    test "not a map, not a list" do
      assert refused("size") == {:option_not_a_map, "An option must be a map."}

      assert {:error, :options_not_a_list} = OptionTypes.validate_options(%{})
      assert Errors.message(:options_not_a_list) == "Options must be a list."
    end

    test "missing keys are named" do
      assert refused(%{"key" => "size"}) ==
               {{:option_missing_keys, ["label", "type"]}, "Missing required keys: label, type"}
    end

    test "key shape" do
      assert refused(%{"key" => "Size!", "label" => "Size", "type" => "text"}) ==
               {:option_key_invalid,
                "The key must be lowercase letters, digits and underscores, starting with a letter."}

      assert refused(%{"key" => 1, "label" => "Size", "type" => "text"}) ==
               {:option_key_not_a_string, "The key must be text."}
    end

    test "label shape" do
      assert refused(%{"key" => "size", "label" => %{"en" => 1}, "type" => "text"}) ==
               {:option_localized_label_invalid,
                "A localized label must map language codes to text."}

      assert refused(%{"key" => "size", "label" => 1, "type" => "text"}) ==
               {:option_label_invalid, "The label must be text or a localized map."}
    end

    test "type and slots" do
      assert refused(%{"key" => "size", "label" => "Size", "type" => "colour"}) ==
               {{:option_type_invalid, "colour"},
                "Invalid type \"colour\". Must be one of: text, number, boolean, select, multiselect"}

      assert refused(%{
               "key" => "size",
               "label" => "Size",
               "type" => "text",
               "allow_multiple_slots" => "yes"
             }) ==
               {:option_allow_multiple_slots_invalid,
                "\"Allow multiple slots\" must be on or off."}
    end

    test "select values" do
      assert refused(select(%{})) ==
               {{:option_values_required, "select"}, "A select option needs its values."}

      assert refused(select(%{"options" => "S"})) ==
               {{:option_values_not_a_list, "select"},
                "The values of a select option must be a list."}

      assert refused(select(%{"options" => []})) ==
               {{:option_values_empty, "select"}, "A select option needs at least one value."}

      assert refused(select(%{"options" => ["S", 1]})) ==
               {:option_values_invalid,
                "Option values must be text, or maps with a \"value\" key."}
    end

    test "price modifiers" do
      priced = fn extra ->
        select(Map.merge(%{"options" => ["S", "M"], "affects_price" => true}, extra))
      end

      assert refused(priced.(%{"modifier_type" => "ratio"})) ==
               {:option_modifier_type_invalid, "The modifier type must be one of: fixed, percent"}

      assert refused(priced.(%{})) ==
               {:option_price_modifiers_required,
                "Price modifiers are required when the option affects the price."}

      assert refused(priced.(%{"price_modifiers" => []})) ==
               {:option_price_modifiers_not_a_map, "Price modifiers must be a map."}

      assert refused(priced.(%{"price_modifiers" => %{"S" => "0"}})) ==
               {{:option_price_modifiers_missing, ["M"]},
                "Missing price modifiers for options: M"}

      assert refused(priced.(%{"price_modifiers" => %{"S" => "0", "M" => "lots"}})) ==
               {:option_price_modifiers_invalid,
                "Price modifiers must be valid decimal numbers (e.g., \"5.00\")."}

      assert refused(%{
               "key" => "size",
               "label" => "Size",
               "type" => "text",
               "affects_price" => true
             }) ==
               {:option_price_modifiers_unsupported,
                "Price modifiers are only supported for select and multiselect types."}
    end

    test "duplicate keys" do
      assert Errors.message({:option_key_exists, "size"}) ==
               "An option with the key \"size\" already exists."

      assert Errors.message({:option_key_exists_in_category, "size"}) ==
               "An option with the key \"size\" already exists in this category."
    end

    test "product form option state" do
      state = OptionState.new(%{metadata: %{}}, [select(%{"options" => ["S", "M"]})])

      assert {:error, :option_value_empty} = OptionState.add_value(state, "size", "  ")
      assert Errors.message(:option_value_empty) == "The value cannot be empty."

      assert {:error, {:option_value_exists, "M"} = reason} =
               OptionState.add_value(state, "size", "M")

      assert Errors.message(reason) == "The value \"M\" already exists."

      assert {:error, :option_key_and_value_required} =
               OptionState.add_new_option(state, " ", "Wood")

      assert Errors.message(:option_key_and_value_required) ==
               "Option key and value are required"
    end

    test "a detail that is not text is shown inspected, not raised on" do
      assert Errors.message({:option_type_invalid, %{"a" => 1}}) =~ ~s(%{"a" => 1})
    end
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
