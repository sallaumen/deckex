[
  parallel: true,
  skipped: false,
  tools: [
    {:compiler, command: "mix compile --warnings-as-errors", detect: [{:package, :elixir}]},
    {:formatter, command: "mix format --check-formatted", detect: [{:package, :elixir}]},
    {:credo, command: "mix credo --strict", detect: [{:package, :credo}]},
    {:dialyzer, command: "mix dialyzer", detect: [{:package, :dialyxir}]},
    {:ex_unit, command: "mix test", detect: [{:package, :ex_unit}]}
  ]
]
