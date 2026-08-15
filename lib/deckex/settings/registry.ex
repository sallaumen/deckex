defmodule Deckex.Settings.Registry do
  @moduledoc """
  The settings this application knows about.

  A key not declared here cannot be read or written. That is the point: a
  key/value table with no registry is a place where typos live forever, and
  where "what can I actually change?" has no answer but grep.

  `options` being non-nil means the value is constrained to that list.
  """

  @type entry :: %{
          key: atom(),
          type: :string | :integer | :number | :baselines,
          default: term(),
          label: String.t(),
          hint: String.t() | nil,
          options: [term()] | nil,
          group: :ai | :budget | :moxfield | :analysis
        }

  @entries [
    %{
      key: :claude_model,
      type: :string,
      default: "sonnet",
      label: "Modelo do Claude",
      hint: "Usado nas consultas e na classificação de cartas.",
      options: ["fable", "sonnet", "opus", "haiku"],
      group: :ai
    },
    %{
      key: :model_floor,
      type: :string,
      default: "fable",
      label: "Modelo mínimo para mudar o deck",
      hint:
        "Análise pode rodar em qualquer modelo. Sugerir corte ou entrada de carta exige " <>
          "pelo menos este. O pipeline recusa começar abaixo dele.",
      options: ["fable", "opus", "sonnet", "haiku"],
      group: :ai
    },
    # Every ceiling is in reais, because that is the currency the owner thinks
    # in. Scryfall quotes USD; `Deckex.Money` converts once, at the edge.
    %{
      key: :budget_max_brl,
      type: :integer,
      default: 0,
      label: "Teto por carta — gastando pouco (R$)",
      hint: "Vale na análise \"Melhorar gastando pouco\". Zero significa sem teto.",
      options: nil,
      group: :budget
    },
    %{
      key: :upgrade_max_brl,
      type: :integer,
      default: 600,
      label: "Teto por carta (R$)",
      hint:
        "Uma carta acima disso ainda pode entrar — gasta uma das vagas de exceção. " <>
          "É um limite, não uma meta: o motor nunca prefere a carta cara.",
      options: nil,
      group: :budget
    },
    # The owner's real constraint is about the LIST, not the card: a few cards
    # at four hundred reais are fine and twelve are not, and there has to be
    # room for the one card worth breaking the rule for.
    %{
      key: :expensive_card_brl,
      type: :integer,
      default: 400,
      label: "A partir de quanto a carta é cara (R$)",
      hint: "Não recusa nada sozinho — serve para contar quantas caras o deck já tem.",
      options: nil,
      group: :budget
    },
    %{
      key: :expensive_card_max,
      type: :integer,
      default: 10,
      label: "Quantas cartas caras o deck aceita",
      hint: "Passando disso, o motor recusa a próxima carta acima da linha. Zero é sem limite.",
      options: nil,
      group: :budget
    },
    %{
      key: :exception_card_max,
      type: :integer,
      default: 2,
      label: "Quantas exceções acima do teto",
      hint:
        "As vagas para a carta absurda que compensa. Não existe teto acima disso: " <>
          "as vagas são o limite, e quando acabam o motor recusa.",
      options: nil,
      group: :budget
    },
    %{
      key: :upgrade_land_max_brl,
      type: :integer,
      default: 200,
      label: "Teto por terreno (R$)",
      hint: "Terreno caro é o jeito mais fácil de estourar o orçamento sem ganhar jogo.",
      options: nil,
      group: :budget
    },
    %{
      key: :usd_to_brl,
      type: :number,
      default: 5.4,
      label: "Dólar em reais",
      hint:
        "A Scryfall cota o mercado americano em dólar. Isto converte para dar escala — " <>
          "a loja brasileira cobra o preço dela, que costuma ser maior.",
      options: nil,
      group: :analysis
    },
    # Group `:view` on purpose: the panel renders the groups a person goes to
    # Ajustes to tune, and nobody opens a settings drawer to change a layout
    # they can toggle on the screen itself. It lives in the registry anyway so
    # the value is validated and persisted like every other one, instead of
    # becoming the app's first untyped preference.
    %{
      key: :deck_layout,
      type: :string,
      default: "cartoes",
      label: "Como listar os decks",
      hint: nil,
      options: ["cartoes", "lista"],
      group: :view
    },
    %{
      key: :moxfield_user_agent,
      type: :string,
      default: "deckex/0.1 (personal deck analysis tool)",
      label: "User-Agent do Moxfield",
      hint: "Cole aqui o que o support@moxfield.com aprovar. Até lá, o sync devolve 403.",
      options: nil,
      group: :moxfield
    },
    %{
      key: :baselines,
      type: :baselines,
      default: %{},
      label: "Baselines da análise",
      hint: "Heurísticas de Commander, não leis. Vazio significa usar os padrões.",
      options: nil,
      group: :analysis
    }
  ]

  @doc "Every declared setting."
  @spec entries() :: [entry()]
  def entries, do: @entries

  @doc "The entry for `key`, or `:error` if it is not declared."
  @spec fetch(atom()) :: {:ok, entry()} | :error
  def fetch(key) do
    case Enum.find(@entries, &(&1.key == key)) do
      nil -> :error
      entry -> {:ok, entry}
    end
  end

  @doc "The entries in one group, in declaration order."
  @spec group(atom()) :: [entry()]
  def group(name), do: Enum.filter(@entries, &(&1.group == name))
end
