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
      default: 800,
      label: "Teto por carta — sem olhar preço (R$)",
      hint: "\"Sem olhar preço\" ainda tem limite: acima disso não é upgrade, é outro deck.",
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
      hint: "Usado só para mostrar o preço das cartas em R$. A Scryfall cota em USD.",
      options: nil,
      group: :analysis
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
