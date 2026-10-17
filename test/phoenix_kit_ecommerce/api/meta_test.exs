defmodule PhoenixKitEcommerce.API.MetaTest do
  @moduledoc """
  The change-log metadata of an API write and the log-safe class of a term.
  """

  use ExUnit.Case, async: true

  alias PhoenixKitEcommerce.API.Meta

  test "the actor is the key owner, and a context without an actor has none" do
    assert Meta.actor_uuid(%{actor: %{user_uuid: "u-1"}}) == "u-1"
    assert Meta.actor_uuid(%{actor: nil}) == nil
    assert Meta.actor_uuid(%{}) == nil
  end

  test "log metadata names the tool, the key prefix and the request; a nil actor does not raise" do
    assert Meta.log_metadata(%{actor: %{key_prefix: "pk_ab"}, request_id: "r-1"}, "t") == %{
             "via" => "api",
             "tool" => "t",
             "key_prefix" => "pk_ab",
             "request_id" => "r-1"
           }

    assert %{"key_prefix" => nil} = Meta.log_metadata(%{actor: nil}, "t")
  end

  test "log metadata carries who approved the call when core's approval flow ran it, and only then" do
    approved =
      Meta.log_metadata(%{actor: %{key_prefix: "pk_ab"}, approved_by_uuid: "admin-1"}, "t")

    assert approved["approved_by_uuid"] == "admin-1"

    plain = Meta.log_metadata(%{actor: %{key_prefix: "pk_ab"}}, "t")
    refute Map.has_key?(plain, "approved_by_uuid")

    refute Map.has_key?(
             Meta.log_metadata(%{actor: %{key_prefix: "pk_ab"}, approved_by_uuid: nil}, "t"),
             "approved_by_uuid"
           )
  end

  test "term_class names the shape of a term and never its values" do
    assert Meta.term_class(:timeout) == ":timeout"
    assert Meta.term_class(%Ecto.Changeset{data: %{}, types: %{}}) == "Ecto.Changeset"
    assert Meta.term_class({:error, "secret sku SK-1"}) == "{:error, _}"
    assert Meta.term_class({1, 2, 3}) == "tuple"
    assert Meta.term_class("secret sku SK-1") == "other"
    refute Meta.term_class({:error, "secret sku SK-1"}) =~ "SK-1"
  end
end
