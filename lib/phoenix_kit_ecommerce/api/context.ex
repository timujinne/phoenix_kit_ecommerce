defmodule PhoenixKitEcommerce.API.Context do
  @moduledoc """
  Language, currency and money of one public API call.

  `build/2` takes the tool input and the executor's handler context and
  resolves what the answer is written in: an explicit `language` / `currency`
  input must be enabled (else `validation_failed` with the allowed list), a
  value from the host hook falls back quietly, and the currency falls back to
  the shop's base currency.

  The `url` and `image` of a card are made absolute with the request's
  `base_url`, which core builds from the Host header unless the host app's
  `:api_request_context` hook names the domains (the calls are POSTs, so no
  shared cache holds a link made for another host). The `url` of a product or
  a category in a language that has a domain of its own (the host's
  `:canonical_host_resolver`) is on that domain instead (`absolute/3`).

  Money is converted from the stored base-currency amount with
  `PhoenixKitBilling.Currency.present/3` (the storefront's one conversion path)
  and written as a string with the currency's decimal places.
  """

  @compile {:no_warn_undefined, [{PhoenixKit.Utils.Routes, :canonical_absolute_or_nil, 2}]}

  alias PhoenixKit.Modules.Languages
  alias PhoenixKit.Modules.Languages.DialectMapper
  alias PhoenixKit.Utils.Routes
  alias PhoenixKitBilling, as: Billing
  alias PhoenixKitBilling.Currency
  alias PhoenixKitEcommerce.Translations

  @enforce_keys [:language, :default_language, :currency, :base, :base_url]
  defstruct [
    :language,
    :default_language,
    :currency,
    :base,
    :base_url,
    hosts: [],
    actor: nil,
    request_id: nil
  ]

  @type t :: %__MODULE__{
          language: String.t(),
          default_language: String.t(),
          currency: Currency.t(),
          base: Currency.t(),
          base_url: String.t(),
          hosts: [String.t()],
          actor: term(),
          request_id: String.t() | nil
        }

  @doc "Resolves the context of one call. Errors are shaped like a handler's own errors."
  @spec build(map(), map()) :: {:ok, t()} | {:error, atom(), String.t(), map()}
  def build(input, handler_ctx) when is_map(input) and is_map(handler_ctx) do
    with {:ok, language} <- language(input, handler_ctx),
         {:ok, base} <- base_currency(),
         {:ok, currency} <- currency(input, handler_ctx, base) do
      {:ok,
       %__MODULE__{
         language: language,
         default_language: default_language(handler_ctx),
         currency: currency,
         base: base,
         base_url: Map.get(handler_ctx, :base_url) || "",
         hosts: Map.get(handler_ctx, :hosts) || [],
         actor: Map.get(handler_ctx, :actor),
         request_id: Map.get(handler_ctx, :request_id)
       }}
    end
  end

  @doc """
  The enabled language code that `requested` stands for: an exact match, then
  a case-insensitive one, then the first enabled code with the same base
  (`"de"` finds `"de-DE"`); the shop's default language when nothing matches.
  """
  @spec resolve_language(String.t() | nil, [String.t()]) :: String.t()
  def resolve_language(requested, enabled) do
    match_language(requested, enabled) || Translations.default_language()
  end

  @doc ~s|`%{"amount" => "12.50", "currency" => "EUR"}` for a base-currency amount; `nil` for `nil`.|
  @spec money(t(), Decimal.t() | nil) :: %{String.t() => String.t()} | nil
  def money(_context, nil), do: nil

  def money(%__MODULE__{currency: currency}, %Decimal{} = amount) do
    places = currency.decimal_places || 2
    # `Decimal.round/2` also pads: 10 rounded to 2 places is written "10.00".
    shown = amount |> Currency.present(currency.code) |> Decimal.round(places)
    %{"amount" => Decimal.to_string(shown, :normal), "currency" => currency.code}
  end

  @doc "A response-currency amount (a price filter) back in the base currency."
  @spec to_base(t(), Decimal.t()) :: Decimal.t()
  def to_base(%__MODULE__{currency: %{code: code}, base: %{code: code}}, amount), do: amount

  def to_base(%__MODULE__{currency: target, base: base}, %Decimal{} = amount) do
    rate = Decimal.div(target.exchange_rate, base.exchange_rate)
    Decimal.div(amount, rate)
  end

  @doc """
  Runs `fun` with Billing's process-scoped display currency set to the
  response currency and the request default language set to the language of
  the domain the request came to (so a link to the domain's own language
  carries no locale prefix, like on the storefront), and puts both previous
  values back afterwards (also when `fun` raises).
  """
  @spec with_request_currency(t(), (-> result)) :: result when result: term()
  def with_request_currency(
        %__MODULE__{currency: %{code: code}, default_language: default_language},
        fun
      )
      when is_function(fun, 0) do
    previous_currency = Currency.get_request_currency()
    previous_language = Languages.request_default_language()
    Currency.put_request_currency(code)
    Languages.put_request_default_language(default_language)

    try do
      fun.()
    after
      Currency.put_request_currency(previous_currency)
      Languages.put_request_default_language(previous_language)
    end
  end

  @doc "A path made absolute with the request's base URL; a URL and `nil` are left alone."
  @spec absolute(t(), String.t() | nil) :: String.t() | nil
  def absolute(_context, nil), do: nil
  def absolute(_context, ""), do: nil
  def absolute(%__MODULE__{base_url: base_url}, "/" <> _rest = path), do: base_url <> path
  def absolute(_context, other), do: other

  @doc """
  `absolute/2` for a path built for a page in `language` (`Shop.product_url/2`
  and the like).

  A language that has a domain of its own (core's
  `Routes.canonical_absolute_or_nil/2`, from the host's
  `:canonical_host_resolver`) is linked on that domain, and the language
  segment goes: the domain is the language. Core removes only the segment of
  that language, straight after the mount prefix; the storefront builds it from
  the base code (`Shop.url_locale/1`), so `en-US` and `en-GB` share `/en`. A language without a domain, a URL, `nil`, and a
  core that has no such helper all give `absolute/2`: the request's own host,
  the path as it is. The resolver is asked once per link, with the language as
  given (`de-AT`), so it decides which dialects share a domain.
  """
  @spec absolute(t(), String.t() | nil, String.t()) :: String.t() | nil
  def absolute(context, "/" <> _rest = path, language) do
    language_domain_url(path, language) || absolute(context, path)
  end

  def absolute(context, other, _language), do: absolute(context, other)

  # The function is not in a core older than the helper (hence
  # `no_warn_undefined`), so it is only reached once it is exported.
  defp language_domain_url(path, language) do
    if Code.ensure_loaded?(Routes) and function_exported?(Routes, :canonical_absolute_or_nil, 2) do
      Routes.canonical_absolute_or_nil(path, language)
    end
  end

  # --- language --------------------------------------------------------------

  # The language of the domain (the host hook's, else the shop default), also
  # when the caller asked for another one: links to the domain's own language
  # are the canonical ones.
  defp default_language(handler_ctx) do
    resolve_language(Map.get(handler_ctx, :language), Translations.enabled_languages())
  end

  defp language(input, handler_ctx) do
    enabled = Translations.enabled_languages()

    case Map.get(input, "language") do
      nil ->
        {:ok, resolve_language(Map.get(handler_ctx, :language), enabled)}

      requested ->
        case match_language(requested, enabled) do
          nil ->
            {:error, :validation_failed, "The requested language is not enabled.",
             %{
               errors: [
                 %{path: "language", message: "is not an enabled language", allowed: enabled}
               ]
             }}

          code ->
            {:ok, code}
        end
    end
  end

  defp match_language(requested, enabled) when is_binary(requested) and requested != "" do
    down = String.downcase(requested)
    base = DialectMapper.extract_base(requested)

    Enum.find(enabled, &(&1 == requested)) ||
      Enum.find(enabled, &(String.downcase(&1) == down)) ||
      Enum.find(enabled, &(DialectMapper.extract_base(&1) == base))
  end

  defp match_language(_requested, _enabled), do: nil

  # --- currency --------------------------------------------------------------

  defp base_currency do
    case Billing.get_base_currency() do
      nil -> {:error, :internal_error, "No base currency is configured for this shop.", %{}}
      base -> {:ok, base}
    end
  end

  defp currency(input, handler_ctx, base) do
    case Map.get(input, "currency") do
      nil ->
        {:ok, resolve_currency(Map.get(handler_ctx, :currency), base)}

      requested ->
        code = String.upcase(requested)
        enabled = [base.code | Enum.map(Billing.list_enabled_currencies(), & &1.code)]
        enabled = enabled |> Enum.uniq() |> Enum.sort()

        if code in enabled do
          {:ok, resolve_currency(code, base)}
        else
          {:error, :validation_failed, "The requested currency is not enabled.",
           %{
             errors: [
               %{path: "currency", message: "is not an enabled currency", allowed: enabled}
             ]
           }}
        end
    end
  end

  defp resolve_currency(code, base) when is_binary(code) and code != "",
    do: Billing.resolve_display_currency(String.upcase(code)) || base

  defp resolve_currency(_none, base), do: base
end
