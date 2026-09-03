defmodule PhoenixKitEcommerce.TranslationSweepSettings do
  @moduledoc """
  Settings that drive the AI-translation reconciliation sweep (design §4.3,
  §4.6). Read-only, like `PhoenixKitEcommerce.Policy` — writing these keys
  is the admin UI's job (design §4.5's operational panel, §4.6's existence
  card), through the same `Settings.update_setting_with_module/3` /
  `update_boolean_setting_with_module/3` / `update_json_setting_with_module/3`
  recipe every other shop setting uses. This module exists so the worker
  (and, later, the management page) never hand-roll a key string or a
  default twice.

  ## Keys

  | Setting | Type | Default | Meaning |
  |---|---|---|---|
  | `shop_translations_enabled` | bool | `false` | The translations feature exists at all: page, menu entry, manual actions. Owned by the `/admin/shop/settings` existence card — the sweep only reads it. |
  | `shop_translation_sweep_enabled` | bool | `false` | The background tick is allowed to enqueue work on its own. |
  | `shop_translation_interval_minutes` | int | `60` | Minutes between ticks. |
  | `shop_translation_batch` | int | `3` | Resources (products + categories combined) a tick may select. |
  | `shop_translation_max_in_flight` | int | `6` | Ceiling on incomplete `TranslateWorker` **jobs** (not resources) contributed by the shop, counted across `available`/`scheduled`/`executing`/`retryable` — the same states `PhoenixKitAI.Translations` itself dedups against. |
  | `shop_translation_languages` | json | every enabled language except the primary | Target languages the sweep translates into. |
  | `shop_translation_statuses` | json | `["active"]` | Product statuses the sweep considers. Categories are never filtered by this (design §4.3: a hidden category would otherwise ship translated navigation before it's visible). |

  `shop_translations_enabled` gates `shop_translation_sweep_enabled`
  one-directionally (design §12.4): the sweep never runs without the
  section, but the section can exist with the sweep off ("manual only").
  Enforcing that direction is the tick's job (`TranslationSweepWorker`
  checks both), not this module's — a reader here has no side effects.

  Every reader tolerates a missing or malformed stored value by falling
  back to its documented default rather than raising, mirroring `Policy`:
  a hand-edited settings row must degrade the sweep to "off", never crash
  the tick or open it wider than configured.
  """

  alias PhoenixKit.Settings
  alias PhoenixKitEcommerce.Translations

  @translations_enabled_key "shop_translations_enabled"
  @sweep_enabled_key "shop_translation_sweep_enabled"
  @interval_key "shop_translation_interval_minutes"
  @batch_key "shop_translation_batch"
  @max_in_flight_key "shop_translation_max_in_flight"
  @languages_key "shop_translation_languages"
  @statuses_key "shop_translation_statuses"

  @default_interval_minutes 60
  @default_batch 3
  @default_max_in_flight 6
  @default_statuses ["active"]

  @doc "Does the translations feature exist (page, menu, manual actions)? Default `false`."
  @spec translations_enabled?() :: boolean()
  def translations_enabled?, do: read_boolean(@translations_enabled_key, false)

  @doc "May the background tick enqueue work on its own? Default `false`."
  @spec sweep_enabled?() :: boolean()
  def sweep_enabled?, do: read_boolean(@sweep_enabled_key, false)

  @doc "Minutes between ticks. Default `#{@default_interval_minutes}`. Never below 1."
  @spec interval_minutes() :: pos_integer()
  def interval_minutes, do: read_positive_integer(@interval_key, @default_interval_minutes)

  @doc "Resources (products + categories combined) a tick may select. Default `#{@default_batch}`."
  @spec batch_size() :: non_neg_integer()
  def batch_size, do: read_non_negative_integer(@batch_key, @default_batch)

  @doc """
  Ceiling on incomplete `TranslateWorker` jobs the shop may have in flight
  at once. Default `#{@default_max_in_flight}`.
  """
  @spec max_in_flight() :: non_neg_integer()
  def max_in_flight, do: read_non_negative_integer(@max_in_flight_key, @default_max_in_flight)

  @doc """
  Target languages, intersected with currently-enabled languages on every
  read (design §4.6): a language disabled after this setting was saved
  silently drops out here rather than being sweep-queued for a language
  the storefront no longer serves. When nothing is stored, defaults to
  every enabled language except the primary.
  """
  @spec languages() :: [String.t()]
  def languages do
    enabled = Translations.enabled_languages()
    enabled_set = MapSet.new(enabled)

    configured =
      case read_json(@languages_key, nil) do
        %{"codes" => codes} when is_list(codes) -> Enum.filter(codes, &is_binary/1)
        _ -> enabled -- [Translations.default_language()]
      end

    Enum.filter(configured, &MapSet.member?(enabled_set, &1))
  end

  @doc """
  Product statuses the sweep considers (design §4.3: categories are never
  filtered this way). Default `#{inspect(@default_statuses)}`.
  """
  @spec statuses() :: [String.t()]
  def statuses do
    case read_json(@statuses_key, nil) do
      %{"statuses" => list} when is_list(list) -> Enum.filter(list, &is_binary/1)
      _ -> @default_statuses
    end
  end

  # -- internals ---------------------------------------------------------

  defp read(key, default) do
    Settings.get_setting_cached(key, default)
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp read_boolean(key, default) do
    read(key, to_string(default)) == "true"
  end

  defp read_positive_integer(key, default) do
    case read_integer(key, default) do
      value when is_integer(value) and value > 0 -> value
      _ -> default
    end
  end

  defp read_non_negative_integer(key, default) do
    case read_integer(key, default) do
      value when is_integer(value) and value >= 0 -> value
      _ -> default
    end
  end

  defp read_integer(key, default) do
    Settings.get_integer_setting(key, default)
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end

  defp read_json(key, default) do
    Settings.get_json_setting_cached(key, default)
  rescue
    _ -> default
  catch
    :exit, _ -> default
  end
end
