defmodule Deckex.ErrorTest do
  use ExUnit.Case, async: true

  alias Deckex.Error

  describe "new/3" do
    test "carries a code, a message and details" do
      error = Error.new(:moxfield_blocked, "O Moxfield bloqueou a busca.", %{status: 403})

      assert %Error{code: :moxfield_blocked, details: %{status: 403}} = error
      assert error.message == "O Moxfield bloqueou a busca."
    end

    test "defaults details to an empty map" do
      assert %Error{details: %{}} = Error.new(:ai_timeout, "A IA não respondeu.")
    end

    test "is a raisable exception whose message is the domain message" do
      error = Error.new(:scryfall_unavailable, "Scryfall fora do ar.")

      assert Exception.message(error) == "Scryfall fora do ar."
      assert_raise Error, "Scryfall fora do ar.", fn -> raise error end
    end
  end
end
