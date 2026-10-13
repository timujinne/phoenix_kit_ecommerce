defmodule PhoenixKitEcommerce.Shopify.ShopDomainTest do
  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.Shopify.ShopDomain

  describe "validate/1" do
    test "accepts a bare myshopify.com hostname, normalized" do
      assert ShopDomain.validate("my-store.myshopify.com") == {:ok, "my-store.myshopify.com"}
      assert ShopDomain.validate("  My-Store.MyShopify.com ") == {:ok, "my-store.myshopify.com"}
    end

    for value <- [
          "internal-host:8443/x#",
          "my-store.myshopify.com:8443",
          "my-store.myshopify.com/admin",
          "my-store.myshopify.com#x",
          "my-store.myshopify.com@evil.example.com",
          "evil.example.com/.myshopify.com",
          "https://my-store.myshopify.com",
          "a.b.myshopify.com",
          "my-store.myshopify.com.evil.example.com",
          "shop.example.com",
          "myshopify.com",
          "-store.myshopify.com",
          "localhost",
          "169.254.169.254",
          ""
        ] do
      test "refuses #{inspect(value)}" do
        assert ShopDomain.validate(unquote(value)) == {:error, :invalid_shop_domain}
      end
    end

    test "refuses a non-string" do
      assert ShopDomain.validate(nil) == {:error, :invalid_shop_domain}
      assert ShopDomain.validate(123) == {:error, :invalid_shop_domain}
    end
  end

  describe "same_host?/2" do
    @host "my-store.myshopify.com"

    test "an https URL on the host itself" do
      assert ShopDomain.same_host?("https://#{@host}/admin/api/x.json?page_info=1", @host)
    end

    test "another host, scheme, port or embedded credentials" do
      refute ShopDomain.same_host?("https://evil.example.com/admin/api/x.json", @host)
      refute ShopDomain.same_host?("http://#{@host}/admin/api/x.json", @host)
      refute ShopDomain.same_host?("https://#{@host}:8443/admin/api/x.json", @host)
      refute ShopDomain.same_host?("https://user@#{@host}/admin/api/x.json", @host)
      refute ShopDomain.same_host?("https://#{@host}.evil.example.com/x", @host)
      refute ShopDomain.same_host?("/admin/api/x.json", @host)
      refute ShopDomain.same_host?(nil, @host)
    end
  end
end
