defmodule DeckexWeb.UI do
  @moduledoc """
  The "A Mesa" component vocabulary: the small pieces every deckex screen is
  built from — mana pips, mana costs, colour identity, stat tiles, findings,
  card tiles and curve bars.

  Nothing here writes a colour. Every tone is resolved by `DeckexWeb.UI.Format`,
  which maps a mana colour or a finding severity onto a design token exactly
  once; a component that needs a literal hex is a hole in the token set, not a
  local fix. `DESIGN.md` records the rules these components enforce.

  User-facing strings are pt-BR. Card names are data and are never translated.
  """
  use Phoenix.Component
  use DeckexWeb, :verified_routes

  alias Deckex.Cards.PlayRate
  alias Deckex.Money
  alias DeckexWeb.UI.Format

  @identity_slots ~w(W U B R G)

  defdelegate mana_symbols(cost), to: Format
  defdelegate color_label(code), to: Format
  defdelegate sort_colors(codes), to: Format
  defdelegate severity_label(severity), to: Format
  defdelegate percent(share), to: Format

  @doc """
  A single mana pip: a coloured disc carrying a drawn glyph, or a mono numeral
  for generic and variable costs.

  Takes a symbol map from `DeckexWeb.UI.Format.mana_symbols/1` rather than a
  raw string, so the parsing happens once per cost instead of once per pip.
  The pip is `aria-hidden`; the accessible name belongs to whatever wraps it
  (`mana_cost/1` and `color_identity/1` both supply one).

  ## Examples

      <.mana_pip symbol={hd(Format.mana_symbols("{G}"))} />
      <.mana_pip symbol={hd(Format.mana_symbols("{2/W}"))} size={20} />
  """
  attr :symbol, :map, required: true, doc: "a symbol map from `Format.mana_symbols/1`"
  attr :size, :integer, default: 16, doc: "the pip diameter, in px"

  attr :absent, :boolean,
    default: false,
    doc: "draw the slot as an empty ring (see `color_identity/1`)"

  attr :class, :any, default: nil

  def mana_pip(assigns) do
    assigns =
      assigns
      |> assign(:glyph, Format.pip_glyph(assigns.symbol))
      |> assign(:text, Format.pip_text(assigns.symbol))
      |> assign(:name, Format.symbol_label(assigns.symbol))

    ~H"""
    <span
      class={["pip", @absent && "pip-absent", @class]}
      style={pip_style(@symbol, @size, @absent)}
      title={@name}
      aria-hidden="true"
    >
      <.mana_glyph :if={@glyph} name={@glyph} />
      <span :if={@text}>{@text}</span>
    </span>
    """
  end

  # An absent slot keeps its geometry but drops the disc, so `.pip-absent` can
  # own the appearance without a background fighting it.
  defp pip_style(symbol, size, absent) do
    geometry = "width:#{size}px;height:#{size}px;font-size:#{max(round(size * 0.56), 9)}px"

    if absent, do: geometry, else: geometry <> ";--pip:#{Format.pip_background(symbol)}"
  end

  @doc """
  A colour identity row.

  By default it prints only the colours the deck actually has. Pass `full` in a
  grid — every deck then keeps the same five slots in WUBRG order with the
  absent ones dropped to a hairline ring, so two decks can be compared by
  scanning down a column instead of reading each row.

  ## Examples

      <.color_identity colors={["G", "U"]} />
      <.color_identity colors={@deck.color_identity} full size={13} />
  """
  attr :colors, :list,
    default: [],
    doc: ~S(colour codes, e.g. `["U", "R"]`; order does not matter)

  attr :size, :integer, default: 14
  attr :full, :boolean, default: false, doc: "keep all five WUBRG slots, dimming the absent ones"
  attr :class, :any, default: nil

  def color_identity(assigns) do
    present = Format.sort_colors(assigns.colors)

    assigns =
      assigns
      |> assign(:present, present)
      |> assign(:slots, if(assigns.full, do: @identity_slots, else: identity_slots(present)))

    ~H"""
    <span
      class={["inline-flex items-center gap-[3px]", @class]}
      role="img"
      aria-label={identity_label(@present)}
    >
      <.mana_pip
        :for={code <- @slots}
        symbol={color_symbol(code)}
        size={@size}
        absent={code not in @present}
      />
    </span>
    """
  end

  defp identity_slots([]), do: ["C"]
  defp identity_slots(present), do: present

  defp identity_label([]), do: "Identidade de cor: incolor"

  defp identity_label(present) do
    "Identidade de cor: " <>
      Enum.map_join(present, ", ", &String.downcase(Format.color_label(&1)))
  end

  defp color_symbol(code) do
    %{kind: :color, raw: "{#{code}}", label: code, colors: [code]}
  end

  @doc """
  A whole mana cost, rendered as pips.

  Renders nothing when the cost is `nil` or empty — a land has no mana cost,
  and that is not a missing value.

  ## Examples

      <.mana_cost cost="{3}{G}{U}{R}" />
      <.mana_cost cost={@card.mana_cost} size={18} />
  """
  attr :cost, :string, default: nil
  attr :size, :integer, default: 16
  attr :class, :any, default: nil

  def mana_cost(assigns) do
    assigns = assign(assigns, :symbols, Format.mana_symbols(assigns.cost))

    ~H"""
    <span
      :if={@symbols != []}
      class={["inline-flex items-center gap-[3px]", @class]}
      role="img"
      aria-label={Format.mana_cost_label(@cost)}
    >
      <.mana_pip :for={symbol <- @symbols} symbol={symbol} size={@size} />
    </span>
    """
  end

  @doc """
  A measured value: a label, a monospaced numeral, and the baseline it is
  measured against.

  `value` arrives already formatted — use `DeckexWeb.UI.Format.decimal/2` or
  `percent/1` so the pt-BR decimal comma is applied in one place. Only
  `:critical` and `:warning` tint the tile's edge; `:healthy` colours the
  numeral and stops there, because a panel where everything glows teaches
  nothing.

  ## Examples

      <.stat label="Terrenos" value="34" target="alvo 36" tone={:warning} />
      <.stat label="CMC médio" value={Format.decimal(3.24)} tone={:healthy} />
  """
  attr :label, :string, required: true, doc: "pt-BR; rendered uppercase"
  attr :value, :string, required: true, doc: "already formatted for display"
  attr :unit, :string, default: nil, doc: ~S(a short suffix, e.g. `"pontos"` or `"%"`)
  attr :target, :string, default: nil, doc: ~S(the baseline behind it, e.g. `"alvo 36"`)
  attr :tone, :atom, values: [:neutral, :critical, :warning, :healthy, :info], default: :neutral
  attr :class, :any, default: nil
  slot :inner_block, doc: "an optional note under the numeral"

  def stat(assigns) do
    ~H"""
    <div
      class={["rounded-lg border bg-surface px-4 py-3", @class]}
      style={"--c:#{Format.tone_var(@tone)};border-color:#{stat_border(@tone)}"}
    >
      <p class="text-label font-semibold uppercase tracking-[0.12em] text-ink-faint">{@label}</p>
      <p class="mt-2 flex items-baseline gap-1.5">
        <span class="font-mono text-numeral font-semibold leading-none" style="color:var(--c)">
          {@value}
        </span>
        <span :if={@unit} class="text-caption text-ink-muted">{@unit}</span>
      </p>
      <p :if={@target} class="mt-1.5 text-caption tabular-nums text-ink-faint">{@target}</p>
      <div :if={@inner_block != []} class="mt-2 text-caption leading-snug text-ink-secondary">
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end

  # Only an alarm tints its edge; a healthy tile keeps the plain hairline.
  defp stat_border(tone) when tone in [:critical, :warning],
    do: "color-mix(in srgb, var(--c) 32%, transparent)"

  defp stat_border(_tone), do: "var(--hairline)"

  @doc """
  One row of the findings feed: a severity mark, a pt-BR title, the explanation,
  and the cards implicated.

  The severity reads from a dot and a word, never from a coloured edge on the
  container. Critical and warning rows sit on a wash of their own tone; a wash
  keeps its text in `--ink`, so the hue never has to carry contrast.

  ## Examples

      <.finding severity={:critical} title="Fontes de preto insuficientes" code="mana.color_starved"
                cards={["Bolas's Citadel", "Sheoldred, the Apocalypse"]}>
        <:detail>12 fontes de preto para 8 cartas que pedem {B}{B}. O alvo é 25.</:detail>
        <:actions><button type="button">Pedir diagnóstico à IA</button></:actions>
      </.finding>
  """
  attr :severity, :atom, values: [:critical, :warning, :healthy, :info], required: true
  attr :title, :string, required: true, doc: "pt-BR"
  attr :code, :string, default: nil, doc: ~S(the finding code, e.g. `"mana.color_starved"`)
  attr :links, :map, default: %{}, doc: "card name => Scryfall URI, for the chips"

  attr :cards, :list, default: [], doc: "implicated card names — never translated"
  attr :class, :any, default: nil
  slot :detail, doc: "the pt-BR explanation"
  slot :actions, doc: "controls for this finding, e.g. the AI consult button"

  def finding(assigns) do
    ~H"""
    <article
      class={["rounded-lg px-4 py-3.5", finding_surface(@severity), @class]}
      style={"--c:#{Format.severity_var(@severity)}"}
    >
      <div class="flex items-start gap-2.5">
        <span
          class="mt-1.5 size-2 shrink-0 rounded-full"
          style="background:var(--c)"
          aria-hidden="true"
        />
        <div class="min-w-0 flex-1">
          <h3 class="text-body-lg font-semibold leading-snug text-ink">{@title}</h3>
          <p :if={@detail != []} class="mt-1 text-body leading-relaxed text-ink-secondary">
            {render_slot(@detail)}
          </p>
        </div>
        <span
          class="shrink-0 text-label font-semibold uppercase tracking-[0.1em]"
          style="color:var(--c)"
        >
          {Format.severity_label(@severity)}
        </span>
      </div>

      <ul :if={@cards != []} class="mt-3 flex flex-wrap gap-1.5 pl-[18px]">
        <li
          :for={name <- @cards}
          class="rounded-sm bg-chip px-2 py-0.5 text-caption text-ink-secondary transition-colors hover:text-ink motion-reduce:transition-none"
        >
          <.card_link name={name} uri={@links[name]} />
        </li>
      </ul>

      <div :if={@actions != []} class="mt-3 flex flex-wrap items-center gap-2 pl-[18px]">
        {render_slot(@actions)}
      </div>

      <p :if={@code} class="mt-3 pl-[18px] font-mono text-micro text-ink-faint">{@code}</p>
    </article>
    """
  end

  defp finding_surface(severity) when severity in [:critical, :warning], do: "tint"
  defp finding_surface(_severity), do: "border border-hairline bg-surface"

  @doc """
  A card's name, linking to its Scryfall page when we know it.

  Card names are the app's densest information and were, until now, dead text:
  the one question a player asks constantly — *what does this card actually do?*
  — had no answer on the screen. Every name the catalogue knows becomes a way
  to go read the card.

  The underline is **permanent**, not a hover effect. A link discoverable only
  by hovering is invisible to touch and to anyone scanning, and half this app
  is read on a phone at a table.

  A name the catalogue never resolved renders as plain text: an unresolved card
  has nowhere honest to point.

  ## Examples

      <.card_link name="Sol Ring" uri={@card.scryfall_uri} />
      <.card_link name={change["card"]} uri={@card_uris[change["card"]]} />
  """
  attr :name, :string, required: true, doc: "the Scryfall card name — never translated"
  attr :uri, :string, default: nil, doc: "the card's Scryfall page, or nil when unknown"
  attr :class, :any, default: nil

  def card_link(%{uri: nil} = assigns) do
    ~H"""
    <span class={@class}>{@name}</span>
    """
  end

  def card_link(assigns) do
    ~H"""
    <a
      href={@uri}
      target="_blank"
      rel="noopener noreferrer"
      title={"Ver #{@name} na Scryfall"}
      class={[
        "underline decoration-hairline-strong decoration-dotted underline-offset-[3px]",
        "transition-colors hover:decoration-ink motion-reduce:transition-none",
        @class
      ]}
    >
      {@name}
    </a>
    """
  end

  @doc """
  One labelled setting: its control, its hint, and **its own error**.

  The settings panel used to hand-roll every box and put the one error message
  it could hold at the top of a nineteen-field form — so a typo in the eighth
  box printed "valor inválido" somewhere above the fold, next to none of them,
  and the box kept showing the rejected value as if it had been accepted. This
  component exists so that never depends on remembering.

  Three rules it enforces by being the only way to draw a field:

    * the error renders **under the field it belongs to**, never at the top;
    * a field carrying an error says so on its border as well as in words,
      because colour alone is not a message;
    * `saved` is the confirmation the panel promises — a form that saves by
      itself has to show that it did, where the eye already is.

  ## Examples

      <.field id="ceiling" name="setting[value]" label="Teto" value={@v} error={@errors["ceiling"]} />
      <.field id="model" name="setting[value]" label="Modelo" options={~w(fable opus)} value={@m} />
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :options, :list, default: nil, doc: "renders a select when given"
  attr :hint, :string, default: nil
  attr :error, :string, default: nil
  attr :saved, :boolean, default: false
  attr :numeric, :boolean, default: false
  attr :rows, :integer, default: nil, doc: "renders a textarea when given"
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(disabled placeholder)

  def field(assigns) do
    ~H"""
    <div class={["min-w-0", @class]}>
      <label
        for={@id}
        class="mb-1 flex items-baseline gap-2 text-caption font-semibold text-ink-secondary"
      >
        {@label}
        <span :if={@saved && is_nil(@error)} class="font-mono text-micro text-sev-healthy">
          salvo
        </span>
      </label>

      <select
        :if={@options}
        id={@id}
        name={@name}
        aria-invalid={to_string(not is_nil(@error))}
        aria-describedby={@error && "#{@id}-error"}
        class={[
          "min-h-touch w-full rounded-md border bg-inlay px-3 py-2 text-body text-ink",
          border(@error)
        ]}
        {@rest}
      >
        <option
          :for={option <- @options}
          value={option}
          selected={to_string(@value) == to_string(option)}
        >
          {option}
        </option>
      </select>

      <textarea
        :if={is_nil(@options) && @rows}
        id={@id}
        name={@name}
        rows={@rows}
        phx-debounce="blur"
        aria-invalid={to_string(not is_nil(@error))}
        aria-describedby={@error && "#{@id}-error"}
        class={[control(), @numeric && "font-mono", border(@error)]}
        {@rest}
      >{@value}</textarea>

      <input
        :if={is_nil(@options) && is_nil(@rows)}
        id={@id}
        type="text"
        name={@name}
        value={@value}
        inputmode={if @numeric, do: "decimal"}
        phx-debounce="blur"
        aria-invalid={to_string(not is_nil(@error))}
        aria-describedby={@error && "#{@id}-error"}
        class={[control(), "min-h-touch", @numeric && "font-mono", border(@error)]}
        {@rest}
      />

      <p :if={@hint && is_nil(@error)} class="mt-1 text-micro text-ink-muted">{@hint}</p>

      <%!-- Under its own field, with the reason. `role="alert"` so the message
            reaches a screen reader the moment the save comes back refused. --%>
      <p :if={@error} id={"#{@id}-error"} role="alert" class="mt-1 text-micro text-sev-critical">
        {@error}
      </p>
    </div>
    """
  end

  @doc """
  The class string every form control in this app wears.

  One padding and one type size. Before this there were three of each — `px-2`,
  `px-3` and `px-4`, `text-caption` and `text-body-lg` — sitting side by side in
  the same form, because each screen wrote its own string. `font-mono` is the
  only variation left, and it means "this is a number you will read", not "this
  screen felt like it".

  `field/1` is the way to draw a control and applies this itself. This is
  public for the handful that genuinely need their own markup — a `<select>`
  whose options carry a label different from their value, for one — so that
  needing custom markup never means inventing custom spacing.
  """
  @spec control_class() :: String.t()
  def control_class do
    "w-full rounded-md border border-hairline-soft bg-inlay px-3 py-2 text-caption text-ink " <>
      "placeholder:text-ink-faint focus:border-ink-faint"
  end

  defp control do
    "w-full rounded-md border bg-inlay px-3 py-2 text-caption text-ink placeholder:text-ink-faint"
  end

  defp border(nil), do: "border-hairline-soft focus:border-ink-faint"
  defp border(_error), do: "border-sev-critical"

  @doc """
  The four screens one deck has, as one row of links.

  It exists because the app grew four of them — the list, the owner's standing
  decisions about cards, the version line, the rounds — and each screen only
  linked back to the one it came from. Reaching the versions of a deck from its
  optimizations meant going back to the deck first. Four screens that are one
  subject should look like one subject, and the row makes that true on every
  page instead of once per page.

  The current screen is a link to nowhere, on purpose: keeping the item in
  place stops the row reflowing as you move between screens.

  ## Examples

      <.deck_nav deck={@deck} current={:cards} />
  """
  attr :deck, :map, required: true
  attr :current, :atom, values: [:deck, :cards, :versions, :runs], required: true
  attr :class, :any, default: nil

  def deck_nav(assigns) do
    ~H"""
    <nav aria-label="Este deck" class={["-mx-1 flex flex-wrap items-center gap-x-1", @class]}>
      <.deck_nav_item
        :for={{key, label, path} <- deck_nav_items(@deck)}
        current={key == @current}
        label={label}
        path={path}
      />
    </nav>
    """
  end

  defp deck_nav_items(deck) do
    [
      {:deck, "Deck", ~p"/decks/#{deck.id}"},
      {:cards, "Cartas", ~p"/decks/#{deck.id}/cartas"},
      {:versions, "Versões", ~p"/decks/#{deck.id}/versoes"},
      {:runs, "Rodadas", ~p"/decks/#{deck.id}/otimizacoes"}
    ]
  end

  attr :current, :boolean, required: true
  attr :label, :string, required: true
  attr :path, :string, required: true

  defp deck_nav_item(%{current: true} = assigns) do
    ~H"""
    <span
      aria-current="page"
      class="inline-flex min-h-touch items-center rounded-md bg-inlay px-3 text-caption font-semibold text-ink"
    >
      {@label}
    </span>
    """
  end

  defp deck_nav_item(assigns) do
    ~H"""
    <.link
      navigate={@path}
      class="inline-flex min-h-touch items-center rounded-md px-3 text-caption text-ink-faint transition-colors hover:bg-inlay hover:text-ink motion-reduce:transition-none"
    >
      {@label}
    </.link>
    """
  end

  @doc """
  What the owner decided about a card, as a chip.

  Three stances, and only two of them are orders — so only two of them get a
  colour. An observation is knowledge the model carries; a lock is a rule the
  engine enforces; a request is a card he is asking for. The chip says which,
  in a word, because "trancada" and "pedida" being one colour apart would make
  a list of them unreadable at a glance.

  ## Examples

      <.card_stance stance={rule.stance} />
  """
  attr :stance, :atom, values: [:locked, :wanted, :note], required: true
  attr :class, :any, default: nil

  def card_stance(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center rounded-md px-1.5 py-0.5 text-micro font-semibold uppercase tracking-[0.08em]",
      stance_tone(@stance),
      @class
    ]}>
      {stance_label(@stance)}
    </span>
    """
  end

  @doc "The pt-BR name of a stance, singular."
  @spec stance_label(atom()) :: String.t()
  def stance_label(:locked), do: "obrigatória"
  def stance_label(:wanted), do: "pedida"
  def stance_label(:note), do: "observação"

  @doc "The pt-BR name of a stance as a heading, plural."
  @spec stance_heading(atom()) :: String.t()
  def stance_heading(:locked), do: "Obrigatórias"
  def stance_heading(:wanted), do: "Pedidas"
  def stance_heading(:note), do: "Observações"

  defp stance_tone(:locked), do: "bg-sev-critical/15 text-sev-critical"
  defp stance_tone(:wanted), do: "bg-sev-info/15 text-sev-info"
  defp stance_tone(:note), do: "bg-inlay text-ink-faint"

  @doc """
  Why a consult failed, in the two registers a failure needs.

  The sentence says what happened in pt-BR. The disclosure under it carries the
  **evidence** — the code, how long it ran, and whatever the adapter actually
  saw. A run once failed with "A IA retornou erro." and nothing else, on the
  screen or in the terminal, while the `claude` CLI had said exactly what was
  wrong the whole time.

  The evidence is folded away, not omitted. It is unreadable on a normal day
  and the only thing that matters on a bad one, and a `<details>` is the one
  control that serves both without a second screen.

  A consult from before the evidence columns existed renders the sentence
  alone: there is nothing honest to unfold.

  ## Examples

      <.failure consult={step.consult} />
  """
  attr :consult, :map, required: true, doc: "a failed consult"
  attr :class, :any, default: nil

  def failure(assigns) do
    assigns = assign(assigns, :evidence, evidence(assigns.consult))

    ~H"""
    <div class={["rounded-lg tint px-4 py-3", @class]} style={"--c:#{Format.severity_var(:critical)}"}>
      <p class="text-body font-semibold text-ink">{@consult.error || "A etapa falhou."}</p>

      <details :if={@evidence != []} class="group mt-2">
        <%!-- A <summary> is a control that reads as text, so it gets a
              control's hit area — the suite fails otherwise, and it is right
              to: this is the one thing on a failed run anyone taps. --%>
        <summary class="inline-flex min-h-touch cursor-pointer items-center text-caption text-ink-muted underline decoration-hairline-strong underline-offset-2 hover:text-ink">
          O que a IA respondeu
        </summary>
        <dl class="mt-2 space-y-2">
          <div :for={{label, value} <- @evidence}>
            <dt class="text-micro font-semibold uppercase tracking-[0.08em] text-ink-faint">
              {label}
            </dt>
            <%!-- `whitespace-pre-wrap` keeps the model's own line breaks — and
                  it would keep this template's indentation too, so the value
                  sits tight against its tags. --%>
            <dd
              phx-no-format
              class="mt-0.5 max-h-72 overflow-auto whitespace-pre-wrap break-words rounded-sm bg-inlay px-2 py-1 font-mono text-micro text-ink-secondary"
            >{value}</dd>
          </div>
        </dl>
      </details>
    </div>
    """
  end

  # The evidence, flattened to label/text pairs in the order a person reads
  # them: what it was, how long it took, then what was actually said.
  defp evidence(consult) do
    header = [{"código", consult.error_code}, {"durou", duration(consult.duration_ms)}]

    Enum.reject(header ++ detail_lines(consult.error_details), fn {_label, value} ->
      value in [nil, ""]
    end)
  end

  defp duration(nil), do: nil
  defp duration(ms) when ms < 1000, do: "#{ms} ms"
  defp duration(ms), do: "#{Float.round(ms / 1000, 1)} s"

  defp detail_lines(details) when is_map(details) do
    details
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> {detail_label(key), detail_text(value)} end)
  end

  defp detail_lines(_absent), do: []

  @detail_labels %{
    "result" => "resposta",
    "output" => "saída",
    "envelope" => "envelope",
    "reason" => "motivo",
    "timeout_ms" => "limite"
  }

  defp detail_label(key), do: Map.get(@detail_labels, key, key)

  defp detail_text(value) when is_binary(value), do: value
  defp detail_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp detail_text(nil), do: nil
  defp detail_text(value), do: inspect(value, pretty: true, limit: :infinity)

  @doc """
  How much of Commander plays this card.

  The column that answers the question a price cannot. The owner's instinct was
  that a cheap suggestion is a weak suggestion; his own runs disagree — the
  cheapest card any model suggested him was Arcane Signet, third most-played
  card in the format, and one of the priciest was a card past rank five
  thousand. This is the number that separates them.

  Only the last band gets a colour, per the Quiet-Health Rule: a card everyone
  plays is not news. A card almost nobody plays is not a verdict either — it is
  the one worth reading the reasoning for.

  ## Examples

      <.play_rate card={row.card} />
      <.play_rate rank={card.edhrec_rank} />
  """
  attr :card, :map, default: nil, doc: "a card struct; `rank` is read off it"
  attr :rank, :integer, default: nil, doc: "the rank itself, when there is no card at hand"
  attr :class, :any, default: nil

  def play_rate(assigns) do
    assigns = assign(assigns, :rank, assigns.rank || (assigns.card && assigns.card.edhrec_rank))

    ~H"""
    <span
      :if={@rank}
      title={PlayRate.sentence(@rank)}
      class={[
        "font-mono text-micro",
        if(PlayRate.worth_a_look?(@rank), do: "text-sev-warning", else: "text-ink-faint"),
        @class
      ]}
    >
      {PlayRate.position(@rank)}
    </span>
    """
  end

  @doc """
  What the model has cost, in tokens and in reais.

  Two numbers, always together. Tokens alone answer "how much did it read"
  and cost alone answers "what do I owe" — the owner asks both at once, and a
  meter that shows one of them makes him open a calculator for the other.

  Cache is folded into the total and spelled out in the tooltip. Almost every
  token this app spends is cache: the briefing repeats the same deck, the same
  baselines and the same rules on every stage. A meter that hid that would make
  a ten-stage run look like it read a novel ten times.

  Nothing measured renders nothing. A row of zeros looks like a measurement.

  ## Examples

      <.token_meter totals={@ai_totals} />
      <.token_meter totals={@ai_totals} label="Este deck" size={:lg} />
  """
  attr :totals, :map, required: true, doc: "a `Deckex.AI.Ledger` total"
  attr :label, :string, default: nil, doc: "shown above the numbers when given"
  attr :size, :atom, default: :sm, values: [:sm, :lg]
  attr :class, :any, default: nil

  def token_meter(assigns) do
    ~H"""
    <div :if={@totals.calls > 0} class={@class} title={token_breakdown(@totals)}>
      <p
        :if={@label}
        class="text-label font-semibold uppercase tracking-[0.1em] text-ink-faint"
      >
        {@label}
      </p>
      <p class={[
        "font-mono leading-none text-ink",
        @size == :lg && "text-numeral-sm font-semibold",
        @size == :sm && "text-caption"
      ]}>
        {Money.brl(@totals.cost_usd)}
      </p>
      <p class={[
        "font-mono text-ink-faint",
        @size == :lg && "mt-1 text-micro",
        @size == :sm && "text-micro"
      ]}>
        {token_count(@totals.total_tokens)} tokens · {@totals.calls} chamada(s)
      </p>
    </div>
    """
  end

  @doc """
  A token count at reading scale: `29,9 k`, `1,2 M`.

  Nobody reads seven digits. The exact figure stays in the tooltip, where
  someone checking a bill can find it.
  """
  @spec token_count(non_neg_integer()) :: String.t()
  def token_count(tokens) when tokens >= 1_000_000 do
    "#{decimal_place(tokens / 1_000_000)} M"
  end

  def token_count(tokens) when tokens >= 1_000, do: "#{decimal_place(tokens / 1_000)} k"
  def token_count(tokens), do: Integer.to_string(tokens)

  defp decimal_place(number) do
    number |> Float.round(1) |> :erlang.float_to_binary(decimals: 1) |> String.replace(".", ",")
  end

  # The tooltip carries what the headline number folds together, exact figures
  # included — the headline is for reading, this is for checking.
  defp token_breakdown(totals) do
    """
    entrada #{totals.input_tokens} · saída #{totals.output_tokens} · \
    cache criado #{totals.cache_creation_tokens} · cache lido #{totals.cache_read_tokens} \
    (total #{totals.total_tokens})\
    """
  end

  @doc """
  One optimization in flight, drawn small enough to sit in a list of them.

  The screen this exists for is A Mesa with three runs going at once. Each is
  half an hour of stages landing one at a time, and reading three of them meant
  opening three tabs and refreshing.

  The bar is segmented rather than continuous because the stages are countable
  and their number is the point: ten segments, three filled, one breathing.
  The count is written beside it, never only drawn — a bar alone cannot be read
  by someone who cannot see it, and cannot be read precisely by anyone.
  """
  attr :run, :map, required: true
  attr :deck, :map, required: true
  attr :now, :any, required: true

  def run_progress(assigns) do
    assigns =
      assigns
      |> assign(:total, length(assigns.run.steps))
      |> assign(:done, Enum.count(assigns.run.steps, &(&1.status in [:done, :skipped])))
      |> assign(:current, Enum.find(assigns.run.steps, &(&1.status == :running)))

    ~H"""
    <.link
      navigate={"/otimizacoes/#{@run.id}"}
      class="block rounded-lg border border-hairline-soft bg-surface p-4 transition-colors hover:border-hairline-strong motion-reduce:transition-none"
    >
      <div class="flex flex-wrap items-baseline justify-between gap-x-3 gap-y-1">
        <span class="min-w-0 truncate text-body font-semibold text-ink">{@deck.name}</span>
        <span class={["font-mono text-caption", run_tone(@run.status)]}>
          {run_progress_status(@run, @current)}
        </span>
      </div>

      <div class="mt-2 flex items-center gap-3">
        <div
          role="progressbar"
          aria-valuenow={@done}
          aria-valuemin="0"
          aria-valuemax={@total}
          aria-valuetext={"etapa #{min(@done + 1, @total)} de #{@total}"}
          class="flex min-w-0 flex-1 gap-0.5"
        >
          <span
            :for={step <- @run.steps}
            class={[
              "h-1.5 min-w-0 flex-1 rounded-full",
              step.status in [:done, :skipped] && "bg-ink-faint",
              step.status == :running && "animate-pulse bg-sev-warning motion-reduce:animate-none",
              step.status == :failed && "bg-sev-critical",
              step.status == :pending && "bg-inlay"
            ]}
          />
        </div>

        <%!-- Written, not only drawn: a bar says "some of it" and this says
              which one. --%>
        <span class="shrink-0 font-mono text-micro text-ink-faint">
          {min(@done + 1, @total)}/{@total}
        </span>
      </div>
    </.link>
    """
  end

  defp run_tone(:awaiting_choice), do: "text-sev-warning"
  defp run_tone(:paused), do: "text-ink-faint"
  defp run_tone(_running), do: "text-ink-secondary"

  defp run_progress_status(%{status: :awaiting_choice}, _current), do: "esperando você"
  defp run_progress_status(%{status: :paused}, _current), do: "pausada"
  defp run_progress_status(_run, nil), do: "seguindo"
  defp run_progress_status(_run, current), do: current.label

  @doc """
  A card at a glance: its art, its name, and a way to go read it.

  The dense sibling of `card_tile/1`. Where a tile is the subject of its own
  block, a thumb belongs in a row of several — a proposed direction's key
  cards, a finding's implicated cards — where the art is what a player
  recognises long before the name registers.

  Nothing is ever laid over the art, per the design rule; the name sits under
  it and carries the Scryfall link.

  ## Examples

      <.card_thumb name="Craterhoof Behemoth" art={card.image_art_crop_url} uri={card.scryfall_uri} />
  """
  attr :name, :string, required: true
  attr :art, :string, default: nil
  attr :uri, :string, default: nil
  attr :note, :string, default: nil, doc: "a short line under the name, e.g. a price"
  attr :rank, :integer, default: nil, doc: "the card's play rate, shown beside the note"
  attr :class, :any, default: nil

  def card_thumb(assigns) do
    ~H"""
    <figure class={["w-[104px] shrink-0", @class]}>
      <.thumb_frame name={@name} uri={@uri}>
        <div class="aspect-art w-full overflow-hidden rounded-sm border border-hairline bg-inlay">
          <img
            :if={@art}
            src={@art}
            alt=""
            loading="lazy"
            width="104"
            height="76"
            class="size-full object-cover"
          />
          <div
            :if={is_nil(@art)}
            class="flex size-full items-center justify-center px-1 text-center text-micro text-ink-faint"
          >
            {@name}
          </div>
        </div>
        <figcaption class="mt-1 text-micro leading-tight text-ink-secondary">
          {@name}
        </figcaption>
      </.thumb_frame>
      <p
        :if={@note || @rank}
        class="flex items-baseline gap-1.5 font-mono text-micro leading-tight text-ink-faint"
      >
        {@note}<.play_rate rank={@rank} />
      </p>
    </figure>
    """
  end

  # The art and the name are one target, not two: a 104x100 tile clears the
  # touch minimum comfortably, where the name alone was an 11px sliver.
  attr :name, :string, required: true
  attr :uri, :string, default: nil
  slot :inner_block, required: true

  defp thumb_frame(%{uri: nil} = assigns) do
    ~H"""
    <div>{render_slot(@inner_block)}</div>
    """
  end

  defp thumb_frame(assigns) do
    ~H"""
    <a
      href={@uri}
      target="_blank"
      rel="noopener noreferrer"
      title={"Ver #{@name} na Scryfall"}
      class="block rounded-sm transition-opacity hover:opacity-85 motion-reduce:transition-none"
    >
      {render_slot(@inner_block)}
    </a>
    """
  end

  @doc """
  A card, led by its art.

  The art is never covered: the caption sits in its own strip below the crop,
  separated by a hairline, so nothing is ever laid over the artwork. Without an
  art URL the frame falls back to a recessed well carrying the card's name — a
  tile is never blank.

  ## Examples

      <.card_tile name="Cultivate" art={@card.image_art_crop_url}
                  mana_cost="{2}{G}" type_line="Sorcery" quantity={1} />
      <.card_tile name="Iroh, Dragon of the West" art={@deck.commander_art}>
        <:footer><.color_identity colors={@deck.color_identity} full /></:footer>
      </.card_tile>
  """
  attr :name, :string, required: true, doc: "the Scryfall card name — never translated"
  attr :art, :string, default: nil, doc: "the `art_crop` URL"
  attr :mana_cost, :string, default: nil
  attr :type_line, :string, default: nil
  attr :quantity, :integer, default: nil, doc: "printed as `2×` when greater than one"
  attr :class, :any, default: nil
  slot :footer, doc: "an extra row under the caption, e.g. role chips or a vital sign"

  def card_tile(assigns) do
    ~H"""
    <figure class={[
      "overflow-hidden rounded-card border border-hairline bg-surface shadow-contact",
      @class
    ]}>
      <div class="aspect-art w-full bg-inlay">
        <img
          :if={@art}
          src={@art}
          alt={@name}
          loading="lazy"
          class="h-full w-full object-cover"
        />
        <div :if={!@art} class="flex h-full w-full items-center justify-center px-4 text-center">
          <span class="text-caption leading-snug text-ink-faint">{@name}</span>
        </div>
      </div>

      <figcaption class="border-t border-hairline px-3 py-2.5">
        <div class="flex items-start justify-between gap-2">
          <p class="min-w-0 text-body-lg font-semibold leading-snug text-ink">{@name}</p>
          <.mana_cost :if={@mana_cost} cost={@mana_cost} size={15} class="mt-px shrink-0" />
        </div>
        <div class="mt-1 flex items-center justify-between gap-2">
          <p :if={@type_line} class="min-w-0 truncate text-caption text-ink-muted">{@type_line}</p>
          <span
            :if={@quantity && @quantity > 1}
            class="shrink-0 font-mono text-caption text-ink-faint"
          >
            {@quantity}×
          </span>
        </div>
        <div :if={@footer != []} class="mt-2.5">{render_slot(@footer)}</div>
      </figcaption>
    </figure>
    """
  end

  @doc """
  A card's rules text, with its mana symbols drawn as pips.

  This is the fact a card is actually judged on, and for most of this app's
  life no screen showed it — the same omission the briefing law names as the
  single cause behind its worst misreadings. A person choosing between three
  cards is doing exactly what a stage does, and deserves the same evidence.

  Reminder text — the parenthetical the printed card sets in italics — is set
  in italics here too, because it explains and never rules.

  ## Examples

      <.oracle_text text={@card.oracle_text} />
      <.oracle_text text={@card.oracle_text} clamp={3} />
  """
  attr :text, :string, default: nil
  attr :clamp, :integer, default: nil, doc: "max lines before overflow is hidden"
  attr :class, :any, default: nil

  def oracle_text(%{text: text} = assigns) when text in [nil, ""] do
    ~H""
  end

  def oracle_text(assigns) do
    ~H"""
    <div
      class={["space-y-1.5 text-caption leading-relaxed text-ink-secondary", @class]}
      style={
        @clamp &&
          "display:-webkit-box;-webkit-line-clamp:#{@clamp};-webkit-box-orient:vertical;overflow:hidden"
      }
    >
      <p :for={line <- String.split(@text, "\n", trim: true)} class="[overflow-wrap:anywhere]">
        <span :for={segment <- Format.segments(line)}>
          <.mana_pip :if={elem(segment, 0) == :symbol} symbol={elem(segment, 1)} size={13} />
          <span :if={elem(segment, 0) == :text} class={reminder_class(elem(segment, 1))}>{elem(
            segment,
            1
          )}</span>
        </span>
      </p>
    </div>
    """
  end

  # A parenthetical in rules text is reminder text: it repeats a rule the game
  # already has, and it is set apart on the printed card for the same reason.
  defp reminder_class(text) do
    if String.starts_with?(String.trim_leading(text), "(") do
      "italic text-ink-faint"
    end
  end

  @doc """
  One bucket of the mana-curve histogram.

  `max` is the tallest bucket in the whole histogram and sets the shared scale —
  pass the same value to every bar or the chart lies. An empty bucket still
  draws its baseline tick, so a gap in the curve is visible as a gap rather than
  as nothing.

  Bars rest in ink; a `tone` lights one up only when a lens has a finding about
  that bucket.

  ## Examples

      <.curve_bar :for={{label, count} <- @buckets} label={label} count={count} max={@peak} />
      <.curve_bar label="7+" count={9} max={18} tone={:warning} />
  """
  attr :label, :string, required: true, doc: ~S(the CMC bucket, e.g. `"3"` or `"7+"`)
  attr :count, :integer, required: true
  attr :max, :integer, required: true, doc: "the tallest bucket in this histogram"
  attr :tone, :atom, values: [:neutral, :critical, :warning, :healthy, :info], default: :neutral
  attr :height, :integer, default: 96, doc: "the plot height, in px"
  attr :class, :any, default: nil

  def curve_bar(assigns) do
    ~H"""
    <div
      class={["flex min-w-0 flex-col items-center gap-1.5", @class]}
      style={"--c:#{Format.tone_var(@tone)}"}
    >
      <span class="font-mono text-caption text-ink-muted">{@count}</span>
      <div class="flex w-full items-end" style={"height:#{@height}px"}>
        <div
          class="w-full rounded-t-xs"
          style={bar_style(@count, @max)}
          role="img"
          aria-label={"#{@count} cartas com custo #{@label}"}
        />
      </div>
      <span class="w-full border-t border-hairline pt-1.5 text-center font-mono text-label text-ink-faint">
        {@label}
      </span>
    </div>
    """
  end

  # An empty bucket keeps a 2px tick: a gap in the curve has to read as a gap.
  defp bar_style(0, _peak), do: "height:2px;background:var(--hairline-strong)"

  defp bar_style(count, peak) when peak > 0 do
    # A single card still has to be visible, hence the 4% floor.
    share = Float.round(max(count / peak * 100, 4.0), 1)

    "height:#{share}%;background:linear-gradient(to top," <>
      "color-mix(in srgb, var(--c) 16%, transparent)," <>
      "color-mix(in srgb, var(--c) 40%, transparent))"
  end

  defp bar_style(_count, _peak), do: "height:2px;background:var(--hairline-strong)"

  @doc """
  A drawn mana glyph.

  The shapes are authored SVG on a 16×16 grid, at one stroke weight, filled with
  `currentcolor` — so a pip's glyph inherits the pip's ink and an absent slot's
  glyph dims with it. `DeckexWeb.UI.Format.pip_glyph/1` decides which name a
  symbol gets; this function only draws.

  ## Examples

      <.mana_glyph name={:skull} />
  """
  attr :name, :atom,
    required: true,
    values: [:sun, :drop, :skull, :flame, :tree, :gem, :snow, :tap, :untap, :phyrexian]

  def mana_glyph(%{name: :sun} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <circle cx="8" cy="8" r="3.4" />
      <path d="M8 0l1.15 2.9h-2.3L8 0Zm0 16-1.15-2.9h2.3L8 16ZM0 8l2.9-1.15v2.3L0 8Zm16 0-2.9 1.15v-2.3L16 8ZM2.34 2.34l2.83 1.07-1.76 1.76-1.07-2.83Zm11.32 11.32-2.83-1.07 1.76-1.76 1.07 2.83ZM13.66 2.34l-1.07 2.83-1.76-1.76 2.83-1.07ZM2.34 13.66l1.07-2.83 1.76 1.76-2.83 1.07Z" />
    </svg>
    """
  end

  def mana_glyph(%{name: :drop} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 1.1c2.7 3.1 4.9 5.6 4.9 8.1a4.9 4.9 0 0 1-9.8 0c0-2.5 2.2-5 4.9-8.1Z" />
    </svg>
    """
  end

  def mana_glyph(%{name: :skull} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path
        fill-rule="evenodd"
        d="M8 1.5c-3.3 0-5.8 2.4-5.8 5.5 0 1.9.9 3.4 2.3 4.3v1.8c0 .8.6 1.4 1.4 1.4h4.2c.8 0 1.4-.6 1.4-1.4v-1.8c1.4-.9 2.3-2.4 2.3-4.3 0-3.1-2.5-5.5-5.8-5.5Zm-2.4 4.7a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2Zm4.8 0a1.6 1.6 0 1 0 0 3.2 1.6 1.6 0 0 0 0-3.2Z"
      />
    </svg>
    """
  end

  def mana_glyph(%{name: :flame} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8.7.5c.7 2.6-.3 4.1-1.8 5.5C5.3 7.5 3.5 9 3.5 11.2a4.5 4.5 0 0 0 9 0c0-1.7-.7-3-1.7-4.1.3 1.1 0 2-.7 2.6.5-2.9-.5-5.6-1.4-9.2Z" />
    </svg>
    """
  end

  def mana_glyph(%{name: :tree} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 .8 4 7.4h2L3.2 11.8h3.7v3.4h2.2v-3.4h3.7L10 7.4h2L8 .8Z" />
    </svg>
    """
  end

  def mana_glyph(%{name: :gem} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M8 .9 2.9 8 8 15.1 13.1 8 8 .9Z" />
    </svg>
    """
  end

  def mana_glyph(%{name: :snow} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <rect x="7.1" y=".6" width="1.8" height="14.8" rx=".9" />
      <rect x="7.1" y=".6" width="1.8" height="14.8" rx=".9" transform="rotate(60 8 8)" />
      <rect x="7.1" y=".6" width="1.8" height="14.8" rx=".9" transform="rotate(120 8 8)" />
    </svg>
    """
  end

  def mana_glyph(%{name: :tap} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M2.6 11.8 10.2 4.2l2 2-7.6 7.6-2-2Z" />
      <path d="M9.4 3 14.6 1.4l-1.6 5.2L9.4 3Z" />
    </svg>
    """
  end

  def mana_glyph(%{name: :untap} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path d="M13.4 11.8 5.8 4.2l-2 2 7.6 7.6 2-2Z" />
      <path d="M6.6 3 1.4 1.4 3 6.6 6.6 3Z" />
    </svg>
    """
  end

  def mana_glyph(%{name: :phyrexian} = assigns) do
    ~H"""
    <svg viewBox="0 0 16 16" aria-hidden="true">
      <path
        fill-rule="evenodd"
        d="M8 1.2c-2.1 0-3.8 1.6-3.8 3.6 0 1.5.9 2.8 2.2 3.3v6.7h3.2V8.1c1.3-.5 2.2-1.8 2.2-3.3 0-2-1.7-3.6-3.8-3.6Zm0 2a1.6 1.6 0 1 1 0 3.2 1.6 1.6 0 0 1 0-3.2Z"
      />
    </svg>
    """
  end
end
