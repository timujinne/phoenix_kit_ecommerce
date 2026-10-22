defmodule PhoenixKitEcommerce.API.CartSettings do
  @moduledoc """
  The settings of the public cart API that this module owns.

  | Setting | Default | Range |
  |---|---|---|
  | `api_cart_idle_days` | 7 | 1..365 |
  | `api_checkout_claim_ttl_minutes` | 30 | 1..1440 |
  | `api_signal_per_cart_per_hour` | 3 | 0..1000 |
  | `api_signal_global_per_hour` | 30 | 0..100000 |

  The two new-rows limits (`api_public_new_rows_per_ip_hour`,
  `api_public_new_rows_global_hour`) belong to core: they are shared by every
  module that creates rows for a caller without a key, read by
  `PhoenixKit.API.RateLimit.check_new_rows/1` and edited on Settings -> API.
  Until core 3.0.0 a limit whose new key holds no number still reads its old
  key (`api_public_cart_rows_per_ip_hour`, `api_public_cart_rows_global_hour`).

  Every reader returns its default for a missing, malformed or out-of-range
  value and when the settings layer fails; none raises. A cap of `0` is valid
  and switches assistant notifications off.
  """

  alias PhoenixKit.Settings

  @keys %{
    idle_days: "api_cart_idle_days",
    claim_ttl_minutes: "api_checkout_claim_ttl_minutes",
    signal_per_cart_per_hour: "api_signal_per_cart_per_hour",
    signal_global_per_hour: "api_signal_global_per_hour"
  }

  @defaults %{
    idle_days: 7,
    claim_ttl_minutes: 30,
    signal_per_cart_per_hour: 3,
    signal_global_per_hour: 30
  }

  @bounds %{
    idle_days: 1..365,
    claim_ttl_minutes: 1..1440,
    signal_per_cart_per_hour: 0..1000,
    signal_global_per_hour: 0..100_000
  }

  @type name ::
          :idle_days | :claim_ttl_minutes | :signal_per_cart_per_hour | :signal_global_per_hour

  @doc "The setting key of each name."
  @spec keys() :: %{name() => String.t()}
  def keys, do: @keys

  @doc "The default of each name."
  @spec defaults() :: %{name() => non_neg_integer()}
  def defaults, do: @defaults

  @doc "The accepted range of each name."
  @spec bounds() :: %{name() => Range.t()}
  def bounds, do: @bounds

  @doc "Days an unclaimed `api:` cart may sit idle before the sweep abandons it."
  @spec idle_days() :: pos_integer()
  def idle_days, do: get(:idle_days)

  @doc "Minutes a checkout claim stays valid."
  @spec claim_ttl_minutes() :: pos_integer()
  def claim_ttl_minutes, do: get(:claim_ttl_minutes)

  @doc "Assistant notifications allowed per cart per hour (0 = none)."
  @spec signal_per_cart_per_hour() :: non_neg_integer()
  def signal_per_cart_per_hour, do: get(:signal_per_cart_per_hour)

  @doc "Assistant notifications allowed per hour for the whole install (0 = none)."
  @spec signal_global_per_hour() :: non_neg_integer()
  def signal_global_per_hour, do: get(:signal_global_per_hour)

  @doc "The value of a setting by name."
  @spec get(name()) :: non_neg_integer()
  def get(name) when is_map_key(@keys, name) do
    read(Map.fetch!(@keys, name), Map.fetch!(@bounds, name), Map.fetch!(@defaults, name))
  end

  defp read(key, range, default) do
    case Settings.get_setting_cached(key, nil) do
      value when is_binary(value) -> parse(String.trim(value), range, default)
      _ -> default
    end
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp parse(value, range, default) do
    case Integer.parse(value) do
      {int, ""} -> if int in range, do: int, else: default
      _ -> default
    end
  end
end
