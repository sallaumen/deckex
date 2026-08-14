defmodule Deckex.Consults.SchemasTest do
  use ExUnit.Case, async: true

  alias Deckex.Consults.Schemas

  test "the scout writes the four dossier fields and nothing else" do
    schema = Schemas.for_lens(:scout)

    assert schema["required"] == ["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]
    refute Map.has_key?(schema["properties"], "cuts")
    refute Map.has_key?(schema["properties"], "adds")
  end

  # The reading comes before the prescription. JSON schemas cannot order
  # generation — the briefing's rules do — but the requirement lives here.
  test "every consulting lens must open with its own reading" do
    lenses = [
      :full,
      :speed_curve,
      :mana_ramp,
      :interaction,
      :consistency,
      :matchup,
      :budget,
      :upgrade,
      :finding
    ]

    for lens <- lenses do
      schema = Schemas.for_lens(lens)

      assert "leitura" in schema["required"], "#{lens} lacks leitura"
      assert schema["required"] == ["leitura", "diagnosis", "cuts", "adds"]
      assert schema["properties"]["leitura"]["description"] =~ "discordar"
    end
  end
end
