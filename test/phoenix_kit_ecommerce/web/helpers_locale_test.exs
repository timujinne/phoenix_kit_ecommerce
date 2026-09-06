defmodule PhoenixKitEcommerce.Web.HelpersLocaleTest do
  @moduledoc """
  `put_content_locale/1` is the fix for a bug that made the ENTIRE module render
  English however complete its catalogues were: the content language is a dialect
  ("ru-RU") and the catalogues are plain codes ("ru"), and Gettext does not fall
  back between them. The existing i18n test passes plain codes directly, which is
  exactly why it never caught this.
  """
  use PhoenixKitEcommerce.DataCase, async: false

  alias PhoenixKit.Settings
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce.Web.Helpers

  @backend PhoenixKitEcommerce.Gettext

  describe "put_content_locale/1" do
    test "an exact locale is used as-is" do
      Helpers.put_content_locale("ru")
      assert Gettext.get_locale(@backend) == "ru"
    end

    test "a DIALECT resolves to its base language" do
      # The regression. Without this the lookup misses and returns the msgid,
      # which is the English source string.
      Helpers.put_content_locale("ru-RU")
      assert Gettext.get_locale(@backend) == "ru"

      Helpers.put_content_locale("et-EE")
      assert Gettext.get_locale(@backend) == "et"
    end

    test "an unknown locale RESETS rather than leaking the previous one" do
      # put_locale/2 is process-scoped and the dead render reuses a connection
      # process across keep-alive requests, so a no-op here served the previous
      # visitor's language to the next one.
      Helpers.put_content_locale("ru")
      assert Gettext.get_locale(@backend) == "ru"

      Helpers.put_content_locale("zz-ZZ")
      refute Gettext.get_locale(@backend) == "ru"
    end

    test "a non-binary is returned untouched" do
      assert Helpers.put_content_locale(nil) == nil
    end

    test "returns its input so it can sit in a pipeline" do
      assert Helpers.put_content_locale("ru-RU") == "ru-RU"
    end
  end

  describe "hide_zero_decimals?/0" do
    test "defaults to off" do
      Settings.update_setting("shop_hide_zero_decimals", "false")
      refute Helpers.hide_zero_decimals?()
    end

    test "drops an all-zero fraction only, and never touches a real one" do
      Settings.update_setting("shop_hide_zero_decimals", "true")
      assert Helpers.hide_zero_decimals?()

      # An UNKNOWN code (not "EUR" — per-domain-currency Э1-E3 made a
      # known code resolve to its real currency struct and symbol via
      # `PhoenixKitEcommerce.currency_for_code/1`, so this needs a code
      # that stays bare to test the bare-code branch at all): the
      # plain-code and nil branches must agree with the currency branch
      # about WHEN to trim.
      assert Helpers.format_price(Decimal.new("40.00"), "XYZ") == "40 XYZ"
      assert Helpers.format_price(Decimal.new("40.50"), "XYZ") == "40.50 XYZ"

      Settings.update_setting("shop_hide_zero_decimals", "false")
      assert Helpers.format_price(Decimal.new("40.00"), "XYZ") == "40.00 XYZ"
    end

    test "the CURRENCY branch trims without rounding a real fraction" do
      # The regression this test's sibling asserted the contract for but never
      # exercised. Trimming is implemented by handing billing a currency whose
      # decimal_places is 0, and `format_amount/2` ROUNDS to that precision — so
      # zeroing it unconditionally turned 40.50 into "€41" and 1234.99 into
      # "€1,235" on the catalog, the cart line, the tax row and the total: a
      # figure the shopper is never charged.
      currency = %Currency{symbol: "€", decimal_places: 2}

      Settings.update_setting("shop_hide_zero_decimals", "true")

      assert Helpers.format_price(Decimal.new("40.00"), currency) == "€40"
      assert Helpers.format_price(Decimal.new("40.50"), currency) == "€40.50"
      assert Helpers.format_price(Decimal.new("40.49"), currency) == "€40.49"
      assert Helpers.format_price(Decimal.new("1234.99"), currency) == "€1,234.99"
      assert Helpers.format_price(Decimal.new("1234.00"), currency) == "€1,234"

      # Off, the currency's own precision is untouched.
      Settings.update_setting("shop_hide_zero_decimals", "false")
      assert Helpers.format_price(Decimal.new("40.00"), currency) == "€40.00"
      assert Helpers.format_price(Decimal.new("40.50"), currency) == "€40.50"
    end

    test "a zero-decimal currency is left alone" do
      # Nothing to trim, and `%{currency | decimal_places: 0}` must not turn a
      # JPY-style currency into something else.
      currency = %Currency{symbol: "¥", decimal_places: 0}

      Settings.update_setting("shop_hide_zero_decimals", "true")
      assert Helpers.format_price(Decimal.new("4000"), currency) == "¥4,000"
    end
  end
end
