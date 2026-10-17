defmodule PhoenixKitEcommerce.Web.ClaimHTML do
  @moduledoc """
  The checkout claim page: a bare card inside the host's root layout, in the
  language of the claim. One form posts back to the claim URL (`<.form>` adds
  the CSRF token); `offer` tells the server what the page showed (`none`, or the
  uuid of the buyer's own cart) and `revision` tells it which lines of the
  assistant's cart were shown, so a change to those lines in between is noticed.
  The buyer's own cart is bound by its uuid only.
  """

  use PhoenixKitEcommerce.Web, :html

  alias PhoenixKitEcommerce.NamePrefix
  alias PhoenixKitEcommerce.PriceDisplay
  alias PhoenixKitEcommerce.Web.Helpers

  attr :cart, :map, required: true
  attr :existing, :map, default: nil
  attr :action, :string, required: true
  attr :revision, :string, required: true
  attr :flash, :map, default: %{}

  @doc "The claim card: the lines, the subtotal, a notice when there is one, and the choice."
  def interstitial(assigns) do
    ~H"""
    <div id="claim-page" class="min-h-screen flex items-center justify-center bg-base-200 p-4">
      <div class="card bg-base-100 shadow-xl w-full max-w-lg">
        <div class="card-body gap-4">
          <h1 class="card-title text-xl">{gettext("An assistant prepared this cart for you")}</h1>

          <div
            :if={Phoenix.Flash.get(@flash, :info)}
            id="claim-notice-info"
            role="alert"
            class="alert alert-info text-sm"
          >
            {Phoenix.Flash.get(@flash, :info)}
          </div>
          <div
            :if={Phoenix.Flash.get(@flash, :error)}
            id="claim-notice-error"
            role="alert"
            class="alert alert-error text-sm"
          >
            {Phoenix.Flash.get(@flash, :error)}
          </div>

          <ul id="claim-lines" class="divide-y divide-base-200">
            <li
              :for={item <- Enum.sort_by(@cart.items, & &1.uuid)}
              id={"claim-line-#{item.uuid}"}
              class="flex justify-between gap-4 py-2 text-sm"
            >
              <span>
                {NamePrefix.strip(item.product_title)}
                <span class="text-base-content/60">×{item.quantity}</span>
                <span
                  :if={item.selected_specs not in [nil, %{}]}
                  class="block text-xs text-base-content/60"
                >
                  <span :for={{key, value} <- item.selected_specs} class="inline-block mr-2">
                    <span class="font-medium">{Helpers.humanize_key(key)}:</span>
                    <span>{value}</span>
                  </span>
                </span>
              </span>
              <span class="font-medium">
                {PriceDisplay.render(nil, @cart.currency, :cart,
                  amount: item.line_total,
                  unit: nil,
                  on_request: PriceDisplay.line_on_request?(item)
                )}
              </span>
            </li>
          </ul>

          <div class="flex justify-between font-semibold">
            <span>{gettext("Subtotal")}</span>
            <span id="claim-subtotal">{Helpers.format_price(@cart.subtotal, @cart.currency)}</span>
          </div>

          <p
            :if={PriceDisplay.any_line_on_request?(@cart.items)}
            id="claim-on-request-note"
            class="text-xs text-base-content/60"
          >
            {gettext("Items priced on request are not included in this total.")}
          </p>

          <.form for={%{}} id="claim-form" action={@action} method="post" class="flex flex-col gap-3">
            <input type="hidden" name="offer" value={if @existing, do: @existing.uuid, else: "none"} />
            <input type="hidden" name="revision" value={@revision} />

            <button
              :if={is_nil(@existing)}
              type="submit"
              id="claim-continue"
              class="btn btn-primary btn-block transition-transform hover:scale-[1.01]"
            >
              {gettext("Continue to checkout")}
            </button>

            <p :if={@existing} class="text-sm text-base-content/70">
              {gettext("You already have items in your cart. What would you like to do?")}
            </p>
            <button
              :if={@existing}
              type="submit"
              name="choice"
              value="add"
              id="claim-add"
              class="btn btn-primary btn-block transition-transform hover:scale-[1.01]"
            >
              {gettext("Add these items to my cart")}
            </button>
            <button
              :if={@existing}
              type="submit"
              name="choice"
              value="replace"
              id="claim-replace"
              class="btn btn-outline btn-block transition-transform hover:scale-[1.01]"
            >
              {gettext("Replace my cart")}
            </button>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
