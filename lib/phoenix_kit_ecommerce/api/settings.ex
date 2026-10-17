defmodule PhoenixKitEcommerce.API.Settings do
  @moduledoc """
  The e-commerce settings of the admin API. One place knows the key and the
  default, so the settings page and the danger check cannot disagree.

  `api_confirm_price_change_pct` (default 30): a price that is above zero and
  moves by more than this many percent needs a confirmation. A read error
  counts as the default, never as "no limit".
  """

  @compile {:no_warn_undefined, PhoenixKit.API.Config}

  alias PhoenixKit.API.Config, as: CoreConfig
  alias PhoenixKit.Settings

  @pct_key "api_confirm_price_change_pct"
  @default_pct 30
  @max_pct 1000

  @doc "The settings key of the threshold."
  @spec price_change_pct_key() :: String.t()
  def price_change_pct_key, do: @pct_key

  @doc "The threshold when nothing valid is stored."
  @spec default_price_change_pct() :: non_neg_integer()
  def default_price_change_pct, do: @default_pct

  @doc "Largest value the settings page accepts."
  @spec max_price_change_pct() :: pos_integer()
  def max_price_change_pct, do: @max_pct

  @doc """
  The confirmation threshold for price moves, in percent. `read` is the
  function that reads an integer setting (`key, default`); a value that is not
  a threshold, or a read that raises or exits, gives the default.
  """
  @spec price_change_pct((String.t(), integer() -> term())) :: non_neg_integer()
  def price_change_pct(read \\ &Settings.get_integer_setting/2) do
    case read.(@pct_key, @default_pct) do
      value when is_integer(value) and value >= 0 and value <= @max_pct -> value
      _ -> @default_pct
    end
  rescue
    _ -> @default_pct
  catch
    :exit, _ -> @default_pct
  end

  @doc "Whether core ships the admin API. The settings page shows its card only then."
  @spec core_available?() :: boolean()
  def core_available?, do: Code.ensure_loaded?(CoreConfig)

  @doc "Whether the admin API is switched on in core. `false` without core's API, and on any read error."
  @spec admin_enabled?() :: boolean()
  def admin_enabled? do
    core_available?() and CoreConfig.admin_enabled?() == true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  @doc "Stores the threshold. `{:error, :invalid}` unless it is a whole number from 0 to 1000."
  @spec put_price_change_pct(term()) :: {:ok, term()} | {:error, :invalid | term()}
  def put_price_change_pct(value) when is_integer(value) and value >= 0 and value <= @max_pct do
    Settings.update_setting_with_module(@pct_key, Integer.to_string(value), "shop")
  end

  def put_price_change_pct(_value), do: {:error, :invalid}
end
