defmodule Deckex.Consults.Schemas do
  @moduledoc """
  The JSON schema a consult's answer must satisfy.

  Three shapes now. The scout writes the strategic dossier — four prose fields,
  no cuts, no adds: a scout that suggests cards has become a consultant, and
  the consultant already exists. The `:visao` lens writes three directions —
  name, thesis, honest cost, key cards — and likewise proposes no changes: it
  is asked what the deck could become, not what to do this turn. Every other lens shares the diagnosis/cuts/
  adds shape, opened by a required `leitura`: the model's own reading of the
  deck, confronted with the dossier when one was injected. The mandated
  disagreement makes `leitura` double as a stale-dossier detector.
  """

  @spec for_lens(atom()) :: map()
  def for_lens(:bracket) do
    %{
      "type" => "object",
      "properties" => %{
        "bracket" => %{
          "type" => "integer",
          "minimum" => 1,
          "maximum" => 5,
          "description" =>
            "The bracket this deck actually belongs in. It may not be lower than the measured floor the briefing states."
        },
        "combo" => %{
          "type" => "string",
          "description" =>
            "pt-BR: any two-card combo that wins on the spot, naming both cards and the earliest turn it assembles. Say \"nenhum que eu veja\" if there is none."
        },
        "speed" => %{
          "type" => "string",
          "description" => "pt-BR: on which turn this deck realistically closes a game, and why."
        },
        "justificativa" => %{
          "type" => "string",
          "description" => "pt-BR: why this bracket and not the one above or below."
        },
        "para_descer" => %{
          "type" => "string",
          "description" =>
            "pt-BR: the single change that would move this deck down a bracket, or why none would."
        }
      },
      "required" => ["bracket", "combo", "speed", "justificativa"]
    }
  end

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

  def for_lens(:pilares) do
    %{
      "type" => "object",
      "properties" => %{
        "leitura" => %{
          "type" => "string",
          "description" =>
            "2-4 frases, pt-BR: o que este deck faz, e o que ele para de ser se as cartas abaixo saírem."
        },
        "pilares" => %{
          "type" => "array",
          "description" =>
            "As cartas que este deck não pode perder. Poucas — se você listar um quarto do deck, não protegeu nada.",
          "items" => %{
            "type" => "object",
            "properties" => %{
              "carta" => %{
                "type" => "string",
                "description" => "Exact card name as written in the decklist, untranslated."
              },
              "motivo" => %{
                "type" => "string",
                "description" =>
                  "Uma frase, pt-BR: o que o deck deixa de fazer sem ela. Nomeie a outra carta quando for uma interação."
              }
            },
            "required" => ["carta", "motivo"]
          }
        }
      },
      "required" => ["leitura", "pilares"]
    }
  end

  def for_lens(:visao) do
    %{
      "type" => "object",
      "properties" => %{
        "visoes" => %{
          "type" => "array",
          "minItems" => 3,
          "maxItems" => 3,
          "items" => %{
            "type" => "object",
            "properties" => %{
              "nome" => %{
                "type" => "string",
                "description" => "pt-BR: a short name for this direction, 2-4 words."
              },
              "arquetipo" => %{
                "type" => "string",
                "enum" => ~w(aggro midrange controle combo stax ramp politica grupo),
                "description" =>
                  "What the deck would be TRYING TO DO. The three visions MUST differ here."
              },
              "tema" => %{
                "type" => "string",
                "description" =>
                  "The mechanical engine, in the community's own name for it: aristocrats, landfall, blink, spellslinger, storm, reanimator, enchantress, tokens, voltron, artifacts, +1/+1 counters, typal, theft, wheels, lifegain, toolbox, and so on. Not an enum — the list grows with every set."
              },
              "tese" => %{
                "type" => "string",
                "description" => "One paragraph, pt-BR: why this makes the deck stronger."
              },
              "custo" => %{
                "type" => "string",
                "description" =>
                  "One paragraph, pt-BR: what the deck LOSES going this way. Be honest."
              },
              "cartas_chave" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" =>
                  "Exact card names, untranslated, that define this direction. Never state a price."
              },
              "comandante" => %{
                "type" => "string",
                "description" =>
                  "Optional: a different commander for this direction. It MUST have exactly the deck's colour identity. Omit to keep the current one."
              }
            },
            "required" => ["nome", "arquetipo", "tema", "tese", "custo", "cartas_chave"]
          }
        }
      },
      "required" => ["visoes"]
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
