defmodule Deckex.Factory do
  @moduledoc "ExMachina factories. See https://hexdocs.pm/ex_machina."
  use ExMachina.Ecto, repo: Deckex.Repo

  alias Deckex.Cards.Card
  alias Deckex.Cards.Name
  alias Deckex.Consults.Consult
  alias Deckex.Decks.Deck
  alias Deckex.Decks.DeckCard
  alias Deckex.Optimizations.Optimization
  alias Deckex.Optimizations.OptimizationStep

  def card_factory do
    name = sequence(:card_name, &"Test Card #{&1}")

    %Card{
      oracle_id: Ecto.UUID.generate(),
      scryfall_id: Ecto.UUID.generate(),
      name: name,
      name_normalized: Name.normalize(name),
      mana_cost: "{2}{G}",
      cmc: Decimal.new("3.0"),
      type_line: "Sorcery",
      oracle_text: "Draw a card.",
      colors: ["G"],
      color_identity: ["G"],
      produced_mana: [],
      keywords: [],
      layout: "normal",
      card_faces: [],
      commander_legal: true,
      fetched_at: DateTime.utc_now(:second)
    }
  end

  def deck_factory do
    %Deck{
      name: sequence(:deck_name, &"Deck #{&1}"),
      source: :paste,
      status: :ready,
      color_identity: [],
      raw_decklist: "1 Sol Ring"
    }
  end

  def consult_factory do
    %Consult{
      deck: build(:deck),
      lens: :mana_ramp,
      status: :pending,
      briefing: "Analise este deck.",
      report_snapshot: %{"curve" => %{"avg_cmc" => 2.8}}
    }
  end

  def deck_card_factory do
    %DeckCard{
      deck: build(:deck),
      card: build(:card),
      quantity: 1,
      board: :main
    }
  end

  def optimization_factory do
    %Optimization{
      deck: build(:deck),
      mode: :refine,
      status: :running,
      contract: %{
        "bracket_max" => 3,
        "ceilings" => %{"card" => 800, "land" => 200},
        "keep" => [],
        "matchups" => ["um deck aggro rápido"],
        "notes" => "",
        "model" => "sonnet"
      },
      recipe: [
        %{"kind" => "execucao", "lens" => "execucao", "label" => "Mana"},
        %{"kind" => "critico", "lens" => "critico", "label" => "Estabilização"}
      ],
      list_original: [%{"name" => "Sol Ring", "quantity" => 1}],
      commanders: []
    }
  end

  def optimization_step_factory do
    %OptimizationStep{
      optimization: build(:optimization),
      position: 1,
      kind: :execucao,
      lens: "execucao",
      label: "Execução",
      status: :pending,
      list_before: [%{"name" => "Sol Ring", "quantity" => 1}]
    }
  end
end
