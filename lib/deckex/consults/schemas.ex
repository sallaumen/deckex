defmodule Deckex.Consults.Schemas do
  @moduledoc """
  The JSON schema a consult's answer must satisfy.

  Two shapes now. The scout writes the strategic dossier — four prose fields,
  no cuts, no adds: a scout that suggests cards has become a consultant, and
  the consultant already exists. Every other lens shares the diagnosis/cuts/
  adds shape, opened by a required `leitura`: the model's own reading of the
  deck, confronted with the dossier when one was injected. The mandated
  disagreement makes `leitura` double as a stale-dossier detector.
  """

  @spec for_lens(atom()) :: map()
  def for_lens(:scout) do
    %{
      "type" => "object",
      "properties" => %{
        "plano" => %{
          "type" => "string",
          "description" =>
            "One paragraph, pt-BR: what this deck is trying to do and how the commander enables it. Card names untranslated."
        },
        "sinergias" => %{
          "type" => "string",
          "description" =>
            "One paragraph, pt-BR: the specific interactions that give this deck its identity, naming the cards involved."
        },
        "linhas_de_vitoria" => %{
          "type" => "string",
          "description" => "One paragraph, pt-BR: how this deck actually closes a game."
        },
        "fraquezas" => %{
          "type" => "string",
          "description" =>
            "One paragraph, pt-BR: only weaknesses the measurements above do NOT show — e.g. a dependency, a single point of failure the numbers cannot see."
        }
      },
      "required" => ["plano", "sinergias", "linhas_de_vitoria", "fraquezas"]
    }
  end

  def for_lens(_lens) do
    %{
      "type" => "object",
      "properties" => %{
        "leitura" => %{
          "type" => "string",
          "description" =>
            "2-4 frases, pt-BR: sua leitura do plano deste deck, confrontada com o dossiê acima (se houver). Se você discordar do dossiê, diga onde e por quê."
        },
        "diagnosis" => %{
          "type" => "string",
          "description" => "One paragraph in pt-BR on what is actually wrong."
        },
        "cuts" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "card" => %{"type" => "string", "description" => "Exact card name, untranslated."},
              "reason" => %{"type" => "string", "description" => "One sentence, pt-BR."},
              "addresses" => %{
                "type" => "string",
                "description" => "The finding code this cut serves, e.g. mana.color_starved."
              }
            },
            "required" => ["card", "reason"]
          }
        },
        "adds" => %{
          "type" => "array",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "card" => %{"type" => "string", "description" => "Exact card name, untranslated."},
              "reason" => %{"type" => "string", "description" => "One sentence, pt-BR."},
              "addresses" => %{
                "type" => "string",
                "description" =>
                  "The finding code this add serves, e.g. interaction.board_wipes_low."
              },
              "replaces" => %{
                "type" => "string",
                "description" => "The cut this add pairs with, if any."
              }
            },
            "required" => ["card", "reason"]
          }
        },
        "notes" => %{
          "type" => "string",
          "description" => "Anything the lists could not carry, pt-BR."
        }
      },
      "required" => ["leitura", "diagnosis", "cuts", "adds"]
    }
  end
end
