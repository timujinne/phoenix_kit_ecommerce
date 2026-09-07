defmodule PhoenixKitEcommerce.Web.Components.SettingRows do
  @moduledoc """
  Rows for the admin settings cards: a title and its explanation on the
  left, the control on the right.

  Mirrors the row layout core uses on its own settings pages (Languages,
  Crawlers): a plain flex row, `font-medium` title, muted explanation. The
  daisyUI 5 `label` / `fieldset-legend` classes are deliberately not used
  here — `label` is an inline-flex, muted text style meant for a single
  input caption, and `fieldset-legend` styles a `<legend>`; stacking them
  around a paragraph of explanation greys the whole row out and stops the
  control from reaching the right edge.
  """
  use Phoenix.Component

  @doc """
  A setting with an on/off toggle. The whole row is the label, so clicking
  the text flips the toggle too.

  `event` is pushed on click; use `rest` for `phx-value-*` attributes.
  """
  attr :id, :string, default: nil, doc: "DOM id of the checkbox (tests target it)"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :note, :string, default: nil, doc: "Smaller third line, e.g. a caveat"
  attr :checked, :boolean, required: true
  attr :event, :string, required: true
  attr :toggle_class, :string, default: "toggle-primary", doc: "daisyUI toggle colour class"
  attr :class, :string, default: nil, doc: "Extra classes on the row"
  attr :rest, :global

  def setting_toggle(assigns) do
    ~H"""
    <label class={["flex items-start justify-between gap-6 py-3 cursor-pointer", @class]}>
      <span class="min-w-0">
        <span class="block font-medium">{@title}</span>
        <span :if={@description} class="block text-sm text-base-content/60 mt-1">
          {@description}
        </span>
        <span :if={@note} class="block text-xs text-base-content/50 mt-1">{@note}</span>
      </span>
      <input
        type="checkbox"
        id={@id}
        class={["toggle shrink-0 mt-0.5", @toggle_class]}
        checked={@checked}
        phx-click={@event}
        {@rest}
      />
    </label>
    """
  end

  @doc """
  A setting whose control is not a toggle — a link, a button group, a
  small form — passed as the inner block.
  """
  attr :id, :string, default: nil
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :note, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, required: true, doc: "The control(s), rendered on the right"

  def setting_row(assigns) do
    ~H"""
    <div id={@id} class={["flex flex-wrap items-center justify-between gap-4 py-3", @class]}>
      <div class="min-w-0 flex-1">
        <p class="font-medium">{@title}</p>
        <p :if={@description} class="text-sm text-base-content/60 mt-1">{@description}</p>
        <p :if={@note} class="text-xs text-base-content/50 mt-1">{@note}</p>
      </div>
      <div class="shrink-0 flex items-center gap-2">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
