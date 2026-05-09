require Logger

# i18n tests require phoenix_kit with the `gettext_backend` API
# (see BeamLabEU/phoenix_kit#522). Until that ships in a Hex release,
# CI building against the published phoenix_kit lacks
# `PhoenixKit.Dashboard.Tab.localized_label/1` and the assertions
# would raise `UndefinedFunctionError`. Detect availability and
# exclude those tests when the API is missing — they run automatically
# the moment the consumer's `phoenix_kit` dep resolves to a release
# that includes the API.
if Code.ensure_loaded?(PhoenixKit.Dashboard.Tab) and
     function_exported?(PhoenixKit.Dashboard.Tab, :localized_label, 1) do
  ExUnit.start()
else
  Logger.info(
    "[test_helper] PhoenixKit.Dashboard.Tab.localized_label/1 not available — " <>
      "i18n tests excluded. They will run automatically once `phoenix_kit` is " <>
      "upgraded to a release that ships the gettext_backend API."
  )

  ExUnit.start(exclude: [:requires_phoenix_kit_i18n_api])
end
