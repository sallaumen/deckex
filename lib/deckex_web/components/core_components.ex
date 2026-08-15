defmodule DeckexWeb.CoreComponents do
  @moduledoc """
  Chrome that Phoenix itself expects: flashes, buttons, form inputs, headers,
  tables and the Heroicon wrapper.

  These are the generator's components, restyled onto the "A Mesa" tokens.
  daisyUI is gone — it carried a light theme this app must never have — so
  every class here resolves through `assets/css/tokens.css`. The product
  vocabulary (mana pips, findings, card tiles) lives in `DeckexWeb.UI`.

  Useful references:

    * [Tailwind CSS](https://tailwindcss.com) - the foundational framework
      we build on. You will use it for layout, sizing, flexbox, grid, and
      spacing.

    * [Heroicons](https://heroicons.com) - see `icon/1` for usage.

    * [Phoenix.Component](https://phoenix-live-view.hexdocs.pm/Phoenix.Component.html) -
      the component system used by Phoenix. Some components, such as `<.link>`
      and `<.form>`, are defined there.

  """
  use Phoenix.Component

  alias DeckexWeb.UI.Format
  alias Phoenix.HTML.Form
  alias Phoenix.HTML.FormField
  alias Phoenix.LiveView.JS

  # Shared field chrome. Inputs are recessed into the table (`inlay`), the one
  # surface step below the mat — see The Felt Rule in DESIGN.md. These are
  # functions rather than module attributes because `@name` inside `~H` means
  # `assigns.name`, not the attribute.
  defp field_class do
    "w-full rounded-md border bg-inlay px-3 py-2 text-body text-ink " <>
      "placeholder:text-ink-faint focus:border-ink-faint disabled:opacity-40"
  end

  # The border colour is applied separately from `field_class/0`: two `border-*`
  # colour utilities on one element are resolved by Tailwind's own output order,
  # not by the order they appear in the attribute, so the resting border must
  # not be in the base string or the invalid state silently loses.
  defp border_class([], _override), do: "border-hairline-soft"
  defp border_class(_errors, nil), do: "border-sev-critical"
  defp border_class(_errors, override), do: override

  defp label_class,
    do: "mb-1.5 block text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"

  @doc """
  Renders flash notices.

  ## Examples

      <.flash kind={:info} flash={@flash} />
      <.flash
        id="welcome-back"
        kind={:info}
        phx-mounted={show("#welcome-back") |> JS.remove_attribute("hidden")}
        hidden
      >
        Welcome Back!
      </.flash>
  """
  attr :id, :string, doc: "the optional id of flash container"
  attr :flash, :map, default: %{}, doc: "the map of flash messages to display"
  attr :title, :string, default: nil
  attr :kind, :atom, values: [:info, :error], doc: "used for styling and flash lookup"
  attr :rest, :global, doc: "the arbitrary HTML attributes to add to the flash container"

  slot :inner_block, doc: "the optional inner block that renders the flash message"

  def flash(assigns) do
    assigns = assign_new(assigns, :id, fn -> "flash-#{assigns.kind}" end)

    ~H"""
    <div
      :if={msg = render_slot(@inner_block) || Phoenix.Flash.get(@flash, @kind)}
      id={@id}
      phx-click={JS.push("lv:clear-flash", value: %{key: @kind}) |> hide("##{@id}")}
      role="alert"
      class="fixed right-4 top-4 z-50 w-80 sm:w-96"
      style={"--c:#{Format.severity_var(if(@kind == :error, do: :critical, else: :healthy))}"}
      {@rest}
    >
      <div
        class="flex items-start gap-2.5 rounded-lg border bg-surface px-3.5 py-3 shadow-lifted"
        style="border-color:color-mix(in srgb, var(--c) 30%, transparent)"
      >
        <.icon
          name={if @kind == :error, do: "hero-exclamation-circle", else: "hero-information-circle"}
          class="mt-px size-4 shrink-0"
          style="color:var(--c)"
        />
        <div class="min-w-0 flex-1">
          <p :if={@title} class="text-body font-semibold text-ink">{@title}</p>
          <p class="text-body text-ink-secondary">{msg}</p>
        </div>
        <button
          type="button"
          class="shrink-0 text-ink-faint transition-colors hover:text-ink"
          aria-label="Fechar"
        >
          <.icon name="hero-x-mark" class="size-4" />
        </button>
      </div>
    </div>
    """
  end

  @doc """
  Renders a button with navigation support.

  The primary variant is a solid ink fill with felt-coloured text: the loudest
  thing the chrome is allowed to be, because every saturated hue in this app
  already means a mana colour or a severity.

  The danger variant is the one exception to that rule, and it stays an
  *outline*: destructive actions must be recognisable before they are clicked,
  and a filled red button competes with the critical findings — the thing on
  screen that actually needs attention.

  ## Examples

      <.button>Colar lista</.button>
      <.button phx-click="go" variant="primary">Importar</.button>
      <.button phx-click="delete" variant="danger" data-confirm="Apagar?">Apagar</.button>
      <.button navigate={~p"/"}>Mesa</.button>
  """
  # `type` is here so the same component can submit a form; without it a form's
  # button falls back to the browser default and the markup lies about intent.
  attr :rest, :global,
    include: ~w(href navigate patch method download name value disabled type phx-disable-with)

  attr :class, :any, default: nil, doc: "added to the variant's classes, never replacing them"
  attr :variant, :string, values: ~w(primary danger)
  slot :inner_block, required: true

  def button(%{rest: rest} = assigns) do
    # min-h-touch is 44px: the floor for a touch target. A button that only looks
    # tappable on a mouse is a button that misses on a phone.
    base =
      "inline-flex min-h-touch items-center justify-center gap-1.5 rounded-md px-3 py-2 " <>
        "text-body font-semibold transition-colors disabled:opacity-40 disabled:cursor-not-allowed"

    variants = %{
      "primary" => "bg-ink text-felt hover:bg-ink-secondary",
      "danger" =>
        "border border-sev-critical/50 bg-transparent text-sev-critical " <>
          "hover:border-sev-critical hover:bg-sev-critical/10",
      nil => "border border-hairline-soft bg-surface-2 text-ink-secondary hover:text-ink"
    }

    # Appended, not replaced: a caller asking for `w-full` wants a full-width
    # button, not a button stripped of every style it had.
    assigns =
      assign(assigns, :class, [base, Map.fetch!(variants, assigns[:variant]), assigns.class])

    if rest[:href] || rest[:navigate] || rest[:patch] do
      ~H"""
      <.link class={@class} {@rest}>
        {render_slot(@inner_block)}
      </.link>
      """
    else
      ~H"""
      <button class={@class} {@rest}>
        {render_slot(@inner_block)}
      </button>
      """
    end
  end

  @doc """
  Renders an input with label and error messages.

  A `Phoenix.HTML.FormField` may be passed as argument,
  which is used to retrieve the input name, id, and values.
  Otherwise all attributes may be passed explicitly.

  ## Types

  This function accepts all HTML input types, considering that:

    * You may also set `type="select"` to render a `<select>` tag

    * `type="checkbox"` is used exclusively to render boolean values

    * For live file uploads, see `Phoenix.Component.live_file_input/1`

  See https://developer.mozilla.org/en-US/docs/Web/HTML/Element/input
  for more information. Unsupported types, such as radio, are best
  written directly in your templates.

  ## Examples

  ```heex
  <.input field={@form[:email]} type="email" />
  <.input name="my-input" errors={["oh no!"]} />
  ```

  ## Select type

  When using `type="select"`, you must pass the `options` and optionally
  a `value` to mark which option should be preselected.

  ```heex
  <.input field={@form[:user_type]} type="select" options={["Admin": "admin", "User": "user"]} />
  ```

  For more information on what kind of data can be passed to `options` see
  [`options_for_select`](https://phoenix-html.hexdocs.pm/Phoenix.HTML.Form.html#options_for_select/2).
  """
  attr :id, :any, default: nil
  attr :name, :any
  attr :label, :string, default: nil
  attr :value, :any

  attr :type, :string,
    default: "text",
    values: ~w(checkbox color date datetime-local email file month number password
               search select tel text textarea time url week hidden)

  attr :field, FormField,
    doc: "a form field struct retrieved from the form, for example: @form[:email]"

  attr :errors, :list, default: []
  attr :checked, :boolean, doc: "the checked flag for checkbox inputs"
  attr :prompt, :string, default: nil, doc: "the prompt for select inputs"
  attr :options, :list, doc: "the options to pass to Phoenix.HTML.Form.options_for_select/2"
  attr :multiple, :boolean, default: false, doc: "the multiple flag for select inputs"
  attr :class, :any, default: nil, doc: "the input class to use over defaults"
  attr :error_class, :any, default: nil, doc: "the input error class to use over defaults"

  attr :rest, :global,
    include: ~w(accept autocomplete capture cols disabled form list max maxlength min minlength
                multiple pattern placeholder readonly required rows size step)

  def input(%{field: %FormField{} = field} = assigns) do
    errors = if Phoenix.Component.used_input?(field), do: field.errors, else: []

    assigns
    |> assign(field: nil, id: assigns.id || field.id)
    |> assign(:errors, Enum.map(errors, &translate_error(&1)))
    |> assign_new(:name, fn -> if assigns.multiple, do: field.name <> "[]", else: field.name end)
    |> assign_new(:value, fn -> field.value end)
    |> input()
  end

  def input(%{type: "hidden"} = assigns) do
    ~H"""
    <input type="hidden" id={@id} name={@name} value={@value} {@rest} />
    """
  end

  def input(%{type: "checkbox"} = assigns) do
    assigns =
      assign_new(assigns, :checked, fn ->
        Form.normalize_value("checkbox", assigns[:value])
      end)

    ~H"""
    <div class="mb-3">
      <label for={@id} class="flex items-center gap-2 text-body text-ink-secondary">
        <input
          type="hidden"
          name={@name}
          value="false"
          disabled={@rest[:disabled]}
          form={@rest[:form]}
        />
        <input
          type="checkbox"
          id={@id}
          name={@name}
          value="true"
          checked={@checked}
          class={@class || "size-4 rounded-xs border-hairline-strong bg-inlay text-ink"}
          {@rest}
        />{@label}
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "select"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id}>
        <span :if={@label} class={label_class()}>{@label}</span>
        <select
          id={@id}
          name={@name}
          class={[@class || field_class(), border_class(@errors, @error_class)]}
          multiple={@multiple}
          {@rest}
        >
          <option :if={@prompt} value="">{@prompt}</option>
          {Form.options_for_select(@options, @value)}
        </select>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  def input(%{type: "textarea"} = assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id}>
        <span :if={@label} class={label_class()}>{@label}</span>
        <textarea
          id={@id}
          name={@name}
          class={[
            @class || [field_class(), "font-mono leading-relaxed"],
            border_class(@errors, @error_class)
          ]}
          {@rest}
        >{Form.normalize_value("textarea", @value)}</textarea>
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # All other inputs text, datetime-local, url, password, etc. are handled here...
  def input(assigns) do
    ~H"""
    <div class="mb-3">
      <label for={@id}>
        <span :if={@label} class={label_class()}>{@label}</span>
        <input
          type={@type}
          name={@name}
          id={@id}
          value={Form.normalize_value(@type, @value)}
          class={[@class || field_class(), border_class(@errors, @error_class)]}
          {@rest}
        />
      </label>
      <.error :for={msg <- @errors}>{msg}</.error>
    </div>
    """
  end

  # Helper used by inputs to generate form errors
  defp error(assigns) do
    ~H"""
    <p
      class="mt-1.5 flex items-center gap-1.5 text-caption"
      style={"color:#{Format.severity_var(:critical)}"}
    >
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  @doc """
  Renders a header with title.
  """
  slot :inner_block, required: true
  slot :subtitle
  slot :actions

  def header(assigns) do
    ~H"""
    <header class={[@actions != [] && "flex items-end justify-between gap-6", "pb-5"]}>
      <div class="min-w-0">
        <h1 class="text-heading font-semibold leading-tight text-ink">
          {render_slot(@inner_block)}
        </h1>
        <p :if={@subtitle != []} class="mt-1 text-body text-ink-muted">
          {render_slot(@subtitle)}
        </p>
      </div>
      <div class="flex-none">{render_slot(@actions)}</div>
    </header>
    """
  end

  @doc """
  Renders a table with generic styling.

  ## Examples

      <.table id="users" rows={@users}>
        <:col :let={user} label="id">{user.id}</:col>
        <:col :let={user} label="username">{user.username}</:col>
      </.table>
  """
  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :row_id, :any, default: nil, doc: "the function for generating the row id"
  attr :row_click, :any, default: nil, doc: "the function for handling phx-click on each row"

  attr :row_item, :any,
    default: &Function.identity/1,
    doc: "the function for mapping each row before calling the :col and :action slots"

  slot :col, required: true do
    attr :label, :string
  end

  slot :action, doc: "the slot for showing user actions in the last table column"

  def table(assigns) do
    assigns =
      with %{rows: %Phoenix.LiveView.LiveStream{}} <- assigns do
        assign(assigns, row_id: assigns.row_id || fn {id, _item} -> id end)
      end

    ~H"""
    <table class="w-full border-collapse text-body">
      <thead>
        <tr class="border-b border-hairline-soft">
          <th
            :for={col <- @col}
            class="px-3 py-2 text-left text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
          >
            {col[:label]}
          </th>
          <th :if={@action != []} class="px-3 py-2">
            <span class="sr-only">Ações</span>
          </th>
        </tr>
      </thead>
      <tbody id={@id} phx-update={is_struct(@rows, Phoenix.LiveView.LiveStream) && "stream"}>
        <tr
          :for={row <- @rows}
          id={@row_id && @row_id.(row)}
          class="border-b border-hairline hover:bg-surface-2"
        >
          <td
            :for={col <- @col}
            phx-click={@row_click && @row_click.(row)}
            class={["px-3 py-2.5 text-ink-secondary", @row_click && "hover:cursor-pointer"]}
          >
            {render_slot(col, @row_item.(row))}
          </td>
          <td :if={@action != []} class="w-0 px-3 py-2.5">
            <div class="flex gap-3">
              <%= for action <- @action do %>
                {render_slot(action, @row_item.(row))}
              <% end %>
            </div>
          </td>
        </tr>
      </tbody>
    </table>
    """
  end

  @doc """
  Renders a data list.

  ## Examples

      <.list>
        <:item title="Title">{@post.title}</:item>
        <:item title="Views">{@post.views}</:item>
      </.list>
  """
  slot :item, required: true do
    attr :title, :string, required: true
  end

  def list(assigns) do
    ~H"""
    <ul class="divide-y divide-[color:var(--hairline)]">
      <li :for={item <- @item} class="flex flex-wrap items-baseline gap-x-4 gap-y-1 py-2.5">
        <div class="w-40 shrink-0 text-label font-semibold uppercase tracking-[0.1em] text-ink-faint">
          {item.title}
        </div>
        <div class="min-w-0 flex-1 text-body text-ink-secondary">{render_slot(item)}</div>
      </li>
    </ul>
    """
  end

  @doc """
  Renders a [Heroicon](https://heroicons.com).

  Heroicons come in three styles – outline, solid, and mini.
  By default, the outline style is used, but solid and mini may
  be applied by using the `-solid` and `-mini` suffix.

  You can customize the size and colors of the icons by setting
  width, height, and background color classes.

  Icons are extracted from the `deps/heroicons` directory and bundled within
  your compiled app.css by the plugin in `assets/vendor/heroicons.js`.

  ## Examples

      <.icon name="hero-x-mark" />
      <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
  """
  attr :name, :string, required: true
  attr :class, :any, default: "size-4"
  attr :rest, :global

  def icon(%{name: "hero-" <> _} = assigns) do
    ~H"""
    <span class={[@name, @class]} {@rest} />
    """
  end

  ## JS Commands

  def show(js \\ %JS{}, selector) do
    JS.show(js,
      to: selector,
      time: 300,
      transition:
        {"transition-all ease-out duration-300",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95",
         "opacity-100 translate-y-0 sm:scale-100"}
    )
  end

  def hide(js \\ %JS{}, selector) do
    JS.hide(js,
      to: selector,
      time: 200,
      transition:
        {"transition-all ease-in duration-200", "opacity-100 translate-y-0 sm:scale-100",
         "opacity-0 translate-y-4 sm:translate-y-0 sm:scale-95"}
    )
  end

  @doc """
  Translates an error message using gettext.
  """
  def translate_error({msg, opts}) do
    # You can make use of gettext to translate error messages by
    # uncommenting and adjusting the following code:

    # if count = opts[:count] do
    #   Gettext.dngettext(DeckexWeb.Gettext, "errors", msg, msg, count, opts)
    # else
    #   Gettext.dgettext(DeckexWeb.Gettext, "errors", msg, opts)
    # end

    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  @doc """
  Translates the errors for a field from a keyword list of errors.
  """
  def translate_errors(errors, field) when is_list(errors) do
    for {^field, {msg, opts}} <- errors, do: translate_error({msg, opts})
  end
end
