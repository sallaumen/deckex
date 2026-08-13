defmodule Deckex.Consults.Schemas do
  @moduledoc """
  The JSON schema a consult's answer must satisfy.

  Every lens gets the same **shape** — a diagnosis, cards to cut, cards to add
  — because that is what the user does with the answer regardless of which
  question was asked. What differs per lens is the *prompt*, not the schema;
  `for_lens/1` exists so that stops being true the day it needs to.
  """

  @spec for_lens(atom()) :: map()
  def for_lens(_lens) do
    %{
      "type" => "object",
      "properties" => %{
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
              "reason" => %{"type" => "string", "description" => "One sentence, pt-BR."}
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
      "required" => ["diagnosis", "cuts", "adds"]
    }
  end
end
