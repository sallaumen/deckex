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
      <p :if={@note} class="font-mono text-micro leading-tight text-ink-faint">{@note}</p>
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
