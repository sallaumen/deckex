# Mox mocks for the integration ports. Each is selected as the adapter in
# config/test.exs so the domain talks to the mock instead of the real service.
Mox.defmock(Deckex.Scryfall.Mock, for: Deckex.Scryfall.Client)
